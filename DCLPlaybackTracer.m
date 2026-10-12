//
//  DCLPlaybackTracer.m
//  DouyinCrashLogger
//

#import "DCLPlaybackTracer.h"
#import "DCLWatchdog.h"
#import "DCLSupport.h"   // DCLNowUs / DCLReplaceInstanceMethod —— 不再各模块自己抄一份
#import "DCLTimeline.h"  // 所有探针共用同一条时间线 —— 事件必须能在同一条轴上比对
#import "DCLSystemSignal.h"  // 复用 AVPlayer 子类枚举（只读 runtime，零 hook）

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

#pragma mark - 播放器类绑定表（每个类各存一份原始实现）

// 为什么必须给「每个类」单独存一份原始实现：
//   过去所有钩子共用一个静态变量存 orig，于是只能挂 AVPlayer 一个基类。
//   但真机日志摆在这儿：运行时枚举到 HTSMediaMixPlayer / ISAVPlayer /
//   BDByteCastAVPlayer 等多个 AVPlayer 子类。子类一旦自己重写了 -pause 且不调 super，
//   消息就根本不会经过基类 —— 基类钩子形同虚设，视频停了却一条也抓不到。
//   而共享静态变量时给多个类替换同名 selector，后挂的会把先挂的 orig 覆盖掉，
//   调用链直接指错 —— 那是真崩溃风险，不是「可能」。
//   改成每个类一条绑定记录、各自持有自己的 orig，冲突从结构上就消失了。
//
// 安全边界：只对「自己实现了该方法」的类动手（DCLReplaceInstanceMethod 内部有此检查）。
//   子类没实现 pause → 消息本来就走继承来的实现（也就是我们挂在父类上的钩子），
//   既不重复挂，也不会形成自环。

#define DCL_MAX_PLAYER_CLASS 24

typedef struct {
    Class  cls;                 // NULL 表示空槽
    char   clsName[64];         // 钩子体内要写字面量到时间线，用 C 字符串避免任何内存分配
    void  *orig_pause;
    void  *orig_play;
    void  *orig_setRate;
    void  *orig_replaceItem;
    void  *orig_initWithItem;
    void  *orig_initWithURL;
} DCLPlayerBinding;

static DCLPlayerBinding g_bindings[DCL_MAX_PLAYER_CLASS];
// 只在挂载阶段（主线程串行）写；钩子体读取时用原子读。
// 顺序保证：先填完结构体内容，再推进计数 —— 读者看到计数就能安全读内容。
static volatile int32_t g_binding_count = 0;

// 尝试过但未挂上的类名（多为该类并未自己实现这些方法），留个出口便于事后核对。
static NSMutableArray<NSString *> *g_skipped = nil;

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
static void dcl_enqueue(NSString *action, const char *clsName, float before, float after,
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
            e.playerClass = clsName ? [NSString stringWithUTF8String:clsName] : @"";
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
static inline void dcl_capture(id player, NSString *action, const char *clsName,
                               float before, float after) {
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
        char tbuf[128];
        snprintf(tbuf, sizeof(tbuf), "%s rate=%.2f %s class=%s",
                 action.UTF8String, (double)after,
                 [NSThread isMainThread] ? "主线程" : "子线程",
                 clsName ?: "(未绑定)");
        DCLTimelineRecordC(k, (int32_t)(after * 100.0f), tbuf);

        // 栈上缓冲：绝不能用 static —— AVPlayer 的回调常在非主线程并发触发，
        // 静态缓冲会被多个线程同时写，采出来的栈是几路调用混在一起的假栈，
        // 基于它做的归因会指向完全错误的方向。
        void *frames[DCL_BT_DEPTH];
        int n = backtrace(frames, DCL_BT_DEPTH);
        BOOL onMain = [NSThread isMainThread];
        dcl_enqueue(action, clsName, before, after, onMain, now, frames, n);
    }

    in_hook = 0;
}

#pragma mark - 钩子实现（全部原样透传，绝不吞事件）

typedef void (*DCLVoidImp)(id, SEL);
typedef void (*DCLSetRateImp)(id, SEL, float);
typedef void (*DCLPtrArgImp)(id, SEL, id);
typedef id   (*DCLInitImp)(id, SEL, id);

/// 某个类是否已挂过钩子（挂载阶段用：重复替换同名 selector 会形成自环）
static DCLPlayerBinding *dcl_binding_for_class(Class cls) {
    if (!cls) return NULL;
    int32_t n = g_binding_count;
    for (int32_t i = 0; i < n; i++) {
        if (g_bindings[i].cls == cls) return &g_bindings[i];
    }
    return NULL;
}

/// 实例 → 绑定记录：沿继承链向上找最近一个挂了钩子的类。
/// 必须走继承链，因为以下两种情况精确匹配会落空：
///   1) KVO 是运行时搞出来的动态子类（NSKVONotifying_Xxx），表里查不到它，
///      它的父类才是我们挂钩子那一层；
///   2) 迟到的子类在被补挂之前就已实例化，此刻它走的是继承来的钩子，
///      按父类记录转发同样正确。
/// 正常情况下必然找得到 —— 能进到钩子函数，就说明某个类的方法 IMP 已被替换成它。
static DCLPlayerBinding *dcl_binding_for_object(id obj) {
    if (!obj) return NULL;
    Class cls = object_getClass(obj);
    while (cls) {
        DCLPlayerBinding *b = dcl_binding_for_class(cls);
        if (b) return b;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void dcl_pause(id self, SEL _cmd) {
    DCLPlayerBinding *b = dcl_binding_for_object(self);
    dcl_capture(self, @"pause", b ? b->clsName : NULL, 0.0f, 0.0f);
    if (b && b->orig_pause) ((DCLVoidImp)b->orig_pause)(self, _cmd);
}

static void dcl_play(id self, SEL _cmd) {
    DCLPlayerBinding *b = dcl_binding_for_object(self);
    dcl_capture(self, @"play", b ? b->clsName : NULL, 0.0f, 1.0f);
    if (b && b->orig_play) ((DCLVoidImp)b->orig_play)(self, _cmd);
}

static void dcl_setRate(id self, SEL _cmd, float rate) {
    DCLPlayerBinding *b = dcl_binding_for_object(self);
    dcl_capture(self, @"setRate:", b ? b->clsName : NULL, 0.0f, rate);
    if (b && b->orig_setRate) ((DCLSetRateImp)b->orig_setRate)(self, _cmd, rate);
}

static void dcl_replaceItem(id self, SEL _cmd, AVPlayerItem *item) {
    DCLPlayerBinding *b = dcl_binding_for_object(self);
    dcl_capture(self, @"replaceCurrentItemWithPlayerItem:", b ? b->clsName : NULL, 0.0f, 0.0f);
    if (b && b->orig_replaceItem) ((DCLPtrArgImp)b->orig_replaceItem)(self, _cmd, item);
}

#pragma mark - AVPlayer 实例化探针（坐实「抖音走不走系统播放器」）

// 这一组钩子不参与归因，只回答一个是非题：
//   本会话到底有没有 AVPlayer 实例被创建出来？
// 刷完整一轮视频后看时间线里有没有「AVPlayer实例」这一行 ——
//   有  → 主播放确实走系统播放器，pause 钩子没命中就该从别处找原因；
//   没有 → 高度怀疑自研引擎，钩子命中不了是「蹲错楼层」而非「钩子写漏」，
//          别再往 AVPlayer 上加钩子了，加多少都是零。
// 相比纯经验判断「抖音大概不用 AVPlayer」，这给了个可验证的事实。

static id dcl_initWithItem(id self, SEL _cmd, AVPlayerItem *item) {
    DCLPlayerBinding *b = dcl_binding_for_object(self);
    char tbuf[128];
    snprintf(tbuf, sizeof(tbuf), "%s 由 initWithPlayerItem: 创建", b ? b->clsName : "(未绑定)");
    DCLTimelineRecordC(DCLTlKindAVPlayerSeen, 1, tbuf);
    if (b && b->orig_initWithItem) return ((DCLInitImp)b->orig_initWithItem)(self, _cmd, item);
    return nil;
}

static id dcl_initWithURL(id self, SEL _cmd, NSURL *url) {
    DCLPlayerBinding *b = dcl_binding_for_object(self);
    char tbuf[128];
    snprintf(tbuf, sizeof(tbuf), "%s 由 initWithURL: 创建", b ? b->clsName : "(未绑定)");
    DCLTimelineRecordC(DCLTlKindAVPlayerSeen, 2, tbuf);
    if (b && b->orig_initWithURL) return ((DCLInitImp)b->orig_initWithURL)(self, _cmd, url);
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

/// 给单个类挂载。只对它「自己实现」了的方法动手（护栏在 DCLReplaceInstanceMethod 内）。
static void dcl_hook_class(Class cls);

/// 尝试给 AVPlayer 基类 + 所有已知子类挂钩子。
/// 返回 NO 表示 AVFoundation 还没加载（连 AVPlayer 类都查不到）—— 交给延迟补挂。
static BOOL dcl_hook_all_classes(void) {
    Class base = NSClassFromString(@"AVPlayer");
    if (!base) return NO;

    dcl_hook_class(base);

    // 抖音大概率基于 AVPlayer 做过扩展（真机已枚举到 HTSMediaMixPlayer / ISAVPlayer 等）。
    // 逐个挂载：它们各自持有自己的原始实现，互不覆盖。
    for (NSString *name in [DCLSystemSignal avPlayerSubclasses]) {
        Class c = NSClassFromString(name);
        if (c && c != base) dcl_hook_class(c);
    }
    return YES;
}

static void dcl_hook_class(Class cls) {
    if (!cls || dcl_binding_for_class(cls)) return;   // 已挂过：再替换一次会形成自环

    int32_t slot = g_binding_count;
    if (slot >= DCL_MAX_PLAYER_CLASS) return;
    DCLPlayerBinding *b = &g_bindings[slot];
    memset(b, 0, sizeof(*b));
    b->cls = cls;
    const char *cn = class_getName(cls);
    if (cn) strncpy(b->clsName, cn, sizeof(b->clsName) - 1);
    else    strcpy(b->clsName, "(无名)");

    NSUInteger before = g_hook_count;
    // typeEncoding 一律传 NULL：沿用宿主真实编码（"v16@0:8" 这类带偏移的写法），
    // 手写 "v@:" 会把 runtime 里的方法签名改掉，是没必要又难以察觉的风险。
    //
    // 关键护栏：DCLReplaceInstanceMethod 只在该类「自己实现」了方法时才动手。
    //   子类没重写 pause → 消息本来就去父类实现（也就是我们挂在父类上的钩子），
    //   这里会返回 NO —— 既不重复计数，也不会把继承链插出个自环来。
    if (DCLReplaceInstanceMethod(cls, @selector(pause), NULL,
                                 (void *)dcl_pause, &b->orig_pause)) g_hook_count++;
    if (DCLReplaceInstanceMethod(cls, @selector(play), NULL,
                                 (void *)dcl_play, &b->orig_play)) g_hook_count++;
    if (DCLReplaceInstanceMethod(cls, @selector(setRate:), NULL,
                                 (void *)dcl_setRate, &b->orig_setRate)) g_hook_count++;
    if (DCLReplaceInstanceMethod(cls, @selector(replaceCurrentItemWithPlayerItem:), NULL,
                                 (void *)dcl_replaceItem, &b->orig_replaceItem)) g_hook_count++;
    if (DCLReplaceInstanceMethod(cls, @selector(initWithPlayerItem:), NULL,
                                 (void *)dcl_initWithItem, &b->orig_initWithItem)) g_hook_count++;
    if (DCLReplaceInstanceMethod(cls, @selector(initWithURL:), NULL,
                                 (void *)dcl_initWithURL, &b->orig_initWithURL)) g_hook_count++;

    NSUInteger got = g_hook_count - before;
    if (got == 0) {
        // 一个都没挂上（该类既不实现这些方法也无自有 init）—— 不占槽位，但要留痕
        if (g_events_lock) {
            @synchronized (g_events_lock) {
                [g_skipped addObject:[NSString stringWithUTF8String:b->clsName]];
            }
        }
        b->cls = NULL;
        return;
    }

    // 内容先写完，再推进计数 —— 读者看到计数就一定能读到完整内容。
    __sync_fetch_and_add(&g_binding_count, 1);

    char tbuf[128];
    snprintf(tbuf, sizeof(tbuf), "%s 挂上 %lu 个方法", b->clsName, (unsigned long)got);
    DCLTimelineRecordC(DCLTlKindHookInstalled, (int32_t)got, tbuf);
}

// —— 延迟补挂 ——
// dyld 构造期（本 dylib 的 constructor）AVFoundation 往往还没被加载，
// NSClassFromString(@"AVPlayer") 会返回 Nil —— 那一刻一个钩子都挂不上，
// 表现出来的症状正是「视频明明停了，探针却一条都没抓到」。
// 有限次重试：既要把迟到的类补上，也不能无限轮询拖着进程不放。
static const int kRetryDelays[] = {1, 2, 5, 10, 20};   // 秒

static void dcl_schedule_retry(int attempt) {
    int n = (int)(sizeof(kRetryDelays) / sizeof(kRetryDelays[0]));
    if (attempt >= n) {
        if (NSClassFromString(@"AVPlayer") == Nil) {
            DCLTimelineRecordC(DCLTlKindHookInstalled, -1,
                               "AVPlayer 类始终未加载，播放钩子放弃挂载");
        }
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kRetryDelays[attempt] * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try { (void)dcl_hook_all_classes(); } @catch (id e) { (void)e; }
        dcl_schedule_retry(attempt + 1);
    });
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
        g_skipped = [NSMutableArray array];
        g_symbolQueue = dispatch_queue_create("com.dcl.symbolicate", DISPATCH_QUEUE_SERIAL);

        // 播放钩子：AVPlayer 基类 + 所有子类各挂一份，各自持有原始实现。
        // 首次尝试 + 若干次延迟补挂（应对 AVFoundation 迟加载）。
        if (!dcl_hook_all_classes()) {
            DCLTimelineRecordC(DCLTlKindHookInstalled, 0,
                               "首次挂载时 AVPlayer 尚未加载，转入延迟补挂");
        }
        dcl_schedule_retry(0);

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

+ (NSArray<NSString *> *)hookedPlayerClasses {
    NSMutableArray *a = [NSMutableArray array];
    int32_t n = g_binding_count;
    for (int32_t i = 0; i < n; i++) {
        if (!g_bindings[i].cls) continue;
        [a addObject:[NSString stringWithUTF8String:g_bindings[i].clsName]];
    }
    return a;
}

+ (NSArray<NSString *> *)skippedPlayerClasses {
    if (!g_events_lock) return @[];
    @synchronized (g_events_lock) {
        return [g_skipped copy] ?: @[];
    }
}

@end
