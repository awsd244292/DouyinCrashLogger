//
//  DCLLogger.h
//  DouyinCrashLogger
//
//  日志管家：只负责「文件怎么长大、什么时候该扔、写进去的东西干不干净」。
//
//  背景（真机反馈里三条抱怨，两条都归它管）：
//    · 日志永远不清 → 现在按会话轮转 + 单会话大小闸门 + 崩溃日志保留份数；
//    · 文件又大又乱 → stderr 不再 freopen 直写，改走「管道 + 后台泵」，
//      坐享过滤噪音、折叠重复行的机会，从这里把体积压下来。
//
//  三条硬约束（对宿主负责）：
//    1) 管道写端必须 O_NONBLOCK —— 万一泵线程出岔子，宿主的 fprintf 拿 EAGAIN 直接失败，
//       绝不允许「写日志把抖音卡住」这种反向事故。
//    2) 泵线程意外退出时要把原 stderr / stdout dup 回去 —— 恢复不了，
//       宿主就永久丢了一条输出通道，这是不可逆的破坏。
//    3) 所有写盘都在一条串行队列里，且只做有界内存的截断操作（见 DCLLogger.m）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCLLogger : NSObject

#pragma mark - 路径

/// 日志根目录（Documents/DouyinCrashLogs）
+ (NSString *)logsDirectory;

/// 当前会话的运行时日志。每次冷启动会被轮转成 _prev，故它永远只装着这一轮的内容。
+ (NSString *)runtimeLogPath;

/// 上一会话的运行时日志（只留一份，再老的不再追溯）
+ (NSString *)previousRuntimeLogPath;

#pragma mark - 生命周期

/// 冷启动轮转：把上一轮的 plugin_runtime.log 挪成 _prev，并给本轮开一份新的。
/// 必须在任何 append 之前调用（放 constructor 里），否则第一轮内容会被后面的挤掉。
+ (void)rotateRuntimeLogAtLaunch;

/// 接管 stderr / stdout：替代旧的 freopen 直写。
/// 只能在延迟到主 runloop 稳定之后调用，不得放进 constructor / +load。
+ (void)installStderrCapture;

/// 接管是否成功（供健康自检展示，避免「看着没输出」时无从判断）
+ (BOOL)stderrCaptureInstalled;

/// 单会话日志大小上限（健康自检拿它做判据，避免各处再抄一遍魔数）
+ (NSUInteger)runtimeLogMaxBytes;

#pragma mark - 写入

/// 追加一行到当前会话日志。异步返回，永不阻塞调用方。
/// 内部依次做：ASCII 净化 → 噪音过滤 → 连续重复行折叠 → 大小闸门。
/// 非 ASCII 全会被转义，故本方法不接受也不产出中文（如需人读的中文报告，写 latest.log）。
+ (void)appendRuntimeLine:(NSString *)line;

#pragma mark - 清理

/// 清理磁盘占用：崩溃日志保留最近 N 份 + 超龄（默认 7 天）删除 + 目录总量闸门。
/// 只动本插件自己产出的文件，不碰 App 任何其他数据。
+ (void)cleanupLogs;

@end

NS_ASSUME_NONNULL_END
