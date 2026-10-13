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
//      ├── plugin_runtime.log          本次会话的运行日志（每轮冷启动轮转一次，大小有闸门）
//      ├── plugin_runtime_prev.log     上一会话的运行日志（只留一份）
//      └── latest.log                  最新状态快照（播放诊断 + 健康自检 + 上次退出性质）
//
//  为什么 runtime 日志要按会话拆开：以前所有会话都往同一个文件里追加，
//  以前所有会话都往同一个 plugin_runtime.log 里追加，宿主再在里面刷屏，
//  文件动辄几 MB 且从不清顶部，真正有用的那几行早被冲没了。现在当前会话永远从干净的一页开始写。
//
//  时序（防闪退）：
//   1) constructor 早期：日志轮转与清理、安装信号/OC 异常捕获、写入上次退出状态标记。
//      —— 捕获必须尽早，否则启动早期的崩溃抓不到。
//   2) 延迟 2s 主线程：按当前采集方案安装看门狗（两档都装）与播放探针（仅 full 档），
//      再做 stderr/stdout 重定向，并自动写一份 latest.log。
//      —— 这两类 install 在头文件中明确标注「绝不在 constructor 阶段」，故延迟到此；
//         重定向同理，绝不能放在 constructor / +load 阶段，否则影响注入早期稳定性。
//

#import <UIKit/UIKit.h>

#import "DCLCrashReporter.h"
#import "DCLWatchdog.h"
#import "DCLPlaybackTracer.h"
#import "DCLConfig.h"
#import "DCLHotSwitch.h"
#import "DCLLogger.h"
#import "DCLSystemSignal.h"
#import "DCLTimelinePersist.h"
#import "DCLResourceProbe.h"
#import "DCLSettings.h"
#import "DCLMain.h"

@implementation DCLOrchestrator

+ (void)startupAll {
    @try { [DCLLogger setLoggingEnabled:YES]; }                     @catch (id e) { (void)e; }

    // 崩溃捕获：信号 + OC 异常。它必须在装别的东西之前就位 ——
    // 后面几步里万一有个闪失，至少那次崩溃还有人记录。
    @try { [DCLCrashReporter install]; }                            @catch (id e) { (void)e; }
    @try { [DCLCrashReporter registerSnapshotTriggers]; }           @catch (id e) { (void)e; }
    @try { [DCLCrashReporter startHandlerSelfHealing]; }            @catch (id e) { (void)e; }

    @try { [DCLWatchdog install]; }                                 @catch (id e) { (void)e; }
    @try { [DCLSystemSignal install]; }                             @catch (id e) { (void)e; }
    @try { [DCLTimelinePersist startWithDirectory:[DCLCrashReporter crashLogsDirectory]]; }
    @catch (id e) { (void)e; }
    @try { [DCLResourceProbe start]; }                              @catch (id e) { (void)e; }

    // 播放探针要交换 AVPlayer / UIApplication 的方法实现，只有 full 档才装。
    // 从 safe 热切到 full 时，就是这一行把它补上的（即时生效，不必等重启）。
    @try { if ([DCLConfig hooksEnabled]) { [DCLPlaybackTracer install]; } }
    @catch (id e) { (void)e; }

    // stderr / stdout 接管：装在最后，且必须在主 runloop 稳定后（此处满足）。
    @try { [DCLCrashReporter redirectStderrToRuntimeLog]; }         @catch (id e) { (void)e; }
}

+ (void)shutdownAll {
    // 顺序不是随便排的：先卸「会往日志里写东西的」，再卸「产生日志的」，
    // 最后才交还输出通道 —— 倒过来的话，卸载过程本身又会写出一堆新日志。
    @try { [DCLPlaybackTracer  uninstall]; }   @catch (id e) { (void)e; }
    @try { [DCLWatchdog        uninstall]; }   @catch (id e) { (void)e; }
    @try { [DCLSystemSignal    uninstall]; }   @catch (id e) { (void)e; }
    @try { [DCLTimelinePersist stop]; }        @catch (id e) { (void)e; }
    @try { [DCLResourceProbe   stop]; }        @catch (id e) { (void)e; }

    // 崩溃捕获卸载里含：停自愈巡检 → 还原信号 / 异常处理器 → 摘快照通知 → 交还 stderr
    @try { [DCLCrashReporter uninstall]; }     @catch (id e) { (void)e; }
}

+ (void)applyCurrentProfile {
    @try {
        if ([DCLConfig isDisabled]) {
            // 留痕必须在关闸门之前：这一行是日后唯一能证明「确实关过」的东西。
            [DCLLogger appendRuntimeLine:
             @"[DCL] total switch OFF (user): unloading crash capture, watchdog, hooks, log pump"];
            [DCLLogger setLoggingEnabled:NO];
            [self shutdownAll];
        } else {
            [self startupAll];
            [DCLLogger appendRuntimeLine:
             [NSString stringWithFormat:@"[DCL] total switch ON -> %@", [DCLConfig profileName]]];
        }
    } @catch (id e) {
        (void)e;
    }
}

@end

__attribute__((constructor)) static void dcl_entry(void) {
    @try {
        if ([DCLConfig isDisabled]) {
            // 总开关 off：不轮转、不清理、不装捕获、不写盘。
            // 唯一还做的这件事是「退出性质标记」—— 它只写两个 bool 进 NSUserDefaults，
            // 不碰任何日志文件，却是下次启动区分「用户划掉」与「真闪退」的唯一依据。
            // 少了它，off 期间正常退出一轮，再切回来就会被误判成可疑闪退。
            [DCLCrashReporter recordExitMarkAndRegisterTerminateObserver];
        } else {
            // 1) 先把日志文件整理好：当前会话单独一份、上一会话留一份、按份数/超龄/总量清
            //    —— 必须在任何日志写入之前做，否则本轮的内容会被当成旧账轮转走。
            [DCLLogger rotateRuntimeLogAtLaunch];

            // 2) 崩溃捕获尽早安装（不可延迟）
            [DCLCrashReporter install];
            [DCLCrashReporter cleanupOldLogs];

            // 3) 退出状态标记：把「上次是否疑似闪退」追加写入本轮 runtime 日志，
            //    这样即使没有 App 内页面，直接读容器里的文件也能判断；
            //    同时注册 WillTerminate 观察者，供下一轮判定。
            [DCLCrashReporter recordExitMarkAndRegisterTerminateObserver];

            // 4) 注册「生成最新日志 latest.log」的触发器（截图 / 进入后台）
            [DCLCrashReporter registerSnapshotTriggers];
        }
    } @catch (id e) {
        (void)e;
    }

    // 5) 以下「重活」全部延迟到主 runloop 稳定后，且放到主线程（dispatch 到 main queue）：
    //    - Watchdog 安装（需在主线程挂 CFRunLoopObserver + 起后台线程）；
    //    - 播放暂停探针安装（方法交换 AVPlayer / UIApplication，需类已加载且主线程）；
    //    - stderr/stdout 重定向；
    //    - 自动写一份最新快照，保证即使从不主动触发也有 latest.log。
    //    两个 install 在头文件里明确标注「绝不在 constructor 阶段」，故置于此处而非入口早期。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            // 两处自救通道，与档位无关，永远安装 ——
            // off 档下若连它们也卸了，用户就只剩「改沙盒文件」这一条路可走。
            // 摇一摇：翻转 safe → full → off → safe，免文件（详见 DCLHotSwitch.h）。
            [DCLHotSwitch install];

            // 设置入口接入 DYStorage：仅在 DYStorage 已安装时注册一个菜单项，
            // 由它统一渲染与派发点击，本插件不自己 Hook 抖音设置页 —— 避免多插件
            // 共存时重复 swizzle 设置 VC 互相踩踏。未安装则静默跳过（保持纯后台）。
            [DCLSettings registerEntry];

            if ([DCLConfig isDisabled]) {
                // 冷启动即 off：上面两步已装的东西里没有采集模块，这里只做一次
                // 保险性的归零，把任何可能被别处提前装起来的东西收干净。
                [DCLOrchestrator shutdownAll];
                return;
            }

            // 以下「重活」全部延迟到主 runloop 稳定后，且放到主线程：
            //   - Watchdog 安装（需在主线程挂 CFRunLoopObserver + 起后台线程）；
            //   - 播放暂停探针安装（方法交换 AVPlayer / UIApplication，需类已加载且主线程）；
            //   - stderr/stdout 重定向（绝不能放在 constructor / +load 阶段）。
            // 两个 install 在头文件里明确标注「绝不在 constructor 阶段」，故置于此处。
            [DCLOrchestrator startupAll];

            // 启动标记 / 上次退出性质：必须在沙盒就绪、runloop 启动后才写 runtime 日志，
            // 否则 constructor 阶段 NSHomeDirectory 未就位 / GCD 异步块未调度 → 写入落空。
            [DCLCrashReporter appendLaunchVerdictToRuntimeLog];

            // 自动写一份最新快照，保证即使从不主动触发也有 latest.log。
            [DCLCrashReporter writeLatestLogWithReason:@"启动完成（自动）"];
        } @catch (id e) {
            (void)e;
        }
    });
}
