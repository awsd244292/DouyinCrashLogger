//
//  DCLWatchdog.m
//  DouyinCrashLogger
//

#import "DCLWatchdog.h"
#import "DCLConfig.h"

#import "DCLCrashReporter.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <pthread.h>
#import <pthread_machdep.h>
#import <stdatomic.h>
#import <string.h>
#import <sys/time.h>

#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

@class DCLWatchdog;

/// 私有接口：反查镜像名是否为第三方注入（供 C 函数反查使用）
@interface DCLWatchdog (DCLPrivate)
+ (BOOL)isThirdPartyImageNamed:(NSString *)imageName;
@end

// 卡顿判定阈值：主线程「醒着」却超过这么久没推进 RunLoop，判定为卡死。
// 取 2s 是刻意的：短于此通常是正常渲染抖动，不值得为此 suspend 主线程。
static const uint64_t kStallThresholdUs = 2 * 1000 * 1000;
// 看门狗轮询间隔
static const useconds_t kPollIntervalUs = 200 * 1000;
// 单次卡顿最多采样的栈次数（抑制 suspend/resume 频率）
static const int kMaxSamplesPerStall = 3;
// 两次采样之间的间隔
static const useconds_t kSampleIntervalUs = 500 * 1000;

#define DCL_MAX_FRAMES 40

static uint64_t dcl_now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
}

#if __has_feature(ptrauth_calls)
static inline uint64_t dcl_strip(uint64_t p) {
    return (uint64_t)ptrauth_strip((void *)p, ptrauth_key_return_address);
}
#else
static inline uint64_t dcl_strip(uint64_t p) { return p; }
#endif

#pragma mark - 全局状态

static volatile uint64_t g_main_heartbeat_us = 0;      // 主线程心跳
static volatile CFRunLoopActivity g_last_activity = 0; // 主线程最后一次 RunLoop 活动
static volatile uint64_t g_last_touch_us = 0;          // 最近一次触摸事件
static volatile uint64_t g_watchdog_alive_us = 0;      // watchdog 自身心跳（自证活着）
static volatile int32_t g_backgrounded = 0;            // App 是否在后台
static volatile int32_t g_installed = 0;

static thread_t g_main_thread = MACH_PORT_NULL;
static CFRunLoopObserverRef g_loop_observer = NULL;
static NSThread *g_watchdog_thread = nil;

static NSMutableArray<DCLStallRecord *> *g_stalls = nil;
static pthread_mutex_t g_stalls_lock = PTHREAD_MUTEX_INITIALIZER;

// 最近一次卡死时自动抓取的全线程快照（缓存，供 latest.log 在任意触发器上复现）
static NSString *g_last_all_threads_snapshot = nil;
static pthread_mutex_t g_snap_lock = PTHREAD_MUTEX_INITIALIZER;

/// 是否允许深度取证（suspend 主线程采样 + 全线程快照）。仅 B 方案 full 为 YES。
/// 用懒加载而不是在 install 里赋一次值：截屏触发器可能在 install 之前就调用快照，
/// 那时 install 尚未执行，读到的会是未初始化的默认值。
static volatile int32_t g_deep_evidence = -1;
static BOOL dcl_deep_evidence(void) {
    int32_t v = g_deep_evidence;
    if (v < 0) {
        @try { v = [DCLConfig deepEvidenceEnabled] ? 1 : 0; }
        @catch (id e) { (void)e; v = 0; }   // 读开关失败按最保守处理：不取证
        g_deep_evidence = v;
    }
    return v == 1;
}

@implementation DCLStallRecord
@end

#pragma mark - RunLoop 观察者（主线程唯一的额外负担）

static void dcl_loop_activity(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    g_main_heartbeat_us = dcl_now_us();
    g_last_activity = activity;
}

#pragma mark - Mach 主线程栈回溯

static BOOL dcl_read_mem(mach_vm_address_t src, void *dst, mach_vm_size_t size) {
    mach_vm_size_t outSize = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), src, size,
                                              (mach_vm_address_t)dst, &outSize);
    return (kr == KERN_SUCCESS && outSize == size);
}

/// 挂起主线程并回溯其调用栈（arm64/arm64e frame pointer 链）。
/// 调用者必须位于非主线程。函数内部保证必定 thread_resume。
static void dcl_sample_main_thread(uint64_t *outAddrs, int *outCount) {
    *outCount = 0;
    if (g_main_thread == MACH_PORT_NULL) return;

    if (thread_suspend(g_main_thread) != KERN_SUCCESS) return;

    uint64_t addrs[DCL_MAX_FRAMES];
    int n = 0;
    @try {
        _STRUCT_MCONTEXT mc;
        mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(g_main_thread, ARM_THREAD_STATE64,
                             (thread_state_t)&mc.__ss, &count) != KERN_SUCCESS) {
            return;
        }

        uint64_t pc = dcl_strip(mc.__ss.__pc);
        uint64_t lr = dcl_strip(mc.__ss.__lr);
        uint64_t fp = dcl_strip(mc.__ss.__fp);

        addrs[n++] = pc;
        if (lr && lr != pc) addrs[n++] = lr;

        uint64_t cur = fp;
        int guard = 0;
        while (n < DCL_MAX_FRAMES && cur != 0 && guard++ < DCL_MAX_FRAMES * 2) {
            uint64_t savedFp = 0, savedLr = 0;
            if (!dcl_read_mem(cur, &savedFp, 8)) break;
            if (!dcl_read_mem(cur + 8, &savedLr, 8)) break;
            savedLr = dcl_strip(savedLr);
            savedFp = dcl_strip(savedFp);
            if (savedLr == 0) break;
            addrs[n++] = savedLr;
            if (savedFp <= cur) break;   // 帧指针不再向高地址推进，链路结束
            cur = savedFp;
        }
    } @catch (id e) {
        (void)e;
    } @finally {
        thread_resume(g_main_thread);
    }

    for (int i = 0; i < n; i++) outAddrs[i] = addrs[i];
    *outCount = n;
}

static NSString *dcl_image_short_name(const char *path) {
    if (!path || !*path) return @"(未知)";
    NSString *s = [NSString stringWithUTF8String:path];
    return s.lastPathComponent.length ? s.lastPathComponent : s;
}

static NSArray<NSString *> *dcl_symbolize(uint64_t *addrs, int n) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (int i = 0; i < n; i++) {
        Dl_info info;
        memset(&info, 0, sizeof(info));
        if (dladdr((const void *)addrs[i], &info)) {
            NSString *img = dcl_image_short_name(info.dli_fname);
            int64_t off = info.dli_fbase ? (int64_t)(addrs[i] - (uint64_t)info.dli_fbase) : 0;
            if (info.dli_sname) {
                [out addObject:[NSString stringWithFormat:@"#%-2d 0x%llx %@ +%lld  %s",
                                i, (unsigned long long)addrs[i], img, (long long)off, info.dli_sname]];
            } else {
                [out addObject:[NSString stringWithFormat:@"#%-2d 0x%llx %@ +%lld",
                                i, (unsigned long long)addrs[i], img, (long long)off]];
            }
        } else {
            [out addObject:[NSString stringWithFormat:@"#%-2d 0x%llx (无法符号化)",
                            i, (unsigned long long)addrs[i]]];
        }
    }
    return out;
}

#pragma mark - 全线程快照（融合 PerfDebugPlugin 抓取手段）

/// 格式化一帧：地址 + 镜像+偏移 + 符号（strip 帧标 <redacted>），与 PerfDebugPlugin 同构。
/// 注意：本函数会调用 dladdr 并分配 NSString —— 只允许在「没有线程被挂起」时调用。
///
/// 线程名（TTNet-TP-Svc / Live0_xxxx 这类）已在挂起窗口之前用 pthread_getname_np
/// 取好并存入 namePool，因为取名字同样不该发生在挂起期间。
static void dcl_append_frame(NSMutableString *out, int idx, uint64_t addr) {
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr((const void *)addr, &info)) {
        NSString *img = info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname].lastPathComponent : @"(未知)";
        int64_t off = info.dli_fbase ? (int64_t)(addr - (uint64_t)info.dli_fbase) : 0;
        if (info.dli_sname) {
            [out appendFormat:@"   %d  0x%llx %@ + %lld  <%s>\n",
                                idx, (unsigned long long)addr, img, (long long)off, info.dli_sname];
        } else {
            [out appendFormat:@"   %d  0x%llx %@ + %lld  <redacted>\n",
                                idx, (unsigned long long)addr, img, (long long)off];
        }
    } else {
        [out appendFormat:@"   %d  0x%llx <redacted>\n", idx, (unsigned long long)addr];
    }
}

/// 只收集一个线程的原始返回地址，不做任何格式化 / 分配 / 符号化。
///
/// 这是整个快照里唯一允许在「其他线程被 suspend」状态下执行的操作：
/// 函数体内只有 thread_get_state 与 mach_vm_read_overwrite，两者都是直接陷入内核的
/// 系统调用，不经过 malloc、不经过 dyld。
///
/// 为什么必须这么苛刻：被 suspend 的线程随时可能正持有 malloc 的全局锁或 dyld 锁。
/// 若在这段窗口里做一次 dladdr 或 NSMutableString 拼接，就会等一把永远不会被释放的锁
/// —— 宿主表现为彻底无响应，且不产生任何崩溃日志，是所有故障里最难归因的一种。
///
/// 返回实际收集到的帧数；调用方需提供至少 maxFrames 个 uint64_t 的空间。
static int dcl_collect_thread_addrs(thread_t t, uint64_t *out, int maxFrames) {
    _STRUCT_MCONTEXT mc;
    mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(t, ARM_THREAD_STATE64, (thread_state_t)&mc.__ss, &sc) != KERN_SUCCESS) {
        return 0;
    }

    uint64_t pc = dcl_strip(mc.__ss.__pc);
    uint64_t lr = dcl_strip(mc.__ss.__lr);
    uint64_t fp = dcl_strip(mc.__ss.__fp);

    int n = 0;
    out[n++] = pc;
    if (lr && lr != pc && n < maxFrames) out[n++] = lr;

    uint64_t cur = fp;
    int guard = 0;
    while (n < maxFrames && cur != 0 && guard++ < maxFrames * 2) {
        uint64_t savedFp = 0, savedLr = 0;
        if (!dcl_read_mem(cur, &savedFp, 8)) break;
        if (!dcl_read_mem(cur + 8, &savedLr, 8)) break;
        savedLr = dcl_strip(savedLr);
        savedFp = dcl_strip(savedFp);
        if (savedLr == 0) break;
        out[n++] = savedLr;
        if (savedFp <= cur) break;
        cur = savedFp;
    }
    return n;
}

/// 第三方注入镜像判定：非系统、非 dyld 缓存、非宿主主可执行文件的镜像
static BOOL dcl_is_third_party_image(const char *path) {
    if (!path || !*path) return NO;
    if (strncmp(path, "/System/", 8) == 0) return NO;
    if (strncmp(path, "/usr/lib/", 9) == 0) return NO;
    if (strncmp(path, "/usr/libexec/", 13) == 0) return NO;
    // 宿主主可执行文件
    const char *exec = _dyld_get_image_name(0);
    if (exec && strcmp(path, exec) == 0) return NO;
    // App 自身 bundle 内的 framework / dylib
    NSString *execPath = exec ? [NSString stringWithUTF8String:exec] : @"";
    NSString *bundle = [execPath stringByDeletingLastPathComponent];
    if (bundle.length && [[NSString stringWithUTF8String:path] hasPrefix:bundle]) return NO;
    return YES;
}

/// 依据调用栈归因卡顿成因
static DCLStallCause dcl_analyze(NSArray<NSString *> *stack, NSString **suspectOut) {
    NSString *suspect = @"";
    BOOL third = NO, lock = NO, io = NO, mach = NO, uiEvent = NO;

    for (NSUInteger i = 0; i < stack.count && i < 12; i++) {
        NSString *line = stack[i];
        if ([line containsString:@"__psynch_mutexwait"] ||
            [line containsString:@"__ulock_wait"] ||
            [line containsString:@"semaphore_wait_trap"] ||
            [line containsString:@"_pthread_mutex_lock"]) {
            lock = YES;
        }
        if ([line containsString:@"mach_msg_trap"] || [line containsString:@"mach_msg "]) mach = YES;
        if ([line containsString:@" fsync"] || [line containsString:@" read"] ||
            [line containsString:@" write"] || [line containsString:@" mmap"] ||
            [line containsString:@" msync"] || [line containsString:@" open"]) {
            // 只认 libc 系统调用包装，避免误判 App 同名方法
            if ([line containsString:@"libsystem"]) io = YES;
        }
        if ([line containsString:@"sendEvent"] || [line containsString:@"sendActionsFor"] ||
            [line containsString:@"touchesBegan"] || [line containsString:@"UIGestureRecognizer"]) {
            uiEvent = YES;
        }
        NSArray *parts = [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (parts.count >= 3) {
            NSString *img = parts[2];
            if (img.length && !third) {
                // 反查完整路径判断是否第三方
                NSString *low = img.lowercaseString;
                if ([low hasSuffix:@".dylib"] && ![low hasPrefix:@"lib"] ) {
                    third = YES; suspect = img;
                } else if ([DCLWatchdog isThirdPartyImageNamed:img]) {
                    third = YES; suspect = img;
                }
            }
        }
    }
    *suspectOut = suspect;

    if (third) return DCLStallCauseThirdParty;
    if (lock)   return DCLStallCauseLockWait;
    if (io)     return DCLStallCauseSystemIO;
    if (mach)   return DCLStallCauseMachWait;
    if (uiEvent) return DCLStallCauseTouchHandler;
    return DCLStallCauseUnknown;
}

#pragma mark - 看门狗线程

/// sampled：本次卡顿是否真的取到过主线程栈。
/// A 方案（safe）不 suspend 主线程采样，此时任何「栈顶不变 = 死等」之类的结论
/// 都是凭空得出的 —— 必须据此屏蔽，宁可写「未采集」，也不能给假结论。
static void dcl_record_stall(uint64_t startUs, uint64_t endUs,
                             NSArray<NSString *> *stack, BOOL sampled, BOOL pcStable,
                             DCLStallCause cause, NSString *suspect) {
    DCLStallRecord *r = [[DCLStallRecord alloc] init];
    r.startedAtUnix = (NSTimeInterval)(startUs / 1000000ULL)
                    + (NSTimeInterval)(startUs % 1000000ULL) / 1000000.0;
    r.durationMs = (double)(endUs - startUs) / 1000.0;
    r.stack = stack ?: @[];
    r.pcStable = sampled ? pcStable : NO;   // 未采样时不得声称「栈顶不变」
    r.cause = cause;
    r.suspectImage = suspect ?: @"";

    uint64_t touch = g_last_touch_us;
    r.msSinceLastTouch = touch ? (double)((int64_t)startUs - (int64_t)touch) / 1000.0 : -1.0;

    NSString *causeText = @"原因不明";
    switch (cause) {
        case DCLStallCauseTouchHandler: causeText = @"主线程停在自己的事件处理里"; break;
        case DCLStallCauseThirdParty:   causeText = @"主线程栈中出现第三方注入库"; break;
        case DCLStallCauseLockWait:     causeText = @"主线程在等互斥锁/信号量"; break;
        case DCLStallCauseSystemIO:     causeText = @"主线程卡在文件 IO 系统调用"; break;
        case DCLStallCauseMachWait:     causeText = @"主线程卡在 mach 消息等待"; break;
        case DCLStallCauseLongCompute:  causeText = @"主线程在持续执行计算/渲染（非阻塞等待）"; break;
        case DCLStallCauseUnknown:      causeText = sampled ? @"无法归因"
                                                            : @"无法归因（未采集主线程栈）"; break;
    }
    NSMutableString *v = [NSMutableString stringWithString:causeText];
    if (suspect.length) [v appendFormat:@"，嫌疑模块：%@", suspect];
    if (r.msSinceLastTouch >= 0 && r.msSinceLastTouch <= 300.0) {
        [v appendFormat:@"，且发生在触摸后 %.0f ms —— 指向触摸处理链阻塞", r.msSinceLastTouch];
    }
    if (sampled && pcStable) [v appendString:@"，多次采样栈顶不变 —— 属于死等，非慢调用"];
    if (!sampled) [v appendString:@"；如需定位卡在哪一步，请切到 B 方案 full 抓取主线程栈"];
    r.verdict = v;

    pthread_mutex_lock(&g_stalls_lock);
    if (!g_stalls) g_stalls = [NSMutableArray array];
    [g_stalls addObject:r];
    while (g_stalls.count > 6) [g_stalls removeObjectAtIndex:0];
    pthread_mutex_unlock(&g_stalls_lock);
}

static void dcl_watchdog_main(void) {
    uint64_t stallStart = 0;
    int samples = 0;
    uint64_t firstPc = 0;
    BOOL pcStable = YES;
    uint64_t lastForcedLogUs = 0;   // 上一次「持续性卡死」强制落盘的时间
    NSArray<NSString *> *lastStack = nil;

    for (;;) {
        g_watchdog_alive_us = dcl_now_us();
        usleep(kPollIntervalUs);

        if (g_backgrounded) { stallStart = 0; samples = 0; continue; }

        uint64_t hb = g_main_heartbeat_us;
        CFRunLoopActivity act = g_last_activity;
        if (hb == 0) continue;   // 尚未接管主线程

        // 主线程正在 mach_msg 休眠 = 合法空闲，不判定卡顿
        BOOL idle = (act == kCFRunLoopBeforeWaiting || act == kCFRunLoopExit);
        uint64_t now = dcl_now_us();
        BOOL stuck = (!idle && (now - hb) > kStallThresholdUs);

        if (stuck && stallStart == 0) {
            stallStart = hb; samples = 0; pcStable = YES; firstPc = 0; lastStack = nil;
        }

        // 栈采样会 suspend 主线程 —— 仅 B 方案（full）开启。
        // A 方案（safe）只记录「卡了多久」，不碰主线程，也不做符号化。
        if (dcl_deep_evidence() && stuck && samples < kMaxSamplesPerStall) {
            uint64_t addrs[DCL_MAX_FRAMES]; int n = 0;
            dcl_sample_main_thread(addrs, &n);
            if (n > 0) {
                if (samples == 0) firstPc = addrs[0];
                else if (addrs[0] != firstPc) pcStable = NO;
                lastStack = dcl_symbolize(addrs, n);
                samples++;
                if (samples < kMaxSamplesPerStall) usleep(kSampleIntervalUs);
            }
        }

        if (!stuck && stallStart != 0) {
            NSArray *stack = lastStack ?: @[];
            NSString *suspect = @"";
            DCLStallCause cause = dcl_analyze(stack, &suspect);
            if (!pcStable && cause == DCLStallCauseUnknown) cause = DCLStallCauseLongCompute;
            dcl_record_stall(stallStart, now, stack, (samples > 0), pcStable, cause, suspect);
            // 卡死结束即抓取全线程快照（冻结取证上下文），供 latest.log 复现。
            // 同样只在 B 方案下发生 —— suspend 其余线程属于有侵入的取证动作。
            // 注意：本函数是 static C 函数，没有隐式的 self，必须写类名。
            if (dcl_deep_evidence()) [DCLWatchdog captureAndStoreAllThreadsSnapshot];
            stallStart = 0; samples = 0; lastStack = nil;
        }

        // 长时间持续性卡死（超过 10s 仍未恢复）：立即落盘一次，别等到用户触发。
        // A 方案下 samples 恒为 0（不采样），因此改用「距上次落盘 ≥10s」节流，
        // 否则这里会每 200ms 重复记一条。
        BOOL samplingDone = (!dcl_deep_evidence()) || (samples >= kMaxSamplesPerStall);
        if (stuck && stallStart != 0 && (now - stallStart) > 10 * 1000000ULL &&
            samplingDone && (now - lastForcedLogUs) > 10 * 1000000ULL) {
            NSArray *stack = lastStack ?: @[];
            NSString *suspect = @"";
            BOOL sampled = (samples > 0);
            DCLStallCause cause = dcl_analyze(stack, &suspect);
            // 与「卡死结束」路径保持一致：只有真的采样过，才能据栈顶变化推断长计算
            if (sampled && !pcStable && cause == DCLStallCauseUnknown) cause = DCLStallCauseLongCompute;
            dcl_record_stall(stallStart, now, stack, sampled, pcStable, cause, suspect);
            if (dcl_deep_evidence()) [DCLWatchdog captureAndStoreAllThreadsSnapshot];
            lastForcedLogUs = now;
            samples = 0;   // 允许继续采样观察
            usleep(kSampleIntervalUs * 4);
        }
    }
}

#pragma mark - DCLWatchdog

@implementation DCLWatchdog

+ (BOOL)isThirdPartyImageNamed:(NSString *)imageName {
    if (!imageName.length) return NO;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *p = _dyld_get_image_name(i);
        if (!p) continue;
        NSString *full = [NSString stringWithUTF8String:p];
        if ([full.lastPathComponent isEqualToString:imageName]) {
            return dcl_is_third_party_image(p);
        }
    }
    return NO;
}

+ (void)install {
    if (g_installed) return;
    // 主线程校验必须发生在置位之前：否则一旦被非主线程误调，
    // installed 已置 1 却什么都没装，此后永远不再重试 —— 整条链路静默失效。
    if (![NSThread isMainThread]) return;
    if (__sync_fetch_and_or(&g_installed, 1)) return;
    @try {
        g_main_thread = mach_thread_self();
        g_main_heartbeat_us = dcl_now_us();
        g_stalls = [NSMutableArray array];

        CFRunLoopObserverContext ctx = {0, NULL, NULL, NULL, NULL};
        g_loop_observer = CFRunLoopObserverCreate(NULL,
                                                  kCFRunLoopEntry | kCFRunLoopBeforeSources |
                                                  kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting |
                                                  kCFRunLoopExit,
                                                  YES, 0, &dcl_loop_activity, &ctx);
        if (g_loop_observer) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), g_loop_observer, kCFRunLoopCommonModes);
        }

        g_watchdog_thread = [[NSThread alloc] initWithTarget:self
                                                    selector:@selector(dcl_threadEntry)
                                                      object:nil];
        g_watchdog_thread.name = @"DCLWatchdog";
        g_watchdog_thread.qualityOfService = NSQualityOfServiceBackground;
        g_watchdog_alive_us = dcl_now_us();
        [g_watchdog_thread start];
    } @catch (id e) {
        (void)e;
    }
}

+ (void)dcl_threadEntry {
    @autoreleasepool {
        @try {
            // sigaltstack 是 per-thread 的：本线程也要装，
            // 否则本线程若发生栈溢出崩溃，处理器会在已损坏的栈上二次崩溃。
            [DCLCrashReporter installSignalStackOnCurrentThread];
        } @catch (id e) { (void)e; }
        @try { dcl_watchdog_main(); }
        @catch (id e) { (void)e; }
    }
}

+ (void)noteTouch {
    g_last_touch_us = dcl_now_us();
}

+ (NSTimeInterval)lastTouchUnix {
    uint64_t t = g_last_touch_us;
    return t ? (NSTimeInterval)(t / 1000000ULL) + (NSTimeInterval)(t % 1000000ULL) / 1000000.0 : 0;
}

+ (void)pauseForBackground  { __sync_fetch_and_or(&g_backgrounded, 1); }
+ (void)resumeFromForeground { __sync_fetch_and_and(&g_backgrounded, 0); g_main_heartbeat_us = dcl_now_us(); }

+ (BOOL)isRunning {
    uint64_t t = g_watchdog_alive_us;
    if (!t) return NO;
    return (dcl_now_us() - t) < 3 * 1000000ULL;
}

+ (double)watchdogHeartbeatAgeSec {
    uint64_t t = g_watchdog_alive_us;
    return t ? (double)(dcl_now_us() - t) / 1000000.0 : -1.0;
}

+ (double)mainLoopHeartbeatAgeSec {
    uint64_t t = g_main_heartbeat_us;
    return t ? (double)(dcl_now_us() - t) / 1000000.0 : -1.0;
}

+ (NSUInteger)stallCount {
    pthread_mutex_lock(&g_stalls_lock);
    NSUInteger c = g_stalls.count;
    pthread_mutex_unlock(&g_stalls_lock);
    return c;
}

+ (NSArray<DCLStallRecord *> *)recentStalls {
    pthread_mutex_lock(&g_stalls_lock);
    NSArray *a = [g_stalls copy] ?: @[];
    pthread_mutex_unlock(&g_stalls_lock);
    return a;
}

+ (double)measureMainThreadResponseMs {
    if ([NSThread isMainThread]) return 0.0;   // 从主线程调用会死锁，直接放弃测量
    // 用 atomic 而非普通 BOOL：跨线程读写 + 自旋等待，普通变量在 -O2 下
    // 可能被优化成「读一次就判死循环」，表现为永远等满 3 秒后误报超时。
    __block _Atomic(BOOL) done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ atomic_store(&done, YES); });
    uint64_t t0 = dcl_now_us();
    NSUInteger spins = 0;
    // 最多等 3 秒，避免测量本身把调用者挂死
    while (!atomic_load(&done) && spins < 3000) { usleep(1000); spins++; }
    return atomic_load(&done) ? (double)(dcl_now_us() - t0) / 1000.0 : -1.0;
}

#pragma mark - 全线程快照

+ (NSString *)captureAllThreadsSnapshot {
    // A 方案（safe，零 hook）不做线程级取证：枚举并短暂 suspend 其余线程属于
    // 有侵入的动作，与「零 hook 档尽可能不碰进程」的定位冲突。
    // 需要这份快照时，把 capture_mode.txt 改成 full 重启即可。
    if (!dcl_deep_evidence()) return nil;

    // —— 阶段 0（未挂起任何线程）：先把全部内存分配完 ——
    thread_act_array_t list = NULL;
    mach_msg_type_number_t cnt = 0;
    if (task_threads(mach_task_self(), &list, &cnt) != KERN_SUCCESS || list == NULL || cnt == 0) {
        if (list) {
            vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_t));
        }
        return nil;
    }

    const int maxFrames = DCL_MAX_FRAMES;
    uint64_t *addrs    = (uint64_t *)calloc((size_t)cnt * (size_t)maxFrames, sizeof(uint64_t));
    int      *counts   = (int *)calloc((size_t)cnt, sizeof(int));
    char     *namePool = (char *)calloc((size_t)cnt * 128, sizeof(char));
    char     *suspFlag = (char *)calloc((size_t)cnt, 1);

    if (!addrs || !counts || !namePool || !suspFlag) {
        free(addrs); free(counts); free(namePool); free(suspFlag);
        for (mach_msg_type_number_t i = 0; i < cnt; i++) {
            mach_port_deallocate(mach_task_self(), list[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_t));
        return nil;
    }

    thread_t self_t = mach_thread_self();

    // 线程名同样在挂起前取：pthread_getname_np 只写缓冲区，不分配内存
    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        char *slot = namePool + (size_t)i * 128;
        pthread_t pt = pthread_from_mach_thread_np(list[i]);
        if (pt) pthread_getname_np(pt, slot, 128);
    }

    // —— 阶段 1：挂起（跳过自身与主线程：挂起自己必死锁，挂起主线程会冻结 UI）——
    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        if (list[i] == self_t || list[i] == g_main_thread) continue;
        if (thread_suspend(list[i]) == KERN_SUCCESS) suspFlag[i] = 1;
    }

    // —— 阶段 2：只收集原始地址。窗口内不分配、不符号化、不发 OC 消息 ——
    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        counts[i] = dcl_collect_thread_addrs(list[i], addrs + (size_t)i * (size_t)maxFrames, maxFrames);
    }

    // —— 阶段 3：无条件全部恢复。此后才允许任何会拿锁的操作 ——
    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        if (suspFlag[i]) thread_resume(list[i]);
    }

    mach_port_deallocate(mach_task_self(), self_t);
    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        mach_port_deallocate(mach_task_self(), list[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_t));

    // —— 阶段 4：符号化与拼接。此刻没有任何线程处于挂起态 ——
    NSMutableString *out = [NSMutableString string];
    @try {
        NSDate *now = [NSDate date];
        [out appendFormat:@"===== 全线程快照 %@ +0000 =====\n", now];
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"(未知)";
        [out appendFormat:@"进程：%@\n\n", proc];

        for (mach_msg_type_number_t i = 0; i < cnt; i++) {
            const char *nm = namePool + (size_t)i * 128;
            BOOL isMain = (counts[i] >= 0) && (i == 0);   // 索引 0 通常是主线程
            if (nm[0]) {
                [out appendFormat:@"线程 #%u [%s]\n", (unsigned)i, nm];
            } else if (isMain) {
                [out appendFormat:@"线程 #%u [主线程]\n", (unsigned)i];
            } else {
                [out appendFormat:@"线程 #%u (无名)\n", (unsigned)i];
            }
            int n = counts[i];
            for (int f = 0; f < n; f++) {
                dcl_append_frame(out, f, addrs[(size_t)i * (size_t)maxFrames + f]);
            }
            [out appendString:@"\n"];
        }

        [out appendFormat:@"说明：符号被 strip 的帧显示 <redacted>；可用 atos 还原 —— "
                            @"atos -o <宿主二进制> -l <镜像基址> -arch arm64 <栈地址>\n"];
        [out appendFormat:@"本快照共 %u 个线程。\n", (unsigned)cnt];
        [out appendString:@"采集方式：先挂起全部非主线程，仅读取寄存器与栈上返回地址"
                          @"（纯内核调用），恢复所有线程后才做符号化 —— "
                          @"挂起窗口内不触碰 malloc/dyld 锁，避免与宿主互等。\n"];
    } @catch (id e) {
        (void)e;
    }

    free(addrs); free(counts); free(namePool); free(suspFlag);
    return out;
}

+ (void)captureAndStoreAllThreadsSnapshot {
    NSString *s = [self captureAllThreadsSnapshot];
    if (s.length) {
        pthread_mutex_lock(&g_snap_lock);
        g_last_all_threads_snapshot = s;
        pthread_mutex_unlock(&g_snap_lock);
    }
}

+ (nullable NSString *)lastAllThreadsSnapshot {
    pthread_mutex_lock(&g_snap_lock);
    NSString *r = g_last_all_threads_snapshot;
    pthread_mutex_unlock(&g_snap_lock);
    return r;
}

@end
