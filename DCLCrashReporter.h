//
//  DCLCrashReporter.h
//  DouyinCrashLogger
//
//  崩溃捕获核心：信号(SIGABRT/SIGSEGV/SIGBUS/SIGTRAP/SIGILL/SIGFPE/SIGPIPE) +
//  NSUncaughtException 捕获，将崩溃写入抖音沙盒 Documents/DouyinCrashLogs/。
//
//  设计要点：
//  - 信号处理路径使用 async-signal-safe 的 POSIX 调用（open/write/fsync/close），
//    不调用任何 Objective-C / malloc / C++ 构造，避免重入导致二次崩溃。
//  - OC 异常路径无信号重入风险，可直接使用 Foundation 写出可读性更高的报告。
//  - 递归保护：同一进程内若再次进入处理，直接退出，避免死循环。
//  - 设备/系统/App 版本等元信息在「非崩溃上下文」预收集并存为 C 缓冲区，
//    信号处理路径只做 write，绝不调用 Foundation。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 上一次退出的性质。
///
/// 重要背景（Apple《App Programming Guide for iOS》- App Termination）：
///   「用户通过多任务界面发起的终止，与终止一个挂起 App 的效果相同：
///     进程被杀死，且不会向 App 发送任何通知。」
/// 也就是说 UIApplicationWillTerminateNotification 在现代 iOS 上几乎收不到，
/// 单看「有没有走 WillTerminate」无法区分「用户主动划掉」和「真崩溃」，必须引入
/// 「退出时 App 是否处于后台」+「上次运行期间是否产出过崩溃文件」两个维度。
typedef NS_ENUM(NSInteger, DCLPreviousExitKind) {
    DCLPreviousExitKindFirstLaunch       = 0,  ///< 首次运行，无历史记录
    DCLPreviousExitKindNormal            = 1,  ///< 走完了完整的终止流程
    DCLPreviousExitKindBackgroundKilled  = 2,  ///< 后台期间被终止且无崩溃记录 —— 用户清后台 / 系统回收，非故障
    DCLPreviousExitKindBackgroundCrashed = 3,  ///< 后台期间崩溃（有崩溃文件佐证）
    DCLPreviousExitKindForegroundCrashed = 4,  ///< 前台崩溃（有崩溃文件佐证）
    DCLPreviousExitKindSuspicious        = 5   ///< 前台异常终止且无崩溃记录 —— 这才是真正值得怀疑的闪退
};

@interface DCLCrashReporter : NSObject

/// 安装崩溃捕获（信号处理 + OC 异常处理器）。应在 +load / constructor 中尽早调用。
+ (void)install;

/// 总开关 off 时的「彻底归零」：卸掉本模块装的一切东西，
/// 让进程回到「这个插件从未注入过」的状态（就崩溃捕获而言）。
///
/// 逐项还原，缺一项就等于假卸载：
///   1. 停止自愈巡检定时器 —— 这是最容易漏的一项。它每 15s 夺回一次处理器，
///      不先停掉的话，刚还原的处理器会在十几秒后又被我们悄悄抢回来，
///      用户看到的是「关了但好像没关」；
///   2. 逐个还原 g_old_sa[] 里保存的旧 sigaction；
///   3. 还原 OC 未捕获异常处理器为接管前那个；
///   4. 移除通知观察者（截图 / 进后台 / 回前台三个快照触发）；
///   5. 交还 stderr / stdout 原本的输出通道。
///
/// 还原一律遵守「只还原自己的」：动手前先比对当前处理器是否仍是我们装的那个。
/// 若期间被别的模块顶替过，就原样留着 —— 否则我们这一脚会把宿主的监控链路踩断。
/// 重复调用安全；卸载后仍可再次 install。
+ (void)uninstall;

/// 启动期清理：保留最近 DCLMaxRetainedLogs 条，删除其余最旧的。非崩溃安全，仅启动时调用。
+ (void)cleanupOldLogs;

/// 崩溃日志目录（App 沙盒内，绝对路径）。
+ (NSString *)crashLogsDirectory;

/// 启动期调用：读取「上次是否正常退出」标记，并注册 WillTerminate 观察者写回正常标记。
///
/// 【为什么不能只用 WillTerminate 判定】依据 Apple 官方文档：
///   - 挂起（suspended）App 被终止时收不到任何通知，系统直接杀进程回收内存；
///   - 用户从多任务界面上滑杀 App，效果同上，同样不发送任何通知；
///   - 现代 iOS 上 App 退回后台后通常在数秒内转入挂起态。
/// 因此本方法改为同时记录「App 当前是否停留在后台」与「上一轮启动时间」，
/// 在下一轮启动时综合判定真实退出性质（见 DCLPreviousExitKind）。
+ (void)recordExitMarkAndRegisterTerminateObserver;

/// 把上次退出性质的结论（英文）写入 plugin_runtime.log。
/// 必须在 App 沙盒就绪、runloop 启动后调用（2s 延迟主线程块），绝不在 dyld
/// constructor 阶段调用——那时 NSHomeDirectory 未必指向正确沙盒且 GCD 异步块
/// 可能尚未被调度，写入会落空。详见 DCLMain.m 的时序注释。
+ (void)appendLaunchVerdictToRuntimeLog;

/// 延迟块中调用：把 stderr 重定向到沙盒 runtime 日志（plugin_runtime.log），
/// 即使随后被 SIGKILL，被杀前已落盘的 stderr 也可作为排查线索（末尾可能丢失）。
+ (void)redirectStderrToRuntimeLog;

/// 崩溃捕获链路自检（健康自检用）：返回本模块信号处理器 / 未捕获异常处理器的函数地址，
/// 与系统当前实际注册的做比对，即可判断是否被其他模块接管。
+ (void *)currentSignalHandlerPointer;
+ (void *)currentUncaughtExceptionHandlerPointer;

/// 本模块实际接管的信号清单（不含 SIGPIPE —— 接管它会把宿主原本忽略的
/// socket 写失败升级成进程终止，等于凭空制造崩溃）。健康自检只核对这些。
+ (NSArray<NSNumber *> *)monitoredSignals;

/// 自愈：若 OC 未捕获异常处理器已被其他共存模块（如 libMetalMetricsInterpose.dylib）
/// 顶替，夺回处理器并把被顶替者保留为链式转发的上游。返回是否发生了夺回。
///
/// 设计背景：本插件的 install 只在 dyld constructor 阶段装一次。若某共存模块随后
/// 调用 NSSetUncaughtExceptionHandler 覆盖我们，OC 异常捕获链路会静默失效——
/// 本会话的 NSException 崩溃将完全没有记录，且健康自检会把它误报成「插件坏了」。
+ (BOOL)healUncaughtExceptionHandlerIfNeeded;

/// 自愈：若某个致命信号处理器被其他模块顶替，夺回并保留链式转发。
/// 返回是否发生了任何夺回。与上面的 OC 异常自愈是同一类修复，对称实现。
+ (BOOL)healSignalHandlersIfNeeded;

/// 启动低频率（默认 15s）的周期性自愈计时器，自动夺回被顶替的捕获处理器。
/// 必须在 install 之后调用（建议放在 DCLMain 的延迟主线程块里）；重复调用安全。
/// 卸载后（总开关 off）再调用可重新启动，故这里刻意不用 dispatch_once。
+ (void)startHandlerSelfHealing;

/// 停止自愈巡检。由 uninstall 调用，一般不必单独调。
+ (void)stopHandlerSelfHealing;

/// 自上次启动以来，OC 异常处理器被夺回的次数（健康自检展示用）。
+ (NSInteger)uncaughtExceptionHealCount;

/// 自上次启动以来，信号处理器被夺回的次数（健康自检展示用）。
+ (NSInteger)signalHealCount;

/// 自建线程调用：为该线程安装备用信号栈（sigaltstack 是 per-thread 的），
/// 使栈溢出类崩溃也能留下日志。
+ (void)installSignalStackOnCurrentThread;

/// 上次退出是否异常（YES = 疑似 SIGKILL/Jetsam 闪退，无 ips）
/// 保留给向后兼容，语义等同 previousExitKind == Suspicious || ForegroundCrashed
+ (BOOL)lastExitWasAbnormal;

/// 上次退出的完整分类（推荐用它替代 lastExitWasAbnormal）
+ (DCLPreviousExitKind)previousExitKind;

/// 上次退出性质的中文说明（可直接写进日志）
+ (NSString *)previousExitDescription;

/// 上一句的同义英文版，专供 plugin_runtime.log —— 那份文件会被各种查看工具打开，
/// 编码不可控，写中文出来就是一屏乱码。
+ (NSString *)previousExitDescriptionASCIILine;

/// 是否首次运行（无历史退出标记）
+ (BOOL)firstLaunchEver;

/// 上次正常退出的时间（无记录返回 nil）
+ (nullable NSDate *)lastNormalExitDate;

/// 运行时 stderr 日志的完整路径
+ (NSString *)runtimeLogPath;

/// 最新状态快照日志（latest.log）的完整路径
+ (NSString *)latestLogPath;

/// 注册「生成最新日志」的触发器（全部走系统公开通知，不 hook 任何方法）：
///   - 用户截图        UIApplicationUserDidTakeScreenshotNotification
///   - App 进入后台    UIApplicationDidEnterBackgroundNotification
+ (void)registerSnapshotTriggers;

/// 立即生成/覆盖一份最新状态快照日志（latest.log）
+ (void)writeLatestLogWithReason:(NSString *)reason;

@end

NS_ASSUME_NONNULL_END
