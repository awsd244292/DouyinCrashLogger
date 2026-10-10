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

@interface DCLCrashReporter : NSObject

/// 安装崩溃捕获（信号处理 + OC 异常处理器）。应在 +load / constructor 中尽早调用。
+ (void)install;

/// 启动期清理：保留最近 DCLMaxRetainedLogs 条，删除其余最旧的。非崩溃安全，仅启动时调用。
+ (void)cleanupOldLogs;

/// 崩溃日志目录（App 沙盒内，绝对路径）。
+ (NSString *)crashLogsDirectory;

@end

NS_ASSUME_NONNULL_END
