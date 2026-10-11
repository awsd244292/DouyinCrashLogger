//
//  DCLMain.m
//  DouyinCrashLogger
//
//  不含任何 UI 层；仅做崩溃捕获、日志落盘，以及三个纯旁路观测探针
//  （主线程看门狗 / 视频暂停归因 / 健康自检）。
//
//  两档采集方案（见 DCLConfig.h，开关：Documents/DouyinCrashLogs/capture_mode.txt）：
//    A 方案 safe（默认）：零 hook。崩溃捕获 + 退出性质 + 卡死时长 + 健康自检。
//    B 方案 full：hook 全开。在 A 之上额外抓暂停调用栈、触摸时间线、卡死时
//                 主线程栈与全线程冻结快照 —— 日志更全，用于深挖疑难问题。
//  所有 hook 均原样透传、零吞事件，仅为取证打点，绝不改变程序行为。
//
//  日志位置（App 沙盒内，直接用 Filza / 自签工具导出容器即可读取）：
//    Documents/DouyinCrashLogs/
//      ├── crash_<时间戳>_P<pid>.log   崩溃报告（信号 + OC 异常 + 回溯 + 镜像基址表）
//      ├── plugin_runtime.log          stderr/stdout 重定向 + 每次启动的退出状态标记
//      └── latest.log                  最新状态快照（播放诊断 + 健康自检 + 上次退出性质）
//
//  时序（防闪退）：
//   1) constructor 早期：安装信号/OC 异常捕获、清理旧日志、写入上次退出状态标记。
//      —— 捕获必须尽早，否则启动早期的崩溃抓不到。
//   2) 延迟 2s 主线程：按当前采集方案安装看门狗（两档都装）与播放探针（仅 full 档），
//      再做 freopen 重定向 stderr/stdout，并自动写一份 latest.log。
//      —— 这两类 install 在头文件中明确标注「绝不在 constructor 阶段」，故延迟到此；
//         freopen 同样绝不能放在 constructor / +load 阶段，否则影响注入早期稳定性。
//

#import <UIKit/UIKit.h>

#import "DCLCrashReporter.h"
#import "DCLWatchdog.h"
#import "DCLPlaybackTracer.h"
#import "DCLConfig.h"

__attribute__((constructor)) static void dcl_entry(void) {
    @try {
        // 1) 崩溃捕获尽早安装（不可延迟）
        [DCLCrashReporter install];
        [DCLCrashReporter cleanupOldLogs];

        // 2) 退出状态标记：把「上次是否疑似闪退」追加写入 plugin_runtime.log，
        //    这样即使没有 App 内页面，直接读容器里的文件也能判断；
        //    同时注册 WillTerminate 观察者，供下一轮判定。
        [DCLCrashReporter recordExitMarkAndRegisterTerminateObserver];

        // 3) 注册「生成最新日志 latest.log」的触发器（截图 / 进入后台）
        [DCLCrashReporter registerSnapshotTriggers];
    } @catch (id e) {
        (void)e;
    }

    // 4) 以下「重活」全部延迟到主 runloop 稳定后，且放到主线程（dispatch 到 main queue）：
    //    - Watchdog 安装（需在主线程挂 CFRunLoopObserver + 起后台线程）；
    //    - 播放暂停探针安装（方法交换 AVPlayer / UIApplication，需类已加载且主线程）；
    //    - stderr/stdout 重定向；
    //    - 自动写一份最新快照，保证即使从不主动触发也有 latest.log。
    //    两个 install 在头文件里明确标注「绝不在 constructor 阶段」，故置于此处而非入口早期。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            // 看门狗：只挂 CFRunLoopObserver（公开 API，非 hook），两档方案都装 ——
            // 「卡了多久」是最基础的事实，没有理由因为方案降级而放弃。
            [DCLWatchdog install];

            // 播放探针会交换 AVPlayer / UIApplication 的方法实现 —— 只有 B 方案（full）才装。
            // A 方案（safe）下这一分支不执行，本进程内不会有任何方法交换。
            if ([DCLConfig hooksEnabled]) {
                [DCLPlaybackTracer install];
            }

            [DCLCrashReporter redirectStderrToRuntimeLog];
            [DCLCrashReporter writeLatestLogWithReason:@"启动完成（自动）"];
        } @catch (id e) {
            (void)e;
        }
    });
}
