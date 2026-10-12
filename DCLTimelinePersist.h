//
//  DCLTimelinePersist.h
//  DouyinCrashLogger
//
//  时间线持久化：把「崩溃前最后几秒发生了什么」从内存搬到磁盘。
//
//  为什么非做不可：
//    时间线原本只在内存环形缓冲里。进程一旦被杀 —— OOM、watchdog、用户上滑、
//    来电后被系统回收 —— 内存里那 512 条连同「最后几秒」一起蒸发。
//    而取证最值钱的东西恰恰就是最后几秒：
//      「崩溃那一刻，是刚点了暂停，还是刚切后台，还是主线程已经冻了 1.2 秒？」
//    没有落盘，这类问题的答案永远是一片空白。Crashlytics 的 breadcrumbs、
//    KSCrash 的文件日志都是落盘的，这不是可选项。
//
//  两条路径，各自的约束完全不同：
//    ① 常规落盘（本模块的 start / flushNow）
//       跑在后台串行队列上，每 5 秒把新增条目追加写 timeline.log。
//       这里可以用 Foundation，但依旧保持增量写：只写没写过的条目。
//    ② 崩溃紧急落盘（DCLTimelineEmergencyDump）
//       跑在信号处理器里。**只允许 open / write / close 三个系统调用**，
//       不碰 malloc、不碰 ObjC、不用 snprintf —— 那几位都不在 POSIX
//       async-signal-safe 白名单里，一次违规就可能把原本能救回来的证据
//       连同进程最后的体面一起弄丢。数字全部自己转成十进制字符串。
//
//  文件布局（均在 Documents/DouyinCrashLogs/）：
//    timeline.log         常规追加記錄（超过 256KB 轮转为 timeline_prev.log）
//    timeline_prev.log    上一轮轮转备份
//    timeline.crash       崩溃瞬间抢救出来的最后 64 条（下次启动被读入后归档）
//

#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCLTimelinePersist : NSObject

/// 启动周期落盘。传进来的目录决定了三个文件落在哪。
/// 周期 5 秒是刻意的取舍：更密并不能多救回多少（崩溃另有紧急路径兜底），
/// 反而把 IO 次数和耗电都堆上去了 —— 探针自己不该成为负担。
+ (void)startWithDirectory:(NSString *)directory;

/// 立即把尚未落盘的条目追加下去（生成 latest.log 前调一次，保证报告是最新的）
+ (void)flushNow;

/// 取走上次崩溃抢救出的时间线文本；取走后即归档，不会被重复输出。
/// 正常启动返回 nil —— 没崩溃过就是没有，不必解释。
+ (NSString * _Nullable)takeLastCrashTimeline;

/// 常规时间线日志路径（用于分享/导出；文件不存在返回 nil）
+ (NSString * _Nullable)timelineLogPath;

@end

/// 崩溃上下文专用：把此刻缓冲内的最后若干条以纯文本写到 path。
///
/// 只用 open / write / close，不分配堆内存、不调 Objective-C、不用 snprintf。
/// 刻意只取最近 64 条：信号处理器可能跑在受限的信号栈上，
/// 把 512 条（约 60KB）铺在栈上是在赌博，而最后 64 条已经足够回答
/// 「崩溃前几秒发生了什么」。这是吃苦力前先想清楚的取舍。
void DCLTimelineEmergencyDump(const char *path);

/// 崩溃时间线该写到哪个路径。返回静态缓冲区地址，永不释放 ——
/// 崩溃那一刻没有「取对象、拼路径」的余裕，路径必须在启动时就备好。
/// 未启动过持久化时返回 NULL（此时调用方应跳过，而不是自己拼一个路径）。
const char * _Nullable DCLTimelineCrashDumpPath(void);

NS_ASSUME_NONNULL_END
