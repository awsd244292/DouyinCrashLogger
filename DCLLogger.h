//
//  DCLLogger.h
//  DouyinCrashLogger
//
//  日志管家：只负责「文件怎么长大、什么时候该扔、写进去的东西干不干净」。
//
//  背景（真机反馈里三条抱怨，两条都归它管）：
//    · 日志永远不清 → 现在按会话轮转 + 单会话大小闸门 + 崩溃日志保留份数；
//    · 文件又大又乱 → stderr 不再 freopen 直写，改走「管道 + 后台泵」，
//      历经三个阶段把体积压下来：过滤已知刷屏 → 折叠连续重复 → 形态级抽样限流。
//
//  降频的红线（不可越过）：
//    形态级抽样只对「同一种话的第 4 次及以后」下手，且满足任一条件即无条件放行 ——
//      1) 本插件自己写的行（[DCL] 前缀）；
//      2) 疑似崩溃取证相关（EXC_ / SIGx / NSException / assert / fatal / ERROR: ...）。
//    另外每个窗口结束会补一行「本轮抽样压掉了多少行」的摘要：
//    被压掉这件事本身必须可查，绝不做悄悄就扔的事。
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

/// 总开关 off：把 stderr / stdout 还给宿主，并让日志泵线程收工。
///
/// 「归还通道」这一步没有替代品 —— 丢了宿主的 stderr 是永久致盲，不可逆。
/// 停掉之后再调用 installStderrCapture 可以重新接管（故这里刻意不用 dispatch_once）。
+ (void)stopStderrCapture;

/// 是否还在往 runtime 日志里写字。off 时置 NO：此后所有 append（含日志泵收尾时
/// 补写的半行残留）一律丢弃，真正做到「一个字节都不再写」。
/// 调用方可在置 NO 之前先 append 一行说明，那一行仍会落盘。
+ (void)setLoggingEnabled:(BOOL)enabled;

/// 单会话日志大小上限（健康自检拿它做判据，避免各处再抄一遍魔数）
+ (NSUInteger)runtimeLogMaxBytes;

#pragma mark - 写入

/// 追加一行到当前会话日志。异步返回，永不阻塞调用方。
/// 内部依次做：ASCII 净化 → 噪音过滤 → 形态限流 → 连续重复行折叠 → 大小闸门。
/// 非 ASCII 全会被转义，故本方法不接受也不产出中文（如需人读的中文报告，写 latest.log）。
+ (void)appendRuntimeLine:(NSString *)line;

/// 批量版：多行走一次入队。管道的泵线程用它投递一次 read 切出来的全部行。
/// 语义与 appendRuntimeLine: 完全一致，只是便宜得多（省掉每行一次队列入队）。
+ (void)appendRuntimeLines:(NSArray<NSString *> *)lines;

#pragma mark - 降频统计

/// 本会话已真正落盘的行数（健康自检展示，允许取到略旧的值）
+ (NSUInteger)writtenLineCount;

/// 被「形态级抽样」压掉的行数 —— 这些是同一种话第 4 次以后的重复，不是随机丢日志
+ (NSUInteger)throttledLineCount;

/// 被判为系统刷屏而剔除的行数（如 objc runtime 对宿主 category 属性的抱怨）
+ (NSUInteger)noiseDroppedCount;

#pragma mark - 清理

/// 清理磁盘占用：崩溃日志保留最近 N 份 + 超龄（默认 7 天）删除 + 目录总量闸门。
/// 只动本插件自己产出的文件，不碰 App 任何其他数据。
+ (void)cleanupLogs;

@end

NS_ASSUME_NONNULL_END
