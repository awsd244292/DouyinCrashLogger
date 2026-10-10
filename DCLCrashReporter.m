//
//  DCLCrashReporter.m
//  DouyinCrashLogger
//
//  崩溃捕获核心实现。
//

#import "DCLCrashReporter.h"
#import "DCLConstants.h"

#import <UIKit/UIKit.h>
#import <sys/signal.h>
#import <execinfo.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <pthread.h>

#pragma mark - 全局状态（信号处理路径只读这些）

static volatile sig_atomic_t g_handling = 0;
static int g_installed = 0;

// 非崩溃上下文预收集、信号处理路径只读：
static char g_meta[2048] = {0};          // 设备/系统/App 版本等多行文本
static char g_logDir[1024] = {0};        // 崩溃日志目录绝对路径（C 字符串）
static char g_tmpPath[2048] = {0};       // 当前正在写入的日志路径（用于异常路径续写）

// 启动时预收集已加载镜像（基址 + 路径）。信号处理路径只做只读 write，
// 不调用 dladdr（非 async-signal-safe，易死锁/丢栈）。atos 符号化时据此基址表映射地址。
static char g_image_table[262144] = {0};
static uint32_t g_image_count = 0;

// 退出标记相关（非崩溃上下文读写，供 UI 展示“上次退出状态”）
static BOOL g_prev_exit_normal = NO;   // 上一轮启动时的“正常退出”标记
static BOOL g_first_launch = YES;      // 是否从未写过退出标记（首次运行）
static NSDate *g_last_normal_exit_date = nil; // 上一轮正常退出的时间

#pragma mark - 小工具（async-signal-safe）

static const char *dcl_signal_name(int sig) {
    switch (sig) {
        case SIGABRT: return "SIGABRT";
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGTRAP: return "SIGTRAP";
        case SIGILL:  return "SIGILL";
        case SIGFPE:  return "SIGFPE";
        case SIGPIPE: return "SIGPIPE";
        default:      return "SIGUNKNOWN";
    }
}

// async-signal-safe 的整段写出
static void dcl_write_all(int fd, const char *s) {
    if (!s) return;
    size_t n = strlen(s);
    while (n > 0) {
        ssize_t w = write(fd, s, n);
        if (w <= 0) break;
        s += w;
        n -= (size_t)w;
    }
}

// 生成形如 "crash_<epochsec>_<usec>_P<pid>.log" 的路径并打开文件描述符
static int dcl_open_report_file(void) {
    if (g_logDir[0] == '\0') return -1;
    struct timeval tv;
    gettimeofday(&tv, NULL); // 明确 async-signal-safe
    long long epoch = (long long)tv.tv_sec;
    long long usec  = (long long)tv.tv_usec;

    char path[2048];
    int n = snprintf(path, sizeof(path), "%s/crash_%lld_%06lld_P%d.log",
                     g_logDir, epoch, usec, (int)getpid());
    if (n < 0 || n >= (int)sizeof(path)) return -1;

    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        strncpy(g_tmpPath, path, sizeof(g_tmpPath) - 1);
    }
    return fd;
}

// 写出回溯（signal 路径）：仅记录原始地址，不调用 dladdr / backtrace_symbols。
// dladdr 非 async-signal-safe，handler 内调用可能触发内部锁导致二次崩溃/死锁、丢栈。
// 符号化交由用户在 macOS 上用 atos + 上方 Loaded images 基址表还原。
static void dcl_write_backtrace(int fd, void **frames, int nframes) {
    char line[64];
    for (int i = 0; i < nframes; i++) {
        snprintf(line, sizeof(line), "#%-3d 0x%llx\n", i,
                 (unsigned long long)(uintptr_t)frames[i]);
        dcl_write_all(fd, line);
    }
}

// 写一个完整报告（signal 路径入口）
static void dcl_write_report_c(const char *type, const char *detail,
                               void **frames, int nframes) {
    int fd = dcl_open_report_file();
    if (fd < 0) return;

    dcl_write_all(fd, "========== DouyinCrashLogger Crash Report ==========\n");
    dcl_write_all(fd, "Time(epoch): ");
    // 已在文件名包含时间；这里再写一次便于检索
    dcl_write_all(fd, "(see filename)\n");
    dcl_write_all(fd, g_meta);                     // 预收集的设备/系统/App 信息
    dcl_write_all(fd, "CrashType: ");
    dcl_write_all(fd, type);
    dcl_write_all(fd, "\n");
    if (detail && detail[0]) {
        dcl_write_all(fd, "Detail: ");
        dcl_write_all(fd, detail);
        dcl_write_all(fd, "\n");
    }
    dcl_write_all(fd, "\n--- Loaded images (base -> module) ---\n");
    dcl_write_all(fd, g_image_table);
    dcl_write_all(fd, "\n--- Backtrace (crashed thread, raw addresses) ---\n");
    dcl_write_backtrace(fd, frames, nframes);
    dcl_write_all(fd, "===================================================\n");

    fsync(fd);
    close(fd);
}

#pragma mark - 信号处理

static void dcl_signal_handler(int sig, siginfo_t *info, void *uctx) {
    // 递归保护：已在处理中则放弃，避免死循环
    if (__sync_fetch_and_or(&g_handling, 1)) {
        return;
    }

    void *frames[64];
    int n = backtrace(frames, 64);

    char type[48];
    snprintf(type, sizeof(type), "%s(%d)", dcl_signal_name(sig), sig);

    char detail[160];
    detail[0] = '\0';
    if (info) {
        snprintf(detail, sizeof(detail),
                 "fault address: 0x%llx, signal code: %d",
                 (unsigned long long)(uintptr_t)info->si_addr, info->si_code);
    }

    dcl_write_report_c(type, detail, frames, n);

    // 恢复默认处置并重新触发，让系统生成标准 crash report 作为补充，然后终止进程
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, NULL);
    raise(sig);
    _exit(130);
}

static void dcl_install_signals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = dcl_signal_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);

    int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGFPE, SIGPIPE};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        sigaction(signals[i], &sa, NULL);
    }
}

#pragma mark - OC 未捕获异常

static void dcl_uncaught_exception_handler(NSException *exception) {
    if (__sync_fetch_and_or(&g_handling, 1)) {
        return;
    }

    // @try/@catch 包裹：捕获模块自身异常，避免覆盖原始崩溃栈
    @try {
        @autoreleasepool {
            // OC 异常路径无信号重入风险，用 Foundation 写出可读性更高的报告
            NSString *dir = [DCLCrashReporter crashLogsDirectory];
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

            struct timeval tv;
            gettimeofday(&tv, NULL);

            NSString *meta = [NSString stringWithUTF8String:g_meta];
            NSMutableString *report = [NSMutableString string];
            [report appendString:@"========== DouyinCrashLogger Crash Report ==========\n"];
            [report appendFormat:@"Time(unix): %lld.%06lld\n", (long long)tv.tv_sec, (long long)tv.tv_usec];
            if (meta.length) [report appendString:meta];
            [report appendFormat:@"CrashType: NSException:%@\n", exception.name ?: @"(null)"];
            [report appendFormat:@"Detail: reason: %@\n", exception.reason ?: @"(null)"];
            [report appendString:@"\n--- callStackSymbols ---\n"];
            NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
            [report appendString:(stack ?: @"(none)")];
            [report appendString:@"\n===================================================\n"];

            NSString *fileName = [NSString stringWithFormat:@"crash_%lld_%06lld_P%d.log",
                                  (long long)tv.tv_sec, (long long)tv.tv_usec, (int)getpid()];
            NSString *path = [dir stringByAppendingPathComponent:fileName];
            [report writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (id e) {
        (void)e;
    }
}

#pragma mark - 镜像基址表预收集（非崩溃上下文，供崩溃日志映射地址）

// 启动时收集所有已加载镜像的基址与路径，写入 g_image_table。
// 信号处理路径只只读该缓冲区，不调用 dladdr（非 async-signal-safe）。
static void dcl_prepare_images(void) {
    uint32_t cnt = _dyld_image_count();
    g_image_count = cnt;
    size_t off = 0;
    for (uint32_t i = 0; i < cnt; i++) {
        const struct mach_header *hdr = _dyld_get_image_header(i);
        const char *name = _dyld_get_image_name(i);
        if (!hdr || !name) continue;
        int n = snprintf(g_image_table + off, sizeof(g_image_table) - off,
                         "Image %u 0x%llx %s\n", i,
                         (unsigned long long)(uintptr_t)hdr, name);
        if (n < 0) break;
        off += (size_t)n;
        if (off >= sizeof(g_image_table) - 128) break;
    }
}

#pragma mark - 元信息预收集（非崩溃上下文）

static void dcl_prepare_meta(void) {
    char machine[128] = "unknown";
    size_t sz = sizeof(machine);
    sysctlbyname("hw.machine", machine, &sz, NULL, 0);

    @autoreleasepool {
        UIDevice *dev = [UIDevice currentDevice];
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *appName = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"??";
        NSString *appVer  = info[@"CFBundleShortVersionString"] ?: @"??";
        NSString *bundle  = info[@"CFBundleIdentifier"] ?: @"??";
        NSString *meta = [NSString stringWithFormat:
            @"Device: %s\n"
            @"OS: %@\n"
            @"App: %@ (%@) v%@\n"
            @"Reporter: DouyinCrashLogger 1.0\n",
            machine, dev.systemVersion ?: @"??", appName, bundle, appVer];
        strncpy(g_meta, [meta UTF8String] ?: "", sizeof(g_meta) - 1);
        g_meta[sizeof(g_meta) - 1] = '\0';
    }
}

#pragma mark - 公开接口

@implementation DCLCrashReporter

+ (NSString *)crashLogsDirectory {
    return [NSHomeDirectory() stringByAppendingPathComponent:DCLCrashLogsRelativeDir];
}

+ (void)cleanupOldLogs {
    @autoreleasepool {
        NSString *dir = [self crashLogsDirectory];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        for (NSString *f in files) {
            if (![f hasPrefix:@"crash_"]) continue;
            NSString *p = [dir stringByAppendingPathComponent:f];
            NSDictionary *attrs = [fm attributesOfItemAtPath:p error:nil];
            [items addObject:@{@"path": p,
                              @"date": attrs[NSFileModificationDate] ?: [NSDate distantPast]}];
        }
        [items sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"date"
                                                                  ascending:NO]]];
        for (NSUInteger i = DCLMaxRetainedLogs; i < items.count; i++) {
            [fm removeItemAtPath:items[i][@"path"] error:nil];
        }

        // 同步 C 缓冲区供信号处理路径使用
        strncpy(g_logDir, [dir UTF8String] ?: "", sizeof(g_logDir) - 1);
        g_logDir[sizeof(g_logDir) - 1] = '\0';
    }
}

+ (void)install {
    if (g_installed) return;
    g_installed = 1;

    dcl_prepare_meta();

    // 确保目录存在并填充 g_logDir
    NSString *dir = [self crashLogsDirectory];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    strncpy(g_logDir, [dir UTF8String] ?: "", sizeof(g_logDir) - 1);
    g_logDir[sizeof(g_logDir) - 1] = '\0';

    dcl_prepare_images();
    dcl_install_signals();
    NSSetUncaughtExceptionHandler(&dcl_uncaught_exception_handler);
}

#pragma mark - 退出标记 / 运行时日志

+ (NSString *)runtimeLogPath {
    return [[self crashLogsDirectory] stringByAppendingPathComponent:DCLRuntimeLogFileName];
}

+ (void)recordExitMarkAndRegisterTerminateObserver {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        id val = [ud objectForKey:DCLLastExitNormalKey];
        if (val == nil) {
            // 没有任何历史退出标记：视为首次运行
            g_first_launch = YES;
            g_prev_exit_normal = NO;
        } else {
            g_first_launch = NO;
            g_prev_exit_normal = [val boolValue];
        }

        // 上一轮正常退出的时间戳（由上一轮的 WillTerminate 写入）
        id t = [ud objectForKey:DCLLastNormalExitTimeKey];
        if ([t isKindOfClass:[NSNumber class]]) {
            g_last_normal_exit_date = [NSDate dateWithTimeIntervalSince1970:[t doubleValue]];
        }

        // 关键：先把“本次尚未正常终止”写回 NO。若随后进程被 SIGKILL / OOM / 崩溃，
        // 不会触发 WillTerminate，下一轮启动读到 NO 即判定为“疑似闪退（无 ips）”。
        [ud setObject:@(NO) forKey:DCLLastExitNormalKey];
        [ud synchronize];

        // 注册标准终止观察者：只有走正常退出流程才会触发，写回 YES + 时间戳。
        // 观察者挂在类对象（元类，进程生命周期内常驻）上，无需额外持有 token。
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(dcl_appWillTerminate:)
                   name:UIApplicationWillTerminateNotification
                 object:nil];

        // 把「上次退出状态」追加写入 plugin_runtime.log：
        // 极简版没有 App 内页面，直接读容器里的文件时据此判断上次是否疑似闪退。
        NSString *path = [self runtimeLogPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:[self crashLogsDirectory]
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:nil];
        FILE *f = fopen([path UTF8String], "a");
        if (f) {
            struct timeval tv;
            gettimeofday(&tv, NULL);
            fprintf(f, "----- [DCL] launch @ %lld.%06lld -----\n",
                    (long long)tv.tv_sec, (long long)tv.tv_usec);
            if (g_first_launch) {
                fprintf(f, "[DCL] 上次退出状态：首次运行（无历史记录）\n");
            } else if (!g_prev_exit_normal) {
                fprintf(f, "[DCL] 上次退出状态：疑似闪退（无 ips 日志，可能 SIGKILL/OOM/早期崩溃）\n");
            } else {
                fprintf(f, "[DCL] 上次退出状态：正常\n");
            }
            if (g_last_normal_exit_date) {
                fprintf(f, "[DCL] 上次正常退出时间：%s\n",
                        [[g_last_normal_exit_date description] UTF8String]);
            }
            fclose(f);
        }
    } @catch (id e) {
        (void)e;
    }
}

+ (void)dcl_appWillTerminate:(NSNotification *)note {
    @try {
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        [u setObject:@(YES) forKey:DCLLastExitNormalKey];
        [u setObject:@([[NSDate date] timeIntervalSince1970]) forKey:DCLLastNormalExitTimeKey];
        [u synchronize];
    } @catch (id e) {
        (void)e;
    }
}

+ (BOOL)lastExitWasAbnormal {
    // 非首次运行 且 上一轮未正常退出
    return (!g_first_launch) && (!g_prev_exit_normal);
}

+ (BOOL)firstLaunchEver {
    return g_first_launch;
}

+ (nullable NSDate *)lastNormalExitDate {
    return g_last_normal_exit_date;
}

+ (void)redirectStderrToRuntimeLog {
    @try {
        NSString *dir = [self crashLogsDirectory];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:nil];
        NSString *path = [self runtimeLogPath];

        // 把 stderr / stdout 重定向到沙盒 runtime 日志。即便随后被 SIGKILL，
        // 被杀前已经落盘的部分仍可作为排查线索（末尾可能丢失）。
        // 注意：freopen 必须在“延迟块”里执行，绝不能放在 constructor / +load 阶段，
        // 否则可能影响注入早期稳定性。
        FILE *fe = freopen([path UTF8String], "a+", stderr);
        (void)fe;
        FILE *fo = freopen([path UTF8String], "a+", stdout);
        (void)fo;

        // 立即落一行启动标记，便于区分每次运行
        struct timeval tv;
        gettimeofday(&tv, NULL);
        fprintf(stderr, "\n--- [DCL] runtime log attached @ %lld.%06lld ---\n",
                (long long)tv.tv_sec, (long long)tv.tv_usec);
        fflush(stderr);
    } @catch (id e) {
        (void)e;
    }
}

@end
