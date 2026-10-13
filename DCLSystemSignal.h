//
//  DCLSystemSignal.h
//  DouyinCrashLogger
//
//  系统层「硬确证」暂停信号探针。
//
//  为什么必须有这一层：
//    如果抖音主 feed 用的是自研播放引擎（不走 AVPlayer 公开路径），那么挂在
//    AVPlayer 上的 pause / setRate: 钩子**根本不会被调到** —— 视频确实停了，
//    但探针一条都记不到。这不是钩子写漏了，是蹲错了楼层。
//
//    系统层信号的好处是它在播放器之上：不管抖音内部用什么引擎，播放一旦被
//    系统打断（来电、耳机拔插、切后台、锁屏），这些通知一定会到。它们能给出
//    一个不依赖任何私有实现的、可确证的「暂停硬信号」。
//
//  零 hook 承诺：
//    本模块**只注册系统通知 + 只读 runtime 查询，不做任何方法交换**。
//    因此在 A 方案（safe）下也照常安装 —— 拿不到调用栈，但拿得到因果事实。
//
//  能确证的与不能确证的（诚实边界）：
//    能：系统打断 / 前后台 / 锁屏 / 内存压力导致的暂停 —— 有明确时间戳。
//    不能：抖音「自己主动」暂停（内部状态机、缓冲策略）在系统层不留痕迹，
//          这一类只能靠 AVPlayer 钩子（若走系统播放器）或时间线旁证推断。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCLSystemSignal : NSObject

/// 安装系统层信号探针。必须在主线程调用（延迟到启动后，不在 constructor 阶段）。
/// 两档方案都调用 —— 本模块零 hook，没有理由在 safe 档下放弃这部分证据。
+ (void)install;

/// 摘掉全部系统信号观察者（总开关 off 时用）。
/// 这些观察者是 addObserverForName:...usingBlock: 装的，必须靠返回的 token 才能精确移除 ——
/// install 时逐个存下来，就是为了此刻能一个个 removeObserver: 回去。
+ (void)uninstall;

/// 已成功注册的信号源数量（健康自检用：>0 说明在系统层有观测点）
+ (NSUInteger)registeredCount;

/// 运行时枚举到的 AVPlayer 子类名（含抖音可能的自研播放器）。
/// 这是「不靠猜」回答「抖音到底走不走系统播放器」的关键线索：
///   · 拿到子类  → 主播放基于 AVPlayer 扩展，AVPlayer 钩子理论上能覆盖到
///   · 一个都没有 → 高度怀疑自研引擎，钩子命中不了属预期，别再怪探针漏了
/// 只读 objc_getClassList，不修改任何类，safe 档同样执行。
+ (NSArray<NSString *> *)avPlayerSubclasses;

/// 一句话结论：本会话在系统层观测到的暂停相关信号摘要（写进 latest.log）
+ (NSString *)signalSummary;

@end

NS_ASSUME_NONNULL_END
