//
//  DCLWatchdog.h
//  DouyinCrashLogger
//
//  主线程卡顿（界面冻死）的看门狗 + 取证。
//
//  设计铁律：常态零干扰。
//    - 主线程侧唯一的负担：一个 CFRunLoop 观察者写一个 volatile 时间戳（纳秒级）。
//      watchDog 线程从不主动唤醒主线程，只读取这个 volatile。
//    - 只有当「主线程醒着却长时间不推进」被确认后，才 suspend 主线程做一次 Mach 栈回溯。
//    - suspend 必定 resume（@try/@finally 保证），且每次卡顿最多采样有限次数。
//
//  为什么不直接用 performSelector 探活：那会向主线程投递事件、打断空闲，属于干扰。
//
//  为什么必须看 CFRunLoopActivity：
//    主线程正常空闲时会停在 mach_msg 休眠（kCFRunLoopBeforeWaiting 之后），
//    此时心跳同样不更新，但这是合法休眠 —— 必须与「醒着卡住」区分开，否则全是误报。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 主线程卡顿的可能成因
typedef NS_ENUM(NSUInteger, DCLStallCause) {
    DCLStallCauseUnknown          = 0,  ///< 无法归因
    DCLStallCauseTouchHandler     = 1,  ///< 卡顿紧随触摸发生 —— 触摸处理链里有阻塞
    DCLStallCauseThirdParty       = 2,  ///< 主线程栈里出现第三方注入库
    DCLStallCauseLockWait         = 3,  ///< 卡在互斥锁 / 信号量等待
    DCLStallCauseSystemIO         = 4,  ///< 卡在文件 IO / mmap 等系统调用
    DCLStallCauseMachWait         = 5,  ///< 卡在进程间 mach 消息等待
    DCLStallCauseLongCompute      = 6,  ///< 多次采样 PC 持续推进 —— 单纯的计算/渲染耗时
};

/// 一次主线程卡顿的取证记录
@interface DCLStallRecord : NSObject
@property (nonatomic) NSTimeInterval startedAtUnix;   ///< 卡顿起始时刻（unix 秒）
@property (nonatomic) double durationMs;              ///< 持续毫秒
@property (nonatomic) double msSinceLastTouch;        ///< 距最近一次触摸的毫秒；<0 表示无触摸
@property (nonatomic) DCLStallCause cause;            ///< 归因结论
@property (nonatomic, copy) NSString *suspectImage;   ///< 嫌疑镜像（第三方 dylib 名，无则空串）
@property (nonatomic, copy) NSArray<NSString *> *stack; ///< 主线程符号化调用栈
@property (nonatomic) BOOL pcStable;                  ///< 多次采样栈顶地址不变 = 死等；变化 = 慢调用
@property (nonatomic, copy) NSString *verdict;        ///< 一句话结论（写进日志）
@end

@interface DCLWatchdog : NSObject

/// 安装看门狗。必须在主线程调用一次（延迟执行，绝不在 constructor 里）。
+ (void)install;

/// 停止看门狗并卸载 RunLoop 观察者（总开关 off 时用）。
/// 后台线程靠 g_wd_stop 标志自然退出 —— 从外面 cancel 一个 NSThread 是不受支持的做法，
/// 让它自己看见「该收工了」再退出，才是稳的。
+ (void)uninstall;

/// 触摸记录（由 UIApplication sendEvent: 的旁路钩子更新）
+ (NSTimeInterval)lastTouchUnix;
+ (void)noteTouch;

/// App 退到后台时暂停判定（后台 RunLoop 停转属正常，不能误报）
+ (void)pauseForBackground;
+ (void)resumeFromForeground;

#pragma mark - 供健康检查与日志输出

+ (BOOL)isRunning;                                  ///< watchdog 线程是否还活着
+ (double)watchdogHeartbeatAgeSec;                  ///< watchdog 自身心跳滞留秒数（自证其活着）
+ (double)mainLoopHeartbeatAgeSec;                  ///< 主线程心跳滞留秒数
+ (NSUInteger)stallCount;
+ (NSArray<DCLStallRecord *> *)recentStalls;

/// 实测一次主线程响应延迟（毫秒）。必须从非主线程调用；主线程调用直接返回 0。
+ (double)measureMainThreadResponseMs;

#pragma mark - 全线程快照（融合 PerfDebugPlugin 抓取手段）

/// 抓取「全线程栈快照」：枚举进程内所有线程，对每个线程 suspend(自身/主线程只读) +
/// thread_get_state(ARM64) + 帧指针回溯 + dladdr 符号化，输出与 PerfDebugPlugin
/// 「冻屏全线程快照」同构的文本（线程 #N [名] / 帧号 地址 镜像+偏移 <符号>）。
/// 用途：主线程卡死时，单看主线程栈看不出死锁 —— 必须同时看其余线程卡在什么锁/IO 上。
/// 仅对「自身线程」与「主线程」做只读；对其余线程严格 suspend→读取→resume 对称，
/// 绝不长期持有任何线程的挂起态（@try/@finally 保证 resume）。
+ (NSString *)captureAllThreadsSnapshot;

/// 抓取全线程快照并缓存到 lastAllThreadsSnapshot（卡死 / 后台取证用）。
/// 必须与 captureAllThreadsSnapshot 一起在头文件声明 —— 它在本文件内被调用的位置
/// 早于实现，缺声明会直接编译失败。
+ (void)captureAndStoreAllThreadsSnapshot;

/// 最近一次卡死时自动抓取并缓存的全线程快照（卡死取证用）。无则返回 nil。
+ (nullable NSString *)lastAllThreadsSnapshot;

@end

NS_ASSUME_NONNULL_END
