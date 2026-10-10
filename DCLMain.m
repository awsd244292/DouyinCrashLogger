//
//  DCLMain.m
//  DouyinCrashLogger
//
//  极简版：只做「崩溃捕获 + 日志落盘」，不含任何 UI、不 hook 任何方法。
//
//  日志位置（App 沙盒内，直接用 Filza / 自签工具导出容器即可读取）：
//    Documents/DouyinCrashLogs/
//      ├── crash_<时间戳>_P<pid>.log   崩溃报告（信号 + OC 异常 + 回溯 + 镜像基址表）
//      └── plugin_runtime.log          stderr/stdout 重定向 + 每次启动的退出状态标记
//
//  时序（防闪退）：
//   1) constructor 早期：安装信号/OC 异常捕获、清理旧日志、写入上次退出状态标记。
//      —— 捕获必须尽早，否则启动早期的崩溃抓不到。
//   2) 延迟 2s 主线程：freopen 重定向 stderr/stdout。
//      —— freopen 绝不能放在 constructor / +load 阶段，否则影响注入早期稳定性。
//

#import <UIKit/UIKit.h>

#import "DCLCrashReporter.h"

__attribute__((constructor)) static void dcl_entry(void) {
    @try {
        // 1) 崩溃捕获尽早安装（不可延迟）
        [DCLCrashReporter install];
        [DCLCrashReporter cleanupOldLogs];

        // 2) 退出状态标记：把「上次是否疑似闪退」追加写入 plugin_runtime.log，
        //    这样即使没有 App 内页面，直接读容器里的文件也能判断；
        //    同时注册 WillTerminate 观察者，供下一轮判定。
        [DCLCrashReporter recordExitMarkAndRegisterTerminateObserver];
    } @catch (id e) {
        (void)e;
    }

    // 3) stderr/stdout 重定向延迟 2s，等主 runloop 稳定后再执行
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            [DCLCrashReporter redirectStderrToRuntimeLog];
        } @catch (id e) {
            (void)e;
        }
    });
}
