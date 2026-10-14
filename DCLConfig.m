//
//  DCLConfig.m
//  DouyinCrashLogger
//
//  采集方案开关的读取与缓存。
//
//  取值优先级：
//    1) 沙盒内 Documents/DouyinCrashLogs/capture_mode.txt（用户用 Filza / 自签工具
//       导出容器后直接改，所见即所得，优先）
//    2) NSUserDefaults key DCL_capture_mode（备用通道，供将来其他入口写入）
//    3) 默认 safe
//
//  任何一步出错都兜底回 safe —— 开关读失败绝不能让插件停摆，
//  也绝不能因为读文件失败就擅自切到 hook 全开档。
//

#import "DCLConfig.h"
#import "DCLConstants.h"

#import <sys/stat.h>
#import <stdatomic.h>

/// 当前生效方案缓存：原子值，支持热切换即时翻面（见 setProfile: / toggleProfile）。
/// 初值由 captureProfile 首次调用时从开关文件读取并写入；之后读一律走原子值，
/// 不再碰盘 —— 这样热切换翻转后才能「不重启立即生效」。
static atomic_int dcl_profile_atomic = ATOMIC_VAR_INIT((int)DCLCaptureProfileSafe);

@implementation DCLConfig

#pragma mark - 路径

+ (NSString *)logsDirectory {
    // 与 DCLCrashReporter crashLogsDirectory 保持一致，但刻意不反向依赖它：
    // 本类可能在崩溃捕获之前的极早期被调用，依赖越少越稳。
    return [NSHomeDirectory() stringByAppendingPathComponent:DCLCrashLogsRelativeDir];
}

+ (NSString *)modeFilePath {
    return [[self logsDirectory] stringByAppendingPathComponent:DCLCaptureModeFileName];
}

#pragma mark - 读取

/// 默认开关文件内容：带完整说明，用户打开就能改，不用翻文档
static NSString *dcl_default_mode_file_text(void) {
    return @"# DouyinCrashLogger 采集方案开关（总开关也在这里）\n"
            "#\n"
            "# safe = A 方案（默认）：零 hook。只抓崩溃、上次退出性质、卡死时长、插件自检。\n"
            "# full = B 方案：hook 全开。在 A 之上额外抓播放暂停调用栈、触摸时间线、\n"
            "#                卡死时主线程栈与全线程冻结快照（日志更全）。\n"
            "# off  = 总开关关闭：本插件拒绝一切活动 —— 崩溃捕获 / 看门狗 / 播放探针 /\n"
            "#        时间线落盘 / 资源采样 / stderr 接管 / 日志写入全部不装或立即卸掉。\n"
            "#        （写 disable / kill / stop / 停用 / 关闭 也是同一个意思）\n"
            "#\n"
            "# 两档下所有钩子均为「原样透传、零吞事件」的旁路观测；\n"
            "# 若只需证明「有没有崩 / 上次是怎么退的」，保持 safe 即可。\n"
            "#\n"
            "# 也可在 App 内摇一摇循环切换（safe→full→off→safe，免文件、切换后顶部有提示）。\n"
            "# 注意：切到 off 只保留摇一摇与设置页入口 —— 那是唯一能把你切回来的通道。\n"
            "# 修改后完全退出并重启抖音生效。\n"
            "safe\n";
}

/// 解析开关文本：忽略空行与 # 注释行，取第一个有效行
static DCLCaptureProfile dcl_parse_mode_text(NSString *text) {
    if (!text.length) return DCLCaptureProfileSafe;
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet newlineCharacterSet]];
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length) continue;
        if ([line hasPrefix:@"#"] || [line hasPrefix:@";"] || [line hasPrefix:@"//"]) continue;

        NSString *low = line.lowercaseString;
        // off 必须排在最前面判定：它跟 safe/full 不是同一维度。
        // （更早的版本把 off 当成了 safe，于是「关掉」这个语义根本表达不出来 —— 已修。）
        if ([low isEqualToString:@"off"] ||
            [low isEqualToString:@"disable"] || [low isEqualToString:@"disabled"] ||
            [low isEqualToString:@"kill"] || [low isEqualToString:@"stop"] ||
            [low isEqualToString:@"none"] || [low isEqualToString:@"no"] ||
            [low containsString:@"停用"] || [low containsString:@"关闭"] ||
            [low containsString:@"停止"] || [low containsString:@"禁用"]) {
            return DCLCaptureProfileOff;
        }
        if ([low isEqualToString:@"full"] || [low isEqualToString:@"b"] ||
            [low isEqualToString:@"1"] || [low isEqualToString:@"on"] ||
            [low isEqualToString:@"yes"] || [low containsString:@"完整"] ||
            [low containsString:@"全量"] || [low containsString:@"full"]) {
            return DCLCaptureProfileFull;
        }
        // 注意 "0" 与 "1"（full）是成对的写法，仍归 safe；"off"/"no" 已归上面的总开关。
        if ([low isEqualToString:@"safe"] || [low isEqualToString:@"a"] ||
            [low isEqualToString:@"0"] || [low containsString:@"保守"] ||
            [low containsString:@"safe"]) {
            return DCLCaptureProfileSafe;
        }
        // 无法识别的内容：按最保守处理，并在日志里体现为 safe
        return DCLCaptureProfileSafe;
    }
    return DCLCaptureProfileSafe;
}

static DCLCaptureProfile dcl_read_profile(void) {
    @try {
        NSString *path = [DCLConfig modeFilePath];
        NSFileManager *fm = [NSFileManager defaultManager];

        if (![fm fileExistsAtPath:path]) {
            // 首次运行：生成带说明的默认文件，用户下次直接改这一行即可
            [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
            [dcl_default_mode_file_text() writeToFile:path
                                           atomically:YES
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
        }

        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        if (text.length) return dcl_parse_mode_text(text);

        // 文件为空或读不出来：退到 NSUserDefaults 备用通道
        id v = [[NSUserDefaults standardUserDefaults] objectForKey:DCLCaptureModeDefaultsKey];
        if ([v isKindOfClass:[NSString class]]) return dcl_parse_mode_text((NSString *)v);
        if ([v isKindOfClass:[NSNumber class]]) {
            return [(NSNumber *)v boolValue] ? DCLCaptureProfileFull : DCLCaptureProfileSafe;
        }
    } @catch (id e) {
        (void)e;
    }
    return DCLCaptureProfileSafe;
}

+ (DCLCaptureProfile)captureProfile {
    static dispatch_once_t once;
    // 用 dispatch_once 而非 __sync：构造期与多线程同时首次调用都要保证只读一次盘
    dispatch_once(&once, ^{
        @try { atomic_store(&dcl_profile_atomic, (int)dcl_read_profile()); }
        @catch (id e) { (void)e; atomic_store(&dcl_profile_atomic, (int)DCLCaptureProfileSafe); }
    });
    return (DCLCaptureProfile)atomic_load(&dcl_profile_atomic);
}

#pragma mark - 热切换（即时生效）

/// 档位 -> 落盘的文本（三态）
static NSString *dcl_profile_text(DCLCaptureProfile p) {
    switch (p) {
        case DCLCaptureProfileFull: return @"full\n";
        case DCLCaptureProfileOff:  return @"off\n";
        case DCLCaptureProfileSafe: return @"safe\n";
    }
    return @"safe\n";
}

+ (void)setProfile:(DCLCaptureProfile)profile {
    // 先翻原子值：此后所有 captureProfile 调用立即见到新值，无需重启
    atomic_store(&dcl_profile_atomic, (int)profile);
    @try {
        // 双写持久层：NSUserDefaults（备选通道）+ capture_mode.txt（优先通道），
        // 保证完全退出重启抖音后依然保持本次选择。
        NSString *text = dcl_profile_text(profile);
        NSString *path = [self modeFilePath];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSString *v = [dcl_profile_text(profile) stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [[NSUserDefaults standardUserDefaults] setObject:v forKey:DCLCaptureModeDefaultsKey];
    } @catch (id e) {
        (void)e;
    }
}

+ (void)toggleProfile {
    // 三态循环：safe → full → off → safe。
    // 顺序有讲究：从最常用的 safe 出发，先给更全的档位，最后才到「彻底停用」，
    // 免得手一抖就从「开」摇到「关」还以为插件坏了。
    DCLCaptureProfile cur = [self captureProfile];
    DCLCaptureProfile next;
    switch (cur) {
        case DCLCaptureProfileSafe: next = DCLCaptureProfileFull; break;
        case DCLCaptureProfileFull: next = DCLCaptureProfileOff;  break;
        case DCLCaptureProfileOff:  next = DCLCaptureProfileSafe; break;
    }
    [self setProfile:next];
}

#pragma mark - 摇一摇防误触开关

+ (BOOL)shakeEnabled {
    // key 不存在（从未设置过）→ 默认 YES，保持老行为
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:DCLShakeEnabledDefaultsKey];
    if (!v) return YES;
    return [v boolValue];
}

+ (void)setShakeEnabled:(BOOL)enabled {
    @try {
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:DCLShakeEnabledDefaultsKey];
    } @catch (id e) {
        (void)e;
    }
}

#pragma mark - 能力矩阵

+ (BOOL)isDisabled {
    return [self captureProfile] == DCLCaptureProfileOff;
}

+ (NSString *)profileName {
    switch ([self captureProfile]) {
        case DCLCaptureProfileFull: return @"full";
        case DCLCaptureProfileOff:  return @"off";
        case DCLCaptureProfileSafe: return @"safe";
    }
    return @"safe";
}

+ (NSString *)profileDisplayName {
    switch ([self captureProfile]) {
        case DCLCaptureProfileFull: return @"B 方案（full，hook 全开 · 日志更全）";
        case DCLCaptureProfileOff:  return @"已停用（off · 本插件零活动）";
        case DCLCaptureProfileSafe: return @"A 方案（safe，零 hook · 默认）";
    }
    return @"A 方案（safe，零 hook · 默认）";
}

+ (BOOL)hooksEnabled {
    return [self captureProfile] == DCLCaptureProfileFull;
}

+ (BOOL)deepEvidenceEnabled {
    return [self captureProfile] == DCLCaptureProfileFull;
}

+ (NSArray<NSString *> *)enabledCapabilities {
    if ([self isDisabled]) {
        return @[@"（总开关 off：本插件当前不采集、不写盘、不接管 stderr，仅保留摇一摇与入口）"];
    }
    NSMutableArray *a = [NSMutableArray array];
    [a addObject:@"崩溃信号捕获（SIGABRT/SEGV/BUS/TRAP/ILL/FPE/PIPE）"];
    [a addObject:@"OC 未捕获异常捕获（NSUncaughtExceptionHandler）"];
    [a addObject:@"上次退出性质判定（区分主动划掉 / 后台回收 / 真闪退）"];
    [a addObject:@"主线程卡死时长检测（CFRunLoopObserver 公开 API，非 hook）"];
    [a addObject:@"插件健康自检（证明「插件在工作」本身）"];
    // 这两项零 hook —— 系统层信号是「自研播放器钩不到」时的兜底证据，
    // 统一时间线只是把已有事件排在同一条轴上，没有理由因为档位降级而放弃。
    [a addObject:@"系统层暂停硬信号（音频中断/路由变更/前后台/锁屏/内存警告，零 hook）"];
    [a addObject:@"统一时间线（所有事件共用 mach_absolute_time，可对齐因果）"];
    if ([self captureProfile] == DCLCaptureProfileFull) {
        [a addObject:@"视频暂停/播放的发起者调用栈（旁路 hook，原样透传）"];
        [a addObject:@"触摸时间线（暂停是否紧随触摸发生）"];
        [a addObject:@"卡死时主线程栈采样与归因（锁等待 / IO / 长计算 / 第三方注入）"];
        [a addObject:@"卡死与截图时的全线程冻结快照（死锁取证）"];
    }
    return a;
}

+ (NSArray<NSString *> *)disabledCapabilities {
    if ([self isDisabled]) {
        return @[@"总开关 off —— 所有能力均未启用（崩溃捕获、看门狗、播放探针、时间线、资源采样全部未安装）",
                 @"摇一摇切换与设置页入口仍在：那是唯一能把总开关切回来的通道"];
    }
    if ([self captureProfile] == DCLCaptureProfileFull) {
        return @[@"无（已是最高采集档位）"];
    }
    return @[
        @"视频暂停/播放的发起者调用栈 —— 需 full 档挂载 AVPlayer 旁路钩子",
        @"触摸时间线 —— 需 full 档挂载 UIApplication sendEvent: 旁路钩子",
        @"卡死时主线程栈与归因 —— 需 full 档开启 suspend 采样",
        @"全线程冻结快照 —— 需 full 档开启（会短暂 suspend 非主线程，仅卡死/截图瞬间）",
    ];
}

+ (NSString *)switchGuide {
    return [NSString stringWithFormat:
            @"编辑沙盒内 %@/%@，内容写 safe / full / off（# 开头的注释行会被忽略；"
            @"写 disable / kill / 停用 / 关闭 等同于 off），完全退出并重启抖音生效。"
            @"也可在 App 内摇一摇循环切换（safe→full→off→safe）。当前生效值：%@。",
            DCLCrashLogsRelativeDir, DCLCaptureModeFileName, [self profileName]];
}

@end
