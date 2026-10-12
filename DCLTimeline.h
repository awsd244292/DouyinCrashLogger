//
//  DCLTimeline.h
//  DouyinCrashLogger
//
//  统一时间线：所有探针共用同一条单调时钟 + 同一个环形缓冲。
//
//  为什么要单独抽这一层：
//    之前各探针各记各的 —— 播放探针记自己的 pause 时刻、看门狗记自己的卡顿时刻、
//    日志里再补一句 lifecycle。事后要回答「视频暂停的那一刻，主线程在干什么、
//    前后 200ms 有没有触摸或音频中断」，就得靠人肉拿 unix 时间戳去对表，
//    精度还对不齐。时间线的价值就在把因果对齐这件事从人脑搬到代码里。
//
//  三条设计底线：
//    1) 时钟统一：单调时钟用 mach_absolute_time（不受系统改时间 / 休眠跳变影响），
//       每条事件同时补一份 wallclock 毫秒，方便与人眼可读的时间对上。
//    2) 内存有界：定长环形缓冲（满 512 条覆盖最旧），绝不无界增长 ——
//       无界缓冲本身就是新的内存压力来源，等于用取证手段制造卡顿。
//    3) 写入极轻：钩子体内只做「填一个定长结构体 + 推进下标」，
//       不分配堆内存、不做 IO、不符号化。崩溃上下文里也能安全读。
//
//  为什么能拿来兜「自研播放器钩不到」这个死穴：
//    即便永远拿不到抖音内部的 pause 调用，只要把「暂停发生时刻 + 当时主线程
//    是否卡顿 + 有没有触摸 / 音频中断 / 前后台」打在同一条轴上，就能把结论
//    推到系统层：是用户点的、是系统打断的、还是画面被主线程冻住的。
//

#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 时间线事件类型。
/// 命名规则：谁产生的前缀 —— Hook(方法交换) / Sys(系统通知) / App(宿主生命周期)。
typedef NS_ENUM(uint32_t, DCLTimelineEventKind) {
    // —— 播放探针（full 档，方法交换产出）——
    DCLTlKindPauseHook        = 0,   ///< AVPlayer pause 钩子命中
    DCLTlKindPlayHook         = 1,   ///< AVPlayer play / setRate: 钩子命中
    DCLTlKindItemReplace      = 2,   ///< replaceCurrentItemWithPlayerItem: 换源
    DCLTlKindAVPlayerSeen     = 3,   ///< 本会话出现过 AVPlayer 实例（坐实是否走系统播放器）

    // —— 宿主外显（full 档，sendEvent 钩子产出）——
    DCLTlKindTouch            = 4,   ///< 触摸事件（可能是用户点了暂停键）

    // —— 主线程（safe 档就有，RunLoop 观察器产出）——
    DCLTlKindMainThreadStall  = 5,   ///< 主线程卡顿超过阈值

    // —— 系统层硬信号（safe 档就有，只注册通知、不做任何方法交换）——
    DCLTlKindAudioInterrupt   = 6,   ///< AVAudioSession 中断 began / ended
    DCLTlKindAudioRouteChange = 7,   ///< 音频路由变更（耳机拔插、蓝牙断开等）
    DCLTlKindEnterBackground  = 8,   ///< 进入后台
    DCLTlKindEnterForeground  = 9,   ///< 回到前台
    DCLTlKindResignActive     = 10,  ///< 即将失活（下拉通知栏、来电横幅等）
    DCLTlKindBecomeActive     = 11,  ///< 重新激活
    DCLTlKindLockScreen       = 12,  ///< 锁屏（保护数据即将不可用）
    DCLTlKindUnlockScreen     = 13,  ///< 解锁
    DCLTlKindMemoryWarning    = 14,  ///< 内存警告

    // —— 本模块自身事件 ——
    DCLTlKindCrash            = 15,  ///< 崩溃发生（信号 / OC 异常）
    DCLTlKindSnapshot         = 16,  ///< 生成 latest.log
    DCLTlKindHookInstalled    = 17,  ///< 播放器钩子挂载完成（含延迟补挂）
};

@interface DCLTimeline : NSObject

/// 记录一条事件（ObjC 入口，普通上下文用）。detail 过长会被截断，不会抛异常。
+ (void)recordKind:(DCLTimelineEventKind)kind
               aux:(int32_t)aux
            detail:(NSString *_Nullable)detail;

/// 累计写入的事件总数（含已被环形缓冲覆盖掉的）
+ (uint64_t)totalRecorded;

/// 当前缓冲内保留的事件条数
+ (NSUInteger)bufferedCount;

/// 导出全部事件的可读行（按时间正序）。
/// 每行格式：`<序号> +<相对毫秒> <HH:MM:SS.mmm> <类型名> aux=<数值> <说明>`
/// 相对毫秒以缓冲内第一条事件为基准 —— 这样「暂停前后 200ms 发生了什么」一眼可见。
+ (NSArray<NSString *> *)formattedLines;

/// 只导出最近 limit 条（latest.log 里控制篇幅用）
+ (NSArray<NSString *> *)formattedLinesLimit:(NSUInteger)limit;

/// 类型枚举 → 可读名（写日志、调试用）
+ (NSString *)kindName:(DCLTimelineEventKind)kind;

/// 本会话是否出现过 AVPlayer 实例。
/// 用途：跑完一轮刷视频看这一项 —— 若一次都没出现，就实锤主 feed 不走系统播放器，
///      挂在其上的 pause 钩子天然不会被调到（"蹲错人"而非"钩子漏了"）。
+ (BOOL)avPlayerSeen;

/// 出现次数（0 = 完全没走 AVPlayer 路径）
+ (NSUInteger)avPlayerSeenCount;

/// 最近一次指定类型事件距现在的毫秒数；从未发生返回 -1
+ (double)millisecondsSinceLastKind:(DCLTimelineEventKind)kind;

/// 以某条事件为锚点，回看它之前 windowMs 毫秒内发生的所有事件行。
/// 这是「暂停时刻上下文」的核心查询接口。
+ (NSArray<NSString *> *)contextLinesBefore:(DCLTimelineEventKind)anchor
                                  windowMs:(double)windowMs
                                     limit:(NSUInteger)limit;

@end

#pragma mark - C 快捷入口

/// 钩子体内专用：避免 ObjC 消息派发与对象分配，只填定长结构体。
/// 不保证线程内不重入，但本身是单行写入，崩溃上下文里调用也安全。
void DCLTimelineRecordC(DCLTimelineEventKind kind, int32_t aux, const char *_Nullable detail);

/// 当前单调时间（纳秒，进程内可比，已用 mach_timebase 换算过）
uint64_t DCLTimelineMonoNow(void);

NS_ASSUME_NONNULL_END
