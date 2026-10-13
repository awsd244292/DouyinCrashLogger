//
//  DCLHealthCheck.m
//  DouyinCrashLogger
//

#import "DCLHealthCheck.h"
#import "DCLCrashReporter.h"
#import "DCLConfig.h"
#import "DCLWatchdog.h"
#import "DCLPlaybackTracer.h"
#import "DCLHotSwitch.h"
#import "DCLLogger.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>   // _dyld_image_count / _dyld_get_image_name
#import <signal.h>
#import <sys/time.h>
#import <unistd.h>

@implementation DCLHealthItem
@end

@implementation DCLHealthCheck

+ (BOOL)isHealthy {
    for (DCLHealthItem *i in [self run]) {
        if (i.level == DCLHealthLevelFail) return NO;
    }
    return YES;
}

#pragma mark - 各项检查

/// 1) 信号处理器是否仍由本模块持有（防止被其他注入插件覆盖）
/// 内部：把「当前各信号处理器状态」分类为 lost（被别的模块接走）/ reset（被重置为默认/忽略）
+ (void)classifySignalStateLost:(NSMutableArray **)lostOut reset:(NSMutableArray **)resetOut {
    void *ours = [DCLCrashReporter currentSignalHandlerPointer];
    NSArray<NSNumber *> *monitored = [DCLCrashReporter monitoredSignals];
    NSMutableArray *lost = [NSMutableArray array];
    NSMutableArray *reset = [NSMutableArray array];
    // 只核对本模块真正接管的信号。刻意不含 SIGPIPE ——
    // 把它算进来会把「按设计不接管」误报成「被别人抢走」，天天刷告警，
    // 反而把真正有价值的告警淹没掉。
    for (NSNumber *num in monitored) {
        int sig = num.intValue;
        struct sigaction cur;
        memset(&cur, 0, sizeof(cur));
        sigaction(sig, NULL, &cur);
        void *installed = (cur.sa_flags & SA_SIGINFO)
                        ? (void *)(uintptr_t)cur.sa_sigaction
                        : (void *)(uintptr_t)cur.sa_handler;
        if (installed == ours) continue;
        if (!installed || installed == (void *)SIG_DFL || installed == (void *)SIG_IGN) {
            [reset addObject:num];
        } else {
            [lost addObject:num];
        }
    }
    *lostOut = lost;
    *resetOut = reset;
}

+ (DCLHealthItem *)checkSignalHandlers {
    DCLHealthItem *it = [DCLHealthItem new];
    it.name = @"崩溃信号处理器";
    @try {
        NSMutableArray *lost = nil, *reset = nil;
        [self classifySignalStateLost:&lost reset:&reset];
        NSUInteger total = [DCLCrashReporter monitoredSignals].count;

        if (lost.count == 0 && reset.count == 0) {
            it.level = DCLHealthLevelPass;
            it.evidence = [NSString stringWithFormat:
                           @"%lu 个致命信号(SIGABRT/SEGV/BUS/TRAP/ILL/FPE)的当前处理器"
                           @"均指向本模块函数地址 0x%llx",
                           (unsigned long)total,
                           (unsigned long long)(uintptr_t)[DCLCrashReporter currentSignalHandlerPointer]];
            return it;
        }

        // 检测到被顶替：先尝试自愈夺回，再复核夺回后的真实状态。
        [DCLCrashReporter healSignalHandlersIfNeeded];
        NSMutableArray *lost2 = nil, *reset2 = nil;
        [self classifySignalStateLost:&lost2 reset:&reset2];

        if (lost2.count == 0 && reset2.count == 0) {
            it.level = DCLHealthLevelWarn;   // 已修好，但这一轮确实出现过顶替
            NSMutableString *d = [NSMutableString string];
            if (lost.count) [d appendFormat:@"信号 %@ 曾被其他模块接管",
                              [lost componentsJoinedByString:@", "]];
            if (reset.count) [d appendFormat:@"%@信号 %@ 曾被重置为默认/忽略",
                              lost.count ? @"；" : @"", [reset componentsJoinedByString:@", "]];
            [d appendString:@"，已自愈夺回（这部分崩溃现在能抓到了）"];
            it.evidence = d;
        } else if (lost2.count + reset2.count < total) {
            it.level = DCLHealthLevelWarn;
            NSMutableString *d = [NSMutableString string];
            if (lost2.count)  [d appendFormat:@"信号 %@ 已被其他模块接管",
                               [lost2 componentsJoinedByString:@", "]];
            if (reset2.count) [d appendFormat:@"%@信号 %@ 已被重置为默认/忽略",
                               lost2.count ? @"；" : @"", [reset2 componentsJoinedByString:@", "]];
            [d appendString:@"，这部分崩溃将抓不到（自愈未能全部夺回）"];
            it.evidence = d;
        } else {
            it.level = DCLHealthLevelFail;
            it.evidence = @"全部信号处理器均已失效，自愈未能夺回，本插件的崩溃捕获不可用";
        }
    } @catch (id e) {
        it.level = DCLHealthLevelFail;
        it.evidence = @"检查过程异常，无法确认";
    }
    return it;
}

/// 2) OC 未捕获异常处理器
+ (DCLHealthItem *)checkUncaughtExceptionHandler {
    DCLHealthItem *it = [DCLHealthItem new];
    it.name = @"OC 未捕获异常处理器";
    @try {
        void *ours = [DCLCrashReporter currentUncaughtExceptionHandlerPointer];
        void *cur = (void *)(uintptr_t)NSGetUncaughtExceptionHandler();
        if (cur == ours) {
            it.level = DCLHealthLevelPass;
            it.evidence = @" NSGetUncaughtExceptionHandler() 返回的正是本模块处理器";
        } else {
            // 检测到被顶替：先尝试自愈夺回，再据结果给结论（而非直接判死）。
            BOOL healed = [DCLCrashReporter healUncaughtExceptionHandlerIfNeeded];
            if (healed) {
                it.level = DCLHealthLevelWarn;
                it.evidence = [NSString stringWithFormat:
                               @"曾被替换(0x%llx)，已自愈夺回；本模块 0x%llx。若反复出现，"
                               @"说明有共存模块在抢这个 handler（如 libMetalMetricsInterpose）",
                               (unsigned long long)(uintptr_t)cur,
                               (unsigned long long)(uintptr_t)ours];
            } else {
                it.level = DCLHealthLevelFail;
                it.evidence = [NSString stringWithFormat:
                               @"已被替换：当前 0x%llx，本模块 0x%llx；自愈尝试未生效",
                               (unsigned long long)(uintptr_t)cur,
                               (unsigned long long)(uintptr_t)ours];
            }
        }
    } @catch (id e) {
        it.level = DCLHealthLevelFail;
        it.evidence = @"检查异常";
    }
    return it;
}

/// 3) 沙盒写入能力（日志落不了盘，前面所有检查都没意义）
+ (DCLHealthItem *)checkSandboxWritable {
    DCLHealthItem *it = [DCLHealthItem new];
    it.name = @"沙盒写入可用性";
    @try {
        NSString *probe = [[DCLCrashReporter crashLogsDirectory]
                           stringByAppendingPathComponent:@".writeprobe"];
        NSString *payload = [NSString stringWithFormat:@"%d", (int)getpid()];
        NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
        [data writeToFile:probe atomically:YES];
        NSData *back = [NSData dataWithContentsOfFile:probe];
        NSString *s = back ? [[NSString alloc] initWithData:back encoding:NSUTF8StringEncoding] : nil;
        [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
        if (s && [s isEqualToString:payload]) {
            it.level = DCLHealthLevelPass;
            it.evidence = @"探针文件写入后立即读回，内容逐字节一致";
        } else {
            it.level = DCLHealthLevelFail;
            it.evidence = @"探针文件写入后无法读回 —— 崩溃日志将无法落盘";
        }
    } @catch (id e) {
        it.level = DCLHealthLevelFail;
        it.evidence = @"写入探针时抛出异常";
    }
    return it;
}

/// 4) 主线程看门狗是否在运行
+ (DCLHealthItem *)checkWatchdog {
    DCLHealthItem *it = [DCLHealthItem new];
    it.name = @"主线程看门狗";
    @try {
        double age = [DCLWatchdog watchdogHeartbeatAgeSec];
        if (age < 0) {
            it.level = DCLHealthLevelFail;
            it.evidence = @"看门狗从未上报心跳，线程可能未启动";
        } else if (age < 2.0) {
            it.level = DCLHealthLevelPass;
            it.evidence = [NSString stringWithFormat:
                           @"看门狗线程 %.2f 秒前上报心跳，主线程心跳滞留 %.2f 秒",
                           age, [DCLWatchdog mainLoopHeartbeatAgeSec]];
        } else {
            it.level = DCLHealthLevelWarn;
            it.evidence = [NSString stringWithFormat:@"看门狗心跳滞留 %.2f 秒", age];
        }
    } @catch (id e) {
        it.level = DCLHealthLevelFail;
        it.evidence = @"检查异常";
    }
    return it;
}

/// 5) 主线程响应延迟实测（这是「界面没卡死」的直接证据）
+ (DCLHealthItem *)checkMainThreadResponsive {
    DCLHealthItem *it = [DCLHealthItem new];
    it.name = @"主线程响应";
    @try {
        // 从主线程自测自己的响应速度是自欺欺人：投递的任务要等 RunLoop 回到当前位置才执行，
        // 测出来的必然是 0。这种情况如实标注为「未客观测量」，不给假绿灯。
        if ([NSThread isMainThread]) {
            it.level = DCLHealthLevelWarn;
            it.evidence = @"本次自检运行在主线程，无法客观测量自身响应延迟（非故障）";
            return it;
        }
        double ms = [DCLWatchdog measureMainThreadResponseMs];
        if (ms < 0) {
            it.level = DCLHealthLevelWarn;
            it.evidence = @"测量超时：主线程 3 秒未处理投递的任务（可能正忙 / 已卡死）";
        } else if (ms < 200.0) {
            it.level = DCLHealthLevelPass;
            it.evidence = [NSString stringWithFormat:@"投递任务在 %.1f ms 内被主线程执行", ms];
        } else {
            it.level = DCLHealthLevelWarn;
            it.evidence = [NSString stringWithFormat:@"主线程响应偏慢：%.1f ms", ms];
        }
    } @catch (id e) {
        it.level = DCLHealthLevelFail;
        it.evidence = @"检查异常";
    }
    return it;
}

/// 6) 播放探针是否已挂载。
/// 关键：A 方案（safe，零 hook）下探针按设计就是不挂载的 —— 这不是故障，
/// 若一概判 FAIL，自检会把「按设计未启用」误报成「插件坏了」，反而破坏证据链。
+ (DCLHealthItem *)checkPlaybackProbe {
    DCLHealthItem *it = [DCLHealthItem new];
    it.name = @"播放暂停探针";
    @try {
        if (![DCLConfig hooksEnabled]) {
            it.level = DCLHealthLevelPass;
            it.evidence = [NSString stringWithFormat:
                           @"按设计未启用：当前为 %@，不挂载任何方法钩子；"
                           @"需抓取「谁调用了 pause」时切到 B 方案 full 即可",
                           [DCLConfig profileDisplayName]];
            return it;
        }
        NSUInteger n = [DCLPlaybackTracer hookedCount];
        if (n >= 4) {
            it.level = DCLHealthLevelPass;
            it.evidence = [NSString stringWithFormat:
                           @"AVPlayer 的 pause/play/setRate:/replaceItem + UIApplication sendEvent:"
                           @" 共 %lu 处挂载成功", (unsigned long)n];
        } else if (n > 0) {
            it.level = DCLHealthLevelWarn;
            it.evidence = [NSString stringWithFormat:
                           @"仅 %lu 处挂载成功（预期 5 处），部分暂停行为可能抓不到", (unsigned long)n];
        } else {
            it.level = DCLHealthLevelFail;
            it.evidence = @"当前为 B 方案 full，但探针一处都没挂上 —— 暂停归因不可用";
        }
    } @catch (id e) {
        it.level = DCLHealthLevelFail;
        it.evidence = @"检查异常";
    }
    return it;
}

/// 9) 采集方案与开关文件 —— 让人一眼看出「这份日志是哪档方案抓的、怎么改」
+ (DCLHealthItem *)checkCaptureProfile {
    DCLHealthItem *it = [DCLHealthItem new];
    it.name = @"采集方案";
    @try {
        it.level = DCLHealthLevelPass;
        it.evidence = [NSString stringWithFormat:@"当前 %@；开关文件 %@",
                       [DCLConfig profileDisplayName], [DCLConfig modeFilePath]];
    } @catch (id e) {
        it.level = DCLHealthLevelWarn;
        it.evidence = @"读取采集方案配置异常，已按 A 方案 safe 兜底";
    }
    return it;
}

/// 7) 第三方注入模块清单 —— 冲突排查的第一手依据
+ (DCLHealthItem *)checkInjectedModules {
    DCLHealthItem *it = [DCLHealthItem new];
    it.name = @"同进程注入模块";
    @try {
        NSMutableArray *third = [NSMutableArray array];
        uint32_t count = _dyld_image_count();
        const char *exec = _dyld_get_image_name(0);
        NSString *execPath = exec ? [NSString stringWithUTF8String:exec] : @"";
        NSString *bundle = [execPath stringByDeletingLastPathComponent];
        for (uint32_t i = 1; i < count; i++) {
            const char *p = _dyld_get_image_name(i);
            if (!p) continue;
            NSString *full = [NSString stringWithUTF8String:p];
            if ([full hasPrefix:@"/System/"] || [full hasPrefix:@"/usr/lib/"] ||
                [full hasPrefix:@"/usr/libexec/"]) continue;
            if (bundle.length && [full hasPrefix:bundle]) continue;
            [third addObject:full.lastPathComponent];
        }
        if (third.count == 0) {
            it.level = DCLHealthLevelPass;
            it.evidence = @"除系统库外未发现其他注入模块（无第三方插件共存）";
        } else {
            it.level = DCLHealthLevelWarn;
            it.evidence = [NSString stringWithFormat:
                           @"共存 %lu 个第三方模块：%@ —— 界面异常时它们是首要嫌疑对象",
                           (unsigned long)third.count, [third componentsJoinedByString:@", "]];
        }
    } @catch (id e) {
        it.level = DCLHealthLevelWarn;
        it.evidence = @"读取镜像列表异常";
    }
    return it;
}

/// 8) 进程资源概况
+ (DCLHealthItem *)checkResourceFootprint {
    DCLHealthItem *it = [DCLHealthItem new];
    it.name = @"进程资源占用";
    @try {
        struct mach_task_basic_info info;
        mach_msg_type_number_t cnt = MACH_TASK_BASIC_INFO_COUNT;
        kern_return_t kr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                     (task_info_t)&info, &cnt);
        if (kr == KERN_SUCCESS) {
            double mb = (double)info.resident_size / (1024.0 * 1024.0);
            DCLHealthLevel lv = mb > 1200.0 ? DCLHealthLevelWarn : DCLHealthLevelPass;
            it.level = lv;
            it.evidence = [NSString stringWithFormat:
                           @"常驻内存 %.1f MB（>1.2GB 时系统会开始强杀 App）", mb];
        } else {
            it.level = DCLHealthLevelWarn;
            it.evidence = @"无法读取内存占用";
        }
    } @catch (id e) {
        it.level = DCLHealthLevelWarn;
        it.evidence = @"读取异常";
    }
    return it;
}

#pragma mark - 入口

/// 9) 日志管线：stderr 是否接管成功 + 当前会话日志体量是否被闸门管住。
///    反馈里「文件又大又从不清」就是这一项要盯的事。
+ (DCLHealthItem *)checkLogPipeline {
    DCLHealthItem *it = [DCLHealthItem new];
    it.name = @"日志管线（会话轮转 + 大小闸门）";
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *cur = [DCLLogger runtimeLogPath];
        unsigned long long curSize = [[fm attributesOfItemAtPath:cur error:nil] fileSize];
        BOOL prev = [fm fileExistsAtPath:[DCLLogger previousRuntimeLogPath]];
        const NSUInteger capBytes = [DCLLogger runtimeLogMaxBytes];

        if ([DCLLogger stderrCaptureInstalled] && curSize <= capBytes) {
            it.level = DCLHealthLevelPass;
            it.evidence = [NSString stringWithFormat:
                           @"stderr/stdout 已接管（管道+后台泵，写端 O_NONBLOCK）；"
                           @"当前会话日志 %llu B / 上限 %lu B，上一会话%s；"
                           @"已落盘 %lu 行，抽样压掉重复刷屏 %lu 行，剔除系统噪音 %lu 行",
                           curSize, (unsigned long)capBytes, prev ? "已轮转为 _prev" : "（首轮无）",
                           (unsigned long)[DCLLogger writtenLineCount],
                           (unsigned long)[DCLLogger throttledLineCount],
                           (unsigned long)[DCLLogger noiseDroppedCount]];
        } else if (![DCLLogger stderrCaptureInstalled]) {
            it.level = DCLHealthLevelWarn;
            it.evidence = @"stderr/stdout 未接管（宿主已在重定向或本次注入方式受限）；"
                          @"本插件自身的日志仍会写盘，但看不到宿主的 stdout 输出";
        } else {
            it.level = DCLHealthLevelWarn;
            it.evidence = [NSString stringWithFormat:
                           @"当前会话日志 %llu B，已超过上限 %lu B 却未被裁剪 —— 需复查闸门逻辑",
                           curSize, (unsigned long)capBytes];
        }
    } @catch (id e) {
        it.level = DCLHealthLevelWarn;
        it.evidence = @"检查异常，无法确认日志管线状态";
    }
    return it;
}

/// 10) 摇一摇热切换监听是否挂上。摇了没反应时，这一项是第一现场：
///     先看「监听有没有挂上」，再谈「有没有提示」。
+ (DCLHealthItem *)checkHotSwitch {
    DCLHealthItem *it = [DCLHealthItem new];
    it.name = @"摇一摇热切换监听";
    @try {
        BOOL ok = [DCLHotSwitch isInstalled];
        it.level = ok ? DCLHealthLevelPass : DCLHealthLevelWarn;
        it.evidence = [DCLHotSwitch installStateDescription];
    } @catch (id e) {
        it.level = DCLHealthLevelWarn;
        it.evidence = @"检查异常，无法确认监听状态";
    }
    return it;
}

+ (NSArray<DCLHealthItem *> *)run {
    NSMutableArray *items = [NSMutableArray array];
    @try {
        [items addObject:[self checkCaptureProfile]];
        [items addObject:[self checkSignalHandlers]];
        [items addObject:[self checkUncaughtExceptionHandler]];
        [items addObject:[self checkSandboxWritable]];
        [items addObject:[self checkWatchdog]];
        [items addObject:[self checkPlaybackProbe]];
        [items addObject:[self checkInjectedModules]];
        [items addObject:[self checkResourceFootprint]];
        [items addObject:[self checkLogPipeline]];
        [items addObject:[self checkHotSwitch]];
        // 主线程响应实测放最后：它会阻塞调用方最多 3 秒，别挡住前面各项
        [items addObject:[self checkMainThreadResponsive]];
    } @catch (id e) {
        (void)e;
    }
    return items;
}

@end
