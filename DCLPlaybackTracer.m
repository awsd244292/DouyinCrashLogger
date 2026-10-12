//
//  DCLPlaybackTracer.m
//  DouyinCrashLogger
//

#import "DCLPlaybackTracer.h"
#import "DCLWatchdog.h"
#import "DCLSupport.h"   // DCLNowUs / DCLReplaceInstanceMethod —— 不再各模块自己抄一份
#import "DCLTimeline.h"  // 所有探针共用同一条时间线 —— 事件必须能在同一条轴上比对

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <stdio.h>        // snprintf（时间线打点用）
#import <execinfo.h>
#import <mach-o/dyld.h>   // _dyld_image_count / _dyld_get_image_name
#import <string.h>
#import <sys/time.h>

#define DCL_BT_DEPTH 24

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

    uint64_t now = DCLNowUs();

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
        // 时间线打点必须排在 backtrace 之前：它是定长写入、微秒级、零分配，
        // 而回溯是钩子体里唯一的重活。即便后续环节出问题，这条时间点也已经落地，
        // 「什么时候发生的」不会因为「归因失败」而一起丢掉。
        DCLTimelineEventKind k = DCLTlKindPauseHook;
        if ([action isEqualToString:@"play"]) k = DCLTlKindPlayHook;
        else if ([action hasPrefix:@"replaceCurrentItem"]) k = DCLTlKindItemReplace;
        char tbuf[96];
        snprintf(tbuf, sizeof(tbuf), "%s rate=%.2f %s",
                 action.UTF8String, (double)after, [NSThread isMainThread] ? "主线程" : "子线程");
        DCLTimelineRecordC(k, (int32_t)(after * 100.0f), tbuf);

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

#pragma mark - AVPlayer 实例化探针（坐实「抖音走不走系统播放器」）

// 这一组钩子不参与归因，只回答一个是非题：
//   本会话到底有没有 AVPlayer 实例被创建出来？
// 刷完整一轮视频后看时间线里有没有「AVPlayer实例」这一行 ——
//   有  → 主播放确实走系统播放器，pause 钩子没命中就该从别处找原因；
//   没有 → 高度怀疑自研引擎，钩子命中不了是「蹲错楼层」而非「钩子写漏」，
//          别再往 AVPlayer 上加钩子了，加多少都是零。
// 相比纯经验判断「抖音大概不用 AVPlayer」，这给了个可验证的事实。

static id (*dcl_orig_initWithItem_fn)(id, SEL, id) = NULL;
static id dcl_initWithItem(id self, SEL _cmd, AVPlayerItem *item) {
    DCLTimelineRecordC(DCLTlKindAVPlayerSeen, 1, "initWithPlayerItem: 被创建");
    if (dcl_orig_initWithItem_fn) return dcl_orig_initWithItem_fn(self, _cmd, item);
    return nil;
}

static id (*dcl_orig_initWithURL_fn)(id, SEL, id) = NULL;
static id dcl_initWithURL(id self, SEL _cmd, NSURL *url) {
    DCLTimelineRecordC(DCLTlKindAVPlayerSeen, 2, "initWithURL: 被创建");
    if (dcl_orig_initWithURL_fn) return dcl_orig_initWithURL_fn(self, _cmd, url);
    return nil;
}

/// UIApplication sendEvent: —— 只做一件事：记录触摸时刻。
/// 事件对象无条件转发给原始实现，连返回值都不改。
static void (*dcl_orig_sendEvent_fn)(id, SEL, id) = NULL;
static void dcl_sendEvent(id self, SEL _cmd, UIEvent *event) {
    [DCLWatchdog noteTouch];
    // 触摸时间线：单独一条记录，用于在时间线上判定「暂停紧随触摸发生 = 用户主动」。
    // 事件类型写进 aux，方便区分是按下还是抬起（暂停多由抬起触发）。
    DCLTimelineRecordC(DCLTlKindTouch, (int32_t)(event ? (int)event.type : -1), "UIEvent 分发");
    if (dcl_orig_sendEvent_fn) dcl_orig_sendEvent_fn(self, _cmd, event);
}

#pragma mark - 挂载

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
            // typeEncoding 一律传 NULL：沿用宿主的真实编码（"v16@0:8" 这类带偏移的写法），
            // 手写 "v@:" 会把 runtime 里的方法签名改掉，是没必要又难以察觉的风险。
            if (DCLReplaceInstanceMethod(playerCls, @selector(pause), NULL, (void *)dcl_pause, (void **)&dcl_orig_pause_fn)) g_hook_count++;
            if (DCLReplaceInstanceMethod(playerCls, @selector(play), NULL, (void *)dcl_play, (void **)&dcl_orig_play_fn)) g_hook_count++;
            if (DCLReplaceInstanceMethod(playerCls, @selector(setRate:), NULL, (void *)dcl_setRate, (void **)&dcl_orig_setRate_fn)) g_hook_count++;
            if (DCLReplaceInstanceMethod(playerCls, @selector(replaceCurrentItemWithPlayerItem:),
                             NULL, (void *)dcl_replaceItem, (void **)&dcl_orig_replaceItem_fn)) g_hook_count++;

            // 实例化探针（坐实是否走系统播放器，见上方说明）
            if (DCLReplaceInstanceMethod(playerCls, @selector(initWithPlayerItem:), NULL,
                             (void *)dcl_initWithItem, (void **)&dcl_orig_initWithItem_fn)) g_hook_count++;
            if (DCLReplaceInstanceMethod(playerCls, @selector(initWithURL:), NULL,
                             (void *)dcl_initWithURL, (void **)&dcl_orig_initWithURL_fn)) g_hook_count++;
        }

        // 触摸入口：唯一的额外动作就是打个时间戳。
        // 挂载层同样要从「当前 App 实例」向上找真正实现 sendEvent: 的那一层 ——
        // 宿主用自定义 UIApplication 子类重写它的话，只钩 UIApplication 本类是收不到事件的。
        Class appRootCls = NSClassFromString(@"UIApplication");
        id app = nil;
        if (appRootCls && [appRootCls respondsToSelector:@selector(sharedApplication)]) {
            app = [appRootCls sharedApplication];
        }
        Class eventOwner = DCLMostDerivedMethodOwner(app, @selector(sendEvent:), appRootCls)
                           ?: appRootCls;
        if (eventOwner &&
            DCLReplaceInstanceMethod(eventOwner, @selector(sendEvent:), NULL,
                                     (void *)dcl_sendEvent, (void **)&dcl_orig_sendEvent_fn)) {
            g_hook_count++;
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
