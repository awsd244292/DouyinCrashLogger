//
//  DCLConstants.h
//  DouyinCrashLogger
//
//  全局常量与配置
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 崩溃日志存放目录（相对 App 沙盒 Documents）
FOUNDATION_EXPORT NSString * const DCLCrashLogsRelativeDir;

/// 单设备上最多保留的崩溃日志条数（超出删除最旧）
FOUNDATION_EXPORT NSUInteger const DCLMaxRetainedLogs;

/// NSUserDefaults key：上次是否正常退出（YES=走正常终止流程）
FOUNDATION_EXPORT NSString * const DCLLastExitNormalKey;

/// NSUserDefaults key：上次正常退出的 unix 时间戳
FOUNDATION_EXPORT NSString * const DCLLastNormalExitTimeKey;

/// 运行时 stderr 重定向日志文件名（存放在崩溃日志目录下）
FOUNDATION_EXPORT NSString * const DCLRuntimeLogFileName;

NS_ASSUME_NONNULL_END
