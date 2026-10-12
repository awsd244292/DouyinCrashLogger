//
//  DCLSystemSignal.m
//  DouyinCrashLogger
//
//  实现说明：
//    1) 全部走 NSNotificationCenter 系统通知，不碰任何方法实现。
//    2) 通知回调里只做一件事 —— 往时间线打一条点。绝不做 IO、符号化、
//       任何可能反噬宿主的重活（回调跑在主线程上，卡了就是我们在制造卡顿）。
//    3) 每条事件都带 aux 数值：中断类型、路由变更原因、通知子类型等，
//       让「为什么停」在系统层就能定位到具体原因，而不是一句「收到通知」。
//

#import "DCLSystemSignal.h"
#import "DCLTimeline.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static volatile int32_t g_ss_installed = 0;
static volatile uint32_t g_ss_count = 0;
static NSArray<NSString *> *g_av_subclasses = nil;

#pragma mark - 辅助

/// aux 字段塞 int32，通知子类型（NSUInteger）收敛后再放，避免溢出成负数
static inline int32_t dcl_aux_from(NSUInteger v) {
    return (int32_t)(v > 1000000U ? 1000000U : v);
}

#pragma mark - AVPlayer 子类枚举（只读 runtime）

/// 类方法定义必须在 @implementation 内 —— 这里放进实现区，
/// 供 install / signalSummary 调用（同实现内方法 clang 两遍扫描，顺序无所谓）。
static NSArray<NSString *> *dcl_av_player_subclasses(void) {
    if (g_av_subclasses) return g_av_subclasses;

    Class avPlayerCls = NSClassFromString(@"AVPlayer");
    if (!avPlayerCls) { g_av_subclasses = @[]; return g_av_subclasses; }

    NSMutableArray *out = [NSMutableArray array];
    @try {
        int num = objc_getClassList(NULL, 0);
        if (num > 0) {
            Class *buf = (Class *)calloc((size_t)num, sizeof(Class));
            if (buf) {
                num = objc_getClassList(buf, num);
                for (int i = 0; i < num; i++) {
                    Class c = buf[i];
                    if (!c) continue;
                    // 只取直接/间接继承 AVPlayer 的类，排除 AVPlayer 自身
                    if (c == avPlayerCls) continue;
                    Class superCls = c;
                    BOOL hit = NO;
                    // 向上最多找 8 层：够覆盖真实继承链，也避免异常链导致死循环
                    for (int depth = 0; depth < 8 && superCls; depth++) {
                        superCls = class_getSuperclass(superCls);
                        if (superCls == avPlayerCls) { hit = YES; break; }
                    }
                    if (hit) [out addObject:NSStringFromClass(c)];
                }
                free(buf);
            }
        }
    } @catch (id e) {
        (void)e;
    }
    g_av_subclasses = [out copy];
    return g_av_subclasses;
}

#pragma mark - 通知回调

static void dcl_ss_audio_interrupt(NSNotification *n) {
    @try {
        NSUInteger type = [[n.userInfo objectForKey:AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        BOOL began = (type == AVAudioSessionInterruptionTypeBegan);
        NSString *why = began ? @"中断开始（来电/其他音频抢占，播放通常随之暂停）"
                              : @"中断结束";
        NSUInteger opt = [[n.userInfo objectForKey:AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        if (!began && (opt & AVAudioSessionInterruptionOptionShouldResume)) {
            why = @"中断结束，系统建议恢复播放";
        }
        DCLTimelineRecordC(DCLTlKindAudioInterrupt, began ? 1 : 0, why.UTF8String);
    } @catch (id e) {
        DCLTimelineRecordC(DCLTlKindAudioInterrupt, -1, "音频中断（解析通知失败）");
    }
}

static void dcl_ss_route_change(NSNotification *n) {
    @try {
        NSUInteger reason = [[n.userInfo objectForKey:AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
        NSString *why = @"音频路由变更";
        switch (reason) {
            case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
                why = @"旧输出设备不可用（耳机拔掉/蓝牙断开，常见触发暂停）"; break;
            case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
                why = @"新输出设备可用"; break;
            case AVAudioSessionRouteChangeReasonCategoryChange:
                why = @"音频会话类别变更"; break;
            case AVAudioSessionRouteChangeReasonOverride:
                why = @"输出路由被覆盖"; break;
            case AVAudioSessionRouteChangeReasonWakeFromSleep:
                why = @"从休眠唤醒"; break;
            default:
                why = [NSString stringWithFormat:@"音频路由变更（原因 %lu）", (unsigned long)reason];
                break;
        }
        DCLTimelineRecordC(DCLTlKindAudioRouteChange, dcl_aux_from(reason), why.UTF8String);
    } @catch (id e) {
        DCLTimelineRecordC(DCLTlKindAudioRouteChange, -1, "音频路由变更（解析失败）");
    }
}

static void dcl_ss_background(NSNotification *n) {
    DCLTimelineRecordC(DCLTlKindEnterBackground, 0, "进入后台（视频通常随之暂停）");
}

static void dcl_ss_foreground(NSNotification *n) {
    DCLTimelineRecordC(DCLTlKindEnterForeground, 0, "回到前台");
}

static void dcl_ss_resign_active(NSNotification *n) {
    DCLTimelineRecordC(DCLTlKindResignActive, 0,
                       "即将失活（下拉通知栏/来电横幅/上滑多任务，视频常在此刻停）");
}

static void dcl_ss_become_active(NSNotification *n) {
    DCLTimelineRecordC(DCLTlKindBecomeActive, 0, "重新激活");
}

static void dcl_ss_lock(NSNotification *n) {
    DCLTimelineRecordC(DCLTlKindLockScreen, 0, "锁屏（受保护数据即将不可用，播放被系统挂起）");
}

static void dcl_ss_unlock(NSNotification *n) {
    DCLTimelineRecordC(DCLTlKindUnlockScreen, 0, "解锁");
}

static void dcl_ss_memory(NSNotification *n) {
    DCLTimelineRecordC(DCLTlKindMemoryWarning, 0, "内存警告（系统可能回收播放器资源）");
}

#pragma mark - 安装

@implementation DCLSystemSignal

+ (void)install {
    if (__sync_fetch_and_or(&g_ss_installed, 1)) return;

    @try {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        // —— 音频会话：系统打断的最直接证据 ——
        if (NSClassFromString(@"AVAudioSession")) {
            [nc addObserverForName:AVAudioSessionInterruptionNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) { dcl_ss_audio_interrupt(n); }];
            g_ss_count++;

            [nc addObserverForName:AVAudioSessionRouteChangeNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) { dcl_ss_route_change(n); }];
            g_ss_count++;
        }

        // —— App 生命周期：前后台 / 锁屏 ——
        struct { NSString *name; void (*fn)(NSNotification *); } pairs[] = {
            { UIApplicationDidEnterBackgroundNotification,                 dcl_ss_background   },
            { UIApplicationWillEnterForegroundNotification,                dcl_ss_foreground   },
            { UIApplicationWillResignActiveNotification,                   dcl_ss_resign_active},
            { UIApplicationDidBecomeActiveNotification,                    dcl_ss_become_active},
            // 注意：这两个常量的真实名字不带 Notification 后缀 ——
            // UIApplicationProtectedDataWillBecomeUnavailable / ...DidBecomeAvailable。
            // 与其余生命周期通知的命名并不一致，写错会让编译直接挂掉。
            { UIApplicationProtectedDataWillBecomeUnavailable, dcl_ss_lock         },
            { UIApplicationProtectedDataDidBecomeAvailable,    dcl_ss_unlock       },
            { UIApplicationDidReceiveMemoryWarningNotification,            dcl_ss_memory       },
        };
        for (NSUInteger i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
            if (!pairs[i].name) continue;
            // 先把函数指针取到局部变量再进 block：block 不允许引用数组类型的声明
            //（clang: cannot refer to declaration with an array type inside block），
            // 而 pairs[i].fn 的求值路径要经过数组。取出来之后捕获的是普通指针，合法。
            void (*fn)(NSNotification *) = pairs[i].fn;
            [nc addObserverForName:pairs[i].name
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) { if (fn) fn(n); }];
            g_ss_count++;
        }

        // —— 只读 runtime 摸底：抖音有没有基于 AVPlayer 的自研播放器 ——
        // 结果不写时间线（它不是事件而是事实），由 signalSummary 输出进日志。
        (void)[self avPlayerSubclasses];
    } @catch (id e) {
        (void)e;
    }
}

+ (NSArray<NSString *> *)avPlayerSubclasses {
    return dcl_av_player_subclasses();
}

+ (NSUInteger)registeredCount { return g_ss_count; }

+ (NSString *)signalSummary {
    NSArray<NSString *> *subs = [self avPlayerSubclasses];

    // 系统层各信号最近一次发生距现在多久 —— 回答「刚才那次暂停是不是系统打断的」
    struct { DCLTimelineEventKind kind; NSString *label; } probes[] = {
        { DCLTlKindAudioInterrupt,   @"音频中断"   },
        { DCLTlKindAudioRouteChange, @"路由变更"   },
        { DCLTlKindResignActive,     @"失活"       },
        { DCLTlKindEnterBackground,  @"进后台"     },
        { DCLTlKindLockScreen,       @"锁屏"       },
        { DCLTlKindMemoryWarning,    @"内存警告"   },
    };
    NSMutableString *ms = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        double d = [DCLTimeline millisecondsSinceLastKind:probes[i].kind];
        if (d < 0) continue;
        [ms appendFormat:@"%@%.0fms 前发生%@",
         ms.length ? @"；" : @"", d, probes[i].label];
    }

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"系统层观测点 %lu 个", (unsigned long)g_ss_count];

    if ([DCLTimeline avPlayerSeen]) {
        [s appendFormat:@"；本会话出现过 %lu 次 AVPlayer 实例（系统播放器路径确认存在）",
         (unsigned long)[DCLTimeline avPlayerSeenCount]];
    } else {
        [s appendString:@"；本会话未见任何 AVPlayer 实例（强烈提示走自研引擎，AVPlayer 钩子命中不了属预期）"];
    }

    if (subs.count) {
        [s appendFormat:@"；AVPlayer 子类：%@", [subs componentsJoinedByString:@", "]];
    } else {
        [s appendString:@"；运行时未枚举到 AVPlayer 子类"];
    }

    if (ms.length) {
        [s appendFormat:@"\n    最近的系统信号：%@", ms];
    }
    return s;
}

@end
