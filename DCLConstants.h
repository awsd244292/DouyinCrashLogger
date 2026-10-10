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

/// 摇一摇触发查看面板的去抖间隔（秒）
FOUNDATION_EXPORT NSTimeInterval const DCLShakeDebounceInterval;

NS_ASSUME_NONNULL_END
