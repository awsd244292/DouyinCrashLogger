//
//  DCLResourceProbe.h
//  DouyinCrashLogger
//
//  进程健康水位采样：给「上次为什么退出」留证据。
//
//  为什么需要它：
//    现有退出判定能分清「正常退出 / 后台被杀 / 真崩溃（有崩溃报告）」，
//    但剩下那一档只能写「疑似闪退 —— 可能是 OOM / watchdog / 早期崩溃」。
//    这一档恰恰是取证价值最高、也最难的一档：
//      · SIGKILL 拦不住（不管是 OOM 还是 watchdog，应用层都收不到信号）
//      · 系统不留只言片语，唯一能指望的就是「进程自己最后一刻记了什么」
//
//  做法（与 KSCrash / Matrix 一致）：活着的进程定期在自己的病历上写一行：
//     当下占了多少内存、系统还剩多少可用内存、主线程最近卡了多久。
//  进程被杀后有且只有这些是能活下来的 —— 它们决定了下一轮能否把
//  「疑似」坐实为「几乎确定是 OOM」或「高度疑似 watchdog」。
//
//  采样代价必须低：15 秒一次、只读 mach/OS 计数器、不做栈回溯、不落磁盘
//  （NSUserDefaults 的写入由系统兜着，且每次立刻 synchronize ——
//   被 OOM 杀掉时没有「稍后再同步」的机会）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCLResourceProbe : NSObject

/// 启动周期采样。任意线程可调用，内部自行切队列。重复调用只有第一次生效。
+ (void)start;

/// 停止周期采样并释放队列/定时器（总开关 off 时用）。
/// 已采到的水位数据留在内存里供 latest.log 读取，只是不再继续采。
+ (void)stop;

/// 上一轮会话遗留下来的水位快照。首次安装返回 nil。
/// 字段：peakFootprint / lastFootprint / lastAvailable / lastStallMs / samples
+ (NSDictionary<NSString *, id> * _Nullable)previousSessionWatermark;

/// 本会话采样到的内存峰值（字节；phys_footprint，最接近系统判定内存占用口径）
+ (unsigned long long)peakFootprintBytes;

/// 本会话最近一次采样到的系统可用内存（字节）。返回 0 表示尚未采样。
+ (unsigned long long)lastAvailableBytes;

/// 一句话现状（latest.log 里给人看的）
+ (NSString *)currentStatusLine;

@end

NS_ASSUME_NONNULL_END
