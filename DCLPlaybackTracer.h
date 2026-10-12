//
//  DCLPlaybackTracer.h
//  DouyinCrashLogger
//
//  视频「为什么会停」的归因探针。
//
//  核心思路：不看现象（画面静了），看**谁调用了暂停**。
//    暂停一定有人发起 —— 用户点了、抖音自己的逻辑、某个注入插件、或者系统中断。
//    发起者必然出现在调用栈里，把栈符号化出来，答案就在那儿。
//
//  零干扰约束：
//    1) 钩子体（跑在抖音的调用线程上，可能是主线程）只做三件事：
//       记录时间戳、backtrace() 收集返回地址到定长数组、调用原始实现。
//       全部是纳秒~微秒级，不分配堆内存、不拿锁、不做 IO。
//    2) 符号化（dladdr）与归因属于重活，连同事件对象一起丢进后台串行队列，
//       绝不在抖音的调用线程上做。
//    3) 无论探针自身出任何异常，原始实现**照常被调用**（参数、返回值原样透传），
//       本模块绝不吞事件、绝不影响播放。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 暂停的归因来源
typedef NS_ENUM(NSUInteger, DCLPauseSource) {
    DCLPauseSourceUnknown         = 0,  ///< 无法归因
    DCLPauseSourceUserAction      = 1,  ///< 用户手势触发（点击/双击/长按/滑动）
    DCLPauseSourceHostAppLogic    = 2,  ///< 抖音自身业务逻辑（定时器/回调驱动）
    DCLPauseSourceBackgroundMove  = 3,  ///< 切后台 / 锁屏
    DCLPauseSourceAudioInterrupt  = 4,  ///< 音频会话中断 / 路由变更（来电、耳机拔插等）
    DCLPauseSourceBufferStall     = 5,  ///< 缓冲不足或播放失败导致的自动暂停
    DCLPauseSourceThirdPartyHook  = 6,  ///< 第三方注入模块发起
    DCLPauseSourceMainThreadStall = 7,  ///< 伴随主线程卡死 —— 画面是「被冻住」而非主动暂停
};

@interface DCLPauseEvent : NSObject
@property (nonatomic) NSTimeInterval unixTime;
@property (nonatomic, copy) NSString *action;        // pause / play / setRate: / replaceItem
/// 命中这次调用的**真实类名**（如 HTSMediaMixPlayer）。
/// 光知道「AVPlayer 被 pause」没用 —— 抖音若用重写过的子类，
/// 必须说清是哪一层发起的，归因才有指向性。
@property (nonatomic, copy) NSString *playerClass;
@property (nonatomic) float  rateBefore;
@property (nonatomic) float  rateAfter;
@property (nonatomic) BOOL   onMainThread;
@property (nonatomic) double msSinceLastTouch;       // 距最近触摸毫秒；<0 无触摸
@property (nonatomic) double msSinceLastStall;       // 距最近主线程卡顿毫秒；<0 无卡顿
@property (nonatomic) DCLPauseSource source;
@property (nonatomic, copy) NSString *suspectImage;  // 嫌疑模块名
@property (nonatomic, copy) NSArray<NSString *> *stack;
@property (nonatomic, copy) NSString *evidence;      // 判定依据（给人看的那句话）
@end

@interface DCLPlaybackTracer : NSObject

/// 安装探针。延迟执行（绝不在 constructor 阶段），且必须在主线程调用。
+ (void)install;

/// 本次会话观测到的暂停/恢复事件（按时间倒序）
+ (NSArray<DCLPauseEvent *> *)recentEvents;

/// 已成功挂载的探针方法数（健康自检用：>0 说明探针在工作）
+ (NSUInteger)hookedCount;

/// 实际挂上钩子的播放器类名（如 HTSMediaMixPlayer、AVPlayer）。
///
/// 这一项直接回答「钩子到底蹲在哪几层」：
///   只看到 AVPlayer          → 只覆盖基类，抖音若用重写 pause 的子类就蹲不到人
///   看到 AVPlayer + 若干子类 → 各层都蹲上了，漏抓才真能算到 probes 头上
/// 健康自检与 latest.log 都会输出它 —— 取证结论必须能被独立验证，不能靠猜。
+ (NSArray<NSString *> *)hookedPlayerClasses;

/// AVPlayer 子类里，钩子尝试过但没能挂上的类名（多为「子类未自己实现该方法」）。
/// 留个出口：万一抖音换了类名导致漏挂，日志里能直接看到，而不是沉默地少抓一条。
+ (NSArray<NSString *> *)skippedPlayerClasses;

@end

NS_ASSUME_NONNULL_END
