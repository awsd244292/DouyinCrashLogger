//
//  DCLConfig.h
//  DouyinCrashLogger
//
//  两套采集方案（Capture Profile）的开关与能力矩阵。
//
//  为什么要分成两套：
//    要回答「视频为什么停」，必须拿到「谁调用了 pause」的调用栈 —— 那就得对
//    AVPlayer / UIApplication 做运行时方法交换。即便实现上做到纯旁路透传、
//    零吞事件、钩子体只打点，只要换了方法实现，就存在与抖音自身或其他注入插件
//    冲突的理论风险。而多数时候，用户只需要证明「有没有崩、上次是怎么退的」。
//
//    所以能力被切成两档，默认走最保守那一档，需要深挖时再手动开全：
//
//    A 方案 safe（默认 · 零 hook · 一行方法都不换）
//      · 崩溃信号 / OC 未捕获异常捕获      —— 无需 hook
//      · 上次退出性质判定                   —— 无需 hook
//      · 主线程卡死「时长」检测             —— CFRunLoopObserver 公开 API，非 hook
//      · 插件健康自检                       —— 无需 hook
//      · 不做：播放暂停归因、触摸时间线、卡死调用栈、全线程快照
//
//    B 方案 full（hook 全开 · 抓得更全）
//      在 A 的全部能力之上，额外开启：
//      · AVPlayer pause/play/setRate:/replaceCurrentItem 旁路钩子 → 暂停发起者调用栈
//      · UIApplication sendEvent: 旁路钩子 → 触摸时间线（暂停是否紧随触摸发生）
//      · 卡死时 suspend 主线程采样 + 归因 → 卡在什么调用上
//      · 卡死 / 截图时抓取全线程冻结快照 → 死锁、锁等待取证（仿 PerfDebugPlugin）
//      所有钩子依旧严格「原样透传、零吞事件、钩子体只打点、重活丢后台队列」。
//
//  切换方式（三选一，等效）：
//   1) 编辑沙盒内 Documents/DouyinCrashLogs/capture_mode.txt，
//      内容写 full 或 safe（# 开头的注释行与空行会被忽略），完全退出并重启抖音生效。
//   2) App 内摇一摇：直接翻转档位，顶部轻提示 + 三连触感，免文件（详见 DCLHotSwitch）。
//   3) App 内设置页（DYStorage 入口）的 Hook 开关：直接翻转 safe/full，与摇一摇等效。
//  文件不存在时按 safe 运行，并在首次运行时自动生成一份带说明的默认文件，方便直接改。
//
//  设计铁律：无论哪一档，捕获链路（信号 / 异常处理器）都始终安装 ——
//  崩溃取证是刚需，不随方案降级而关闭。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, DCLCaptureProfile) {
    DCLCaptureProfileSafe = 0,  ///< A 方案：零 hook，只抓崩溃 / 退出性质 / 卡死时长 / 自检
    DCLCaptureProfileFull = 1,  ///< B 方案：hook 全开，在 A 之上抓调用栈与全线程快照
    DCLCaptureProfileOff  = 2,  ///< 总开关关闭：插件拒绝一切活动（详见 isDisabled 的说明）
};

@interface DCLConfig : NSObject

/// 当前采集方案（默认 safe）。首次调用时读取开关文件并缓存，全程异常安全。
+ (DCLCaptureProfile)captureProfile;

/// 方案代号，写进日志：@"safe" / @"full"
+ (NSString *)profileName;

/// 方案中文名，写进日志：@"A 方案（safe，零 hook）" / @"B 方案（full，hook 全开）"
+ (NSString *)profileDisplayName;

/// 总开关是否被关掉（off 档）。
///
/// off 的语义是「拒绝此插件所有活动」：崩溃捕获 / 卡死看门狗 / 播放探针 /
/// 时间线落盘 / 资源采样 / stderr 接管 / 日志写入，一律不装或立即卸掉。
///
/// 唯一的两处例外（刻意保留，否则用户再也切不回来）：
///   1) 摇一摇检测 —— 它是唯一的自救通道，卸掉就只能靠沙盒文件改回来；
///   2) DYStorage / 设置页入口行 —— 同上，给一个能点回来的地方。
/// 这两处本身零采集、零写盘，不构成「活动」。
+ (BOOL)isDisabled;

/// 是否允许方法交换（hook）。仅 full 为 YES —— DCLMain 据此决定是否安装播放探针。
+ (BOOL)hooksEnabled;

/// 是否允许深度取证（suspend 主线程采样 / 全线程快照）。仅 full 为 YES。
+ (BOOL)deepEvidenceEnabled;

/// 开关文件绝对路径（Documents/DouyinCrashLogs/capture_mode.txt）
+ (NSString *)modeFilePath;

/// 当前方案已开启的能力清单（逐行写进日志，作为「这份日志覆盖到哪」的依据）
+ (NSArray<NSString *> *)enabledCapabilities;

/// 当前方案未覆盖、需切到另一档才能拿到的能力清单
+ (NSArray<NSString *> *)disabledCapabilities;

/// 切换方式说明（写进日志，避免用户忘了怎么改回来）
+ (NSString *)switchGuide;

/// 立即设定采集方案（绕过只读缓存，热切换用）。
/// 双写 NSUserDefaults 与 capture_mode.txt —— 即使完全退出重启抖音也保持生效。
+ (void)setProfile:(DCLCaptureProfile)profile;

/// 三态循环切换：safe → full → off → safe（摇一摇热切换入口）
+ (void)toggleProfile;

@end

NS_ASSUME_NONNULL_END
