//
//  DCLPlaybackTracer.m
//  DouyinCrashLogger
//

#import "DCLPlaybackTracer.h"
#import "DCLWatchdog.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <execinfo.h>
#import <mach-o/dyld.h>   // _dyld_image_count / _dyld_get_image_name
#import <string.h>
#import <sys/time.h>

#define DCL_BT_DEPTH 24

static uint64_t dcl_now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
}

#pragma mark - 状态

static NSMutableArray<DCLPauseEvent *> *g_events = nil;
// 专用锁对象，永不为 nil：@synchronized(nil) 是不加锁的空操作，
// 用它保护容器等于没保护。
static NSObject *g_events_lock = nil;
static dispatch_queue_t g_symbolQueue = NULL;
static volatile int32_t g_installed = 0;
static volatile uint32_t g_hook_count = 0;

// 原始实现。刻意只 hook AVPlayer 基类：
// 若同时对多个自研播放器类替换同名 selector，它们的原始实现要共用同一个静态变量，
// 一旦某个类的实现被后来的覆盖，调用链就会指错 — 那是实质性的崩溃风险。
// AVPlayer 是 iOS 视频播放的事实底层，继承自它的自研播放器会被自动覆盖。

// 抑制表：同一 player 实例 500ms 窗口内只记一次。
// 刻意用定长 C 数组而非 NSMutableDictionary —— 钩子体里不做任何内存分配、不拿锁。
#define DCL_SUPP_SLOTS 32
typedef struct { uintptr_t obj; uint64_t ts; } DCLSuppEntry;
static volatile DCLSuppEntry g_supp[DCL_SUPP_SLOTS];
static volatile int32_t g_supp_seq = 0;

@implementation DCLPauseEvent
@end

#pragma mark - 工具

static BOOL dcl_is_path_third_party(const char *p) {
    if (!p || !*p) return NO;
    if (strncmp(p, "/System/", 8) == 0) return NO;
    if (strncmp(p, "/usr/lib/", 9) == 0) return NO;
    if (strncmp(p, "/usr/libexec/", 13) == 0) return NO;
    const char *exec = _dyld_get_image_name(0);
    if (exec && strcmp(p, exec) == 0) return NO;
    NSString *ep = exec ? [NSString stringWithUTF8String:exec] : @"";
    NSString *bundle = [ep stringByDeletingLastPathComponent];
    if (bundle.length && [[NSString stringWithUTF8String:p] hasPrefix:bundle]) return NO;
    return YES;
}

/// 后台队列里执行：符号化 + 归因
static void dcl_enqueue(NSString *action, float before, float after,
                        BOOL onMain, uint64_t nowUs, void **frames, int nframes) {
    if (!g_symbolQueue) return;
    uintptr_t addrs[DCL_BT_DEPTH];
    int n = nframes > DCL_BT_DEPTH ? DCL_BT_DEPTH : nframes;
    for (int i = 0; i < n; i++) addrs[i] = (uintptr_t)frames[i];

    // 地址打包成 NSData 再入队：block 对 C 数组的捕获语义不够明确，
    // 而这里要跨线程用到它 —— 交给 NSData 持有，生命周期没有歧义。
    NSData *packed = [NSData dataWithBytes:addrs length:(NSUInteger)n * sizeof(uintptr_t)];

    dispatch_async(g_symbolQueue, ^{
        @autoreleasepool {
            const uintptr_t *addrs = (const uintptr_t *)packed.bytes;
            NSMutableArray *lines = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
            BOOL thirdParty = NO;
            NSString *suspect = @"";
            BOOL uiEvent = NO, bgMove = NO, audioInt = NO, buffer = NO, appLogicFrame = NO;

            for (int i = 2; i < n; i++) {   // 跳过 hook 自身两帧
                Dl_info info;
                memset(&info, 0, sizeof(info));
                uintptr_t addr = addrs[i];
                NSString *img = @"(未知)";
                NSString *sym = @"";
                if (dladdr((const void *)addr, &info)) {
                    NSString *full = info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname] : @"";
                    img = full.lastPathComponent.length ? full.lastPathComponent : full;
                    int64_t off = info.dli_fbase ? (int64_t)(addr - (uintptr_t)info.dli_fbase) : 0;
                    if (info.dli_sname) sym = [NSString stringWithUTF8String:info.dli_sname];
                    [lines addObject:[NSString stringWithFormat:@"#%-2d 0x%llx %@ +%lld %@",
                                      i - 2, (unsigned long long)addr, img, (long long)off, sym]];
                    if (info.dli_fname && dcl_is_path_third_party(info.dli_fname) && !thirdParty) {
                        thirdParty = YES; suspect = img;
                    }
                } else {
                    [lines addObject:[NSString stringWithFormat:@"#%-2d 0x%llx (无法符号化)",
                                      i - 2, (unsigned long long)addr]];
                }

                // —— 归因关键字：全部在调用栈上做文本匹配 ——
                if ([sym containsString:@"sendActionsForControlEvents"] ||
                    [sym containsString:@"sendEvent"] ||
                    [sym containsString:@"touchesBegan"] ||
                    [sym containsString:@"UIGestureRecognizer"] ||
                    [sym containsString:@"_UIScrollView"] ||
                    [sym containsString:@"handleTap"] ||
                    [sym containsString:@"didTap"]) {
                    uiEvent = YES;
                }
                if ([sym containsString:@"applicationDidEnterBackground"] ||
                    [sym containsString:@"_applicationDidEnterBackground"] ||
                    [sym containsString:@"didEnterBackground"] ||
                    [sym containsString:@"applicationWillResignActive"]) {
                    bgMove = YES;
                }
                if ([sym containsString:@"AVAudioSession"] ||
                    [sym containsString:@"Interruption"] ||
                    [sym containsString:@"RouteChange"] ||
                    [sym containsString:@"notifyAudio"]) {
                    audioInt = YES;
                }
                if ([sym containsString:@"playbackBufferEmpty"] ||
                    [sym containsString:@"FailedToPlayToEndTime"] ||
                    [sym containsString:@"playerItemFailed"] ||
                    [sym containsString:@"stall"]) {
                    buffer = YES;
                }
                if ([sym hasPrefix:@"_dispatch_call_block_and_release"] ||
                    [sym containsString:@"CFRunLoopTimer"] ||
                    [sym containsString:@"NSTimer"] ||
                    [sym containsString:@"_block_invoke"]) {
                    appLogicFrame = YES;
                }
            }

            // —— 综合判决，优先级从高到低 ——
            DCLPauseSource src = DCLPauseSourceUnknown;
            NSString *ev = @"";

            uint64_t lastTouchUs = 0;
            NSTimeInterval tTouch = [DCLWatchdog lastTouchUnix];
            lastTouchUs = (uint64_t)(tTouch * 1000000.0);
            double msTouch = lastTouchUs ? (double)((int64_t)nowUs - (int64_t)lastTouchUs) / 1000.0 : -1.0;

            NSArray<DCLStallRecord *> *stalls = [DCLWatchdog recentStalls];
            double msStall = -1.0;
            if (stalls.count) {
                DCLStallRecord *last = stalls.lastObject;
                msStall = (nowUs / 1000.0) - (last.startedAtUnix * 1000.0
                                              + last.durationMs);
            }

            if (thirdParty) {
                src = DCLPauseSourceThirdPartyHook;
                ev = [NSString stringWithFormat:
                      @"调用栈第 3 方位置出现注入模块 %@ —— 暂停由该模块发起", suspect];
            } else if (audioInt) {
                src = DCLPauseSourceAudioInterrupt;
                ev = @"调用栈含 AVAudioSession / 中断处理帧 —— 系统音频会话变更导致";
            } else if (bgMove) {
                src = DCLPauseSourceBackgroundMove;
                ev = @"调用栈含 App 生命周期帧（进后台/失活）—— 随 App 切后台自然停止";
            } else if (buffer) {
                src = DCLPauseSourceBufferStall;
                ev = @"调用栈含缓冲耗尽/播放失败帧 —— 数据源问题导致的自动暂停";
            } else if (msStall >= 0 && msStall <= 1500.0) {
                src = DCLPauseSourceMainThreadStall;
                ev = [NSString stringWithFormat:
                      @"此次暂停发生在主线程卡死 %.0f ms 内 —— 画面是被冻结而非主动暂停", msStall];
            } else if (uiEvent) {
                src = DCLPauseSourceUserAction;
                ev = @"调用栈含 UIKit 事件分发帧（sendEvent/sendActions/touches）—— 用户触摸触发";
            } else if (appLogicFrame) {
                src = DCLPauseSourceHostAppLogic;
                ev = @"调用栈入口为定时器/dispatch 回调且无 UIKit 事件帧 —— 抖音自身业务逻辑自动暂停";
            } else {
                src = DCLPauseSourceUnknown;
                ev = @"调用栈未见明确来源特征，需人工结合下方原始栈分析";
            }

            DCLPauseEvent *e = [[DCLPauseEvent alloc] init];
            e.unixTime = (NSTimeInterval)(nowUs / 1000000ULL)
                       + (NSTimeInterval)(nowUs % 1000000ULL) / 1000000.0;
            e.action = action;
            e.rateBefore = before;
            e.rateAfter = after;
            e.onMainThread = onMain;
            e.msSinceLastTouch = msTouch;
            e.msSinceLastStall = msStall;
            e.source = src;
            e.suspectImage = suspect;
            e.stack = lines;
            e.evidence = ev;

            @synchronized (g_events_lock) {
                [g_events addObject:e];
                while (g_events.count > 8) [g_events removeObjectAtIndex:0];
            }
        }
    });
}

/// 钩子体的公共部分：轻量打点 + 收集回溯地址 + 入队
static inline void dcl_capture(id player, NSString *action, float before, float after) {
    // 重入保护：宿主原实现内部可能再次调用被钩方法（典型如 setRate: 内部走 pause）。
    // 刻意用线程局部变量而非全局标志 —— 钩子完全可能在多个线程并发进入，
    // 全局标志会把其他线程本该正常记录的调用也一并挡掉。
    static __thread int in_hook = 0;
    if (in_hook) return;
    in_hook = 1;

    uint64_t now = dcl_now_us();

    // 抑制同一实例的高频重复（滑视频时抖音会连续调 pause）。
    // 必须排在 backtrace 之前：回溯是钩子体里唯一的重活，
    // 先回溯再剪枝等于每次都白付一遍开销 —— 那就是真的在拖慢宿主了。
    uintptr_t key = (uintptr_t)(__bridge void *)player;
    BOOL allow = YES;
    for (int i = 0; i < DCL_SUPP_SLOTS; i++) {
        if (g_supp[i].obj == key) {
            if (now - g_supp[i].ts < 500000ULL) allow = NO;
            else g_supp[i].ts = now;
            key = 0;
            break;
        }
    }
    if (key != 0) {
        int slot = __sync_fetch_and_add(&g_supp_seq, 1) & (DCL_SUPP_SLOTS - 1);
        g_supp[slot].obj = key;
        g_supp[slot].ts = now;
    }

    if (allow) {
        // 栈上缓冲：绝不能用 static —— AVPlayer 的回调常在非主线程并发触发，
        // 静态缓冲会被多个线程同时写，采出来的栈是几路调用混在一起的假栈，
        // 基于它做的归因会指向完全错误的方向。
        void *frames[DCL_BT_DEPTH];
        int n = backtrace(frames, DCL_BT_DEPTH);
        BOOL onMain = [NSThread isMainThread];
        dcl_enqueue(action, before, after, onMain, now, frames, n);
    }

    in_hook = 0;
}

#pragma mark - 钩子实现（全部原样透传，绝不吞事件）

static void (*dcl_orig_pause_fn)(id, SEL) = NULL;
static void dcl_pause(id self, SEL _cmd) {
    dcl_capture(self, @"pause", 0.0f, 0.0f);
    if (dcl_orig_pause_fn) dcl_orig_pause_fn(self, _cmd);
}

static void (*dcl_orig_play_fn)(id, SEL) = NULL;
static void dcl_play(id self, SEL _cmd) {
    dcl_capture(self, @"play", 0.0f, 1.0f);
    if (dcl_orig_play_fn) dcl_orig_play_fn(self, _cmd);
}

static void (*dcl_orig_setRate_fn)(id, SEL, float) = NULL;
static void dcl_setRate(id self, SEL _cmd, float rate) {
    dcl_capture(self, @"setRate:", 0.0f, rate);
    if (dcl_orig_setRate_fn) dcl_orig_setRate_fn(self, _cmd, rate);
}

static void (*dcl_orig_replaceItem_fn)(id, SEL, id) = NULL;
static void dcl_replaceItem(id self, SEL _cmd, AVPlayerItem *item) {
    dcl_capture(self, @"replaceCurrentItemWithPlayerItem:", 0.0f, 0.0f);
    if (dcl_orig_replaceItem_fn) dcl_orig_replaceItem_fn(self, _cmd, item);
}

/// UIApplication sendEvent: —— 只做一件事：记录触摸时刻。
/// 事件对象无条件转发给原始实现，连返回值都不改。
static void (*dcl_orig_sendEvent_fn)(id, SEL, id) = NULL;
static void dcl_sendEvent(id self, SEL _cmd, UIEvent *event) {
    [DCLWatchdog noteTouch];
    if (dcl_orig_sendEvent_fn) dcl_orig_sendEvent_fn(self, _cmd, event);
}

#pragma mark - 挂载

/// 本类是否「自己拥有」该方法的实现（不含从父类继承来的）。
/// class_getInstanceMethod 会一路向上找到父类的实现，拿它去替换就会改到父类 ——
/// 那是会波及所有子类的实质性破坏，必须先排除这种情况。
static BOOL dcl_class_owns_method(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    BOOL owned = NO;
    if (list) {
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(list[i]) == sel) { owned = YES; break; }
        }
        free(list);
    }
    return owned;
}

static BOOL dcl_try_hook(Class cls, SEL sel, const char *typeEnc, void *newImp, void **outFn) {
    if (!cls) return NO;
    // 只替换本类自己的实现，绝不碰父类
    if (!dcl_class_owns_method(cls, sel)) return NO;

    IMP orig = class_replaceMethod(cls, sel, (IMP)newImp, typeEnc);
    // orig 为 NULL 说明本类原本没有实现（此时已被强行添加），
    // 后续钩子体将无处透传 —— 宁可不挂，也不能吞掉宿主行为。
    if (!orig) return NO;
    // 已挂过：再挂一次会让 orig 指向我们自己，形成自环
    if (orig == (IMP)newImp) return NO;

    *outFn = (void *)orig;
    return YES;
}

@implementation DCLPlaybackTracer

+ (BOOL)isThirdPartyImageNamed:(NSString *)imageName {
    if (!imageName.length) return NO;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *p = _dyld_get_image_name(i);
        if (!p) continue;
        NSString *full = [NSString stringWithUTF8String:p];
        if ([full.lastPathComponent isEqualToString:imageName]) return dcl_is_path_third_party(p);
    }
    return NO;
}

+ (void)install {
    if (__sync_fetch_and_or(&g_installed, 1)) return;
    @try {
        g_events = [NSMutableArray array];
        g_events_lock = [NSObject new];
        g_symbolQueue = dispatch_queue_create("com.dcl.symbolicate", DISPATCH_QUEUE_SERIAL);

        // AVFoundation 层：AVPlayer 是所有视频播放的汇聚点，继承自它的自研播放器自动被覆盖
        Class playerCls = NSClassFromString(@"AVPlayer");
        if (playerCls) {
            if (dcl_try_hook(playerCls, @selector(pause), "v@:", (void *)dcl_pause, (void **)&dcl_orig_pause_fn)) g_hook_count++;
            if (dcl_try_hook(playerCls, @selector(play), "v@:", (void *)dcl_play, (void **)&dcl_orig_play_fn)) g_hook_count++;
            if (dcl_try_hook(playerCls, @selector(setRate:), "v@f", (void *)dcl_setRate, (void **)&dcl_orig_setRate_fn)) g_hook_count++;
            if (dcl_try_hook(playerCls, @selector(replaceCurrentItemWithPlayerItem:),
                             "v@@", (void *)dcl_replaceItem, (void **)&dcl_orig_replaceItem_fn)) g_hook_count++;
        }

        // 触摸入口：唯一的额外动作就是打个时间戳
        Class uiAppCls = NSClassFromString(@"UIApplication");
        if (uiAppCls) {
            if (dcl_try_hook(uiAppCls, @selector(sendEvent:), "v@@",
                             (void *)dcl_sendEvent, (void **)&dcl_orig_sendEvent_fn)) {
                g_hook_count++;
            }
        }
    } @catch (id e) {
        (void)e;
    }
}

+ (NSArray<DCLPauseEvent *> *)recentEvents {
    @synchronized (g_events_lock) {
        return [[g_events reverseObjectEnumerator] allObjects] ?: @[];
    }
}

+ (NSUInteger)hookedCount { return g_hook_count; }

@end
