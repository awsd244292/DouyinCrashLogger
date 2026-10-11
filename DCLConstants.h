//
//  DCLConstants.h
//  DouyinCrashLogger
//
//  全局常量与配置
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 插件版本号。必须与 control 里的 Version 字段保持一致 ——
/// 每份崩溃报告的 "Reporter:" 一行都会带上它，真机排查时靠它确认
/// 日志是哪个包产出的（崩溃路径改过之后尤其重要）。
/// 升版时两处一起改：control 的 Version + 这里的字符串。
FOUNDATION_EXPORT NSString * const DCLPluginVersion;

/// 崩溃日志存放目录（相对 App 沙盒 Documents）
FOUNDATION_EXPORT NSString * const DCLCrashLogsRelativeDir;

/// 单设备上最多保留的崩溃日志条数（超出删除最旧）
FOUNDATION_EXPORT NSUInteger const DCLMaxRetainedLogs;

/// NSUserDefaults key：上次是否正常退出（YES=走正常终止流程）
FOUNDATION_EXPORT NSString * const DCLLastExitNormalKey;

/// NSUserDefaults key：上次正常退出的 unix 时间戳
FOUNDATION_EXPORT NSString * const DCLLastNormalExitTimeKey;

/// NSUserDefaults key：上一轮的启动 unix 时间戳（用于圈定「上次运行期间」是否产出过崩溃文件）
FOUNDATION_EXPORT NSString * const DCLLastLaunchTimeKey;

/// NSUserDefaults key：上次 App 是否停留在后台时被终止。
/// 依据 Apple《App Programming Guide for iOS》：用户从多任务界面上滑杀 App，
/// 与挂起态 App 被回收完全等价 —— 进程直接 SIGKILL，不发送任何通知。
FOUNDATION_EXPORT NSString * const DCLLastExitWasBackgroundedKey;

/// NSUserDefaults key：上次进入后台的 unix 时间戳（用于计算后台停留时长）
FOUNDATION_EXPORT NSString * const DCLLastEnterBackgroundTimeKey;

/// 运行时 stderr 重定向日志文件名（存放在崩溃日志目录下）
FOUNDATION_EXPORT NSString * const DCLRuntimeLogFileName;

/// 最新状态快照日志文件名（每次触发即覆盖，永远是最新的那份）
FOUNDATION_EXPORT NSString * const DCLSnapshotLogFileName;

/// 采集方案开关文件名（存放在崩溃日志目录下，内容写 full 或 safe）
FOUNDATION_EXPORT NSString * const DCLCaptureModeFileName;

/// NSUserDefaults key：采集方案（开关文件不存在时的备选取值）
FOUNDATION_EXPORT NSString * const DCLCaptureModeDefaultsKey;

NS_ASSUME_NONNULL_END
