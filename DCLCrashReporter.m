//
//  DCLCrashReporter.m
//  DouyinCrashLogger
//
//  崩溃捕获核心实现。
//

#import "DCLCrashReporter.h"
#import "DCLConfig.h"
#import "DCLConstants.h"
#import "DCLLogger.h"
#import "DCLSupport.h"
#import "DCLWatchdog.h"
#import "DCLPlaybackTracer.h"
#import "DCLTimeline.h"
#import "DCLSystemSignal.h"
#import "DCLTimelinePersist.h"
#import "DCLResourceProbe.h"
#import "DCLHealthCheck.h"

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

/// 内部方法（不对外暴露）
@interface DCLCrashReporter (DCLPrivate)
+ (void)appendLaunchVerdictToRuntimeLog;
+ (void)dcl_appDidEnterBackgroundState:(NSNotification *)note;
+ (void)dcl_appDidBecomeActiveState:(NSNotification *)note;
@end

// 前置声明：下面的类方法要返回这些 C 函数地址，而函数体定义在文件更下方
static void dcl_signal_handler(int sig, siginfo_t *info, void *uctx);
static void dcl_uncaught_exception_handler(NSException *exception);

static volatile sig_atomic_t g_handling = 0;
static int g_installed = 0;

// 宿主 / 其他插件原有的「未捕获异常」处理器（对应信号路径的 g_old_sa）。
// NSSetUncaughtExceptionHandler 会返回它，必须保存并在写完日志后转发，
// 否则宿主自己的异常上报链被我们一刀切断。
static NSUncaughtExceptionHandler *g_prev_uncaught = NULL;

// 宿主 / 其他插件原有的信号处理器。接管前逐个保存，写完自己的报告后链式转发 ——
// 直接覆盖会静默切断宿主自身的崩溃监控与收尾逻辑（上报、保存草稿等）。
static struct sigaction g_old_sa[NSIG];
static volatile int g_old_sa_valid[NSIG];

// 自上次启动以来，捕获处理器被顶替后成功夺回的次数（自愈记录，供健康自检展示）
static NSInteger g_uncaught_heal_count = 0;
static NSInteger g_signal_heal_count = 0;

// 备用信号栈：栈溢出类崩溃时，处理器不能在已经损坏的栈上运行，
// 否则必然二次崩溃 —— 而这类崩溃恰恰最需要留下日志。
// 注意 sigaltstack 是 per-thread 的，无法覆盖全部线程；至少保证主线程与看门狗线程。
#define DCL_SIGSTACK_SIZE (64 * 1024)
static char g_sigstack[DCL_SIGSTACK_SIZE];

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

// 退出性质判定所需的三个维度（详见 DCLPreviousExitKind 注释）
static BOOL g_prev_was_backgrounded = NO;   // 上一轮终止时 App 是否停留在后台
static NSTimeInterval g_prev_launch_time = 0;  // 上一轮的启动时间戳
static NSTimeInterval g_prev_enter_bg_time = 0; // 上一轮最后进入后台的时间戳
static BOOL g_prev_crashed = NO;            // 上一轮运行期间是否产出过崩溃文件
static DCLPreviousExitKind g_prev_exit_kind = DCLPreviousExitKindFirstLaunch;

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

// —— async-signal-safe 的数字格式化 ——
// snprintf 严格来说不在 POSIX 的 async-signal-safe 列表里（可能触碰 locale、
// 复杂格式下可能分配内存）。崩溃处理器是最不该赌「实践上安全」的地方，
// 因此这里手写两个只做查表取模的转换函数：无分配、无 locale、无锁。
static size_t dcl_u64_to_hex(uint64_t v, char *out, size_t cap) {
    char tmp[20];
    int n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v && n < (int)sizeof(tmp)) {
        uint32_t d = (uint32_t)(v & 0xF);
        tmp[n++] = (char)(d < 10 ? ('0' + d) : ('a' + (d - 10)));
        v >>= 4;
    }
    size_t o = 0;
    while (n > 0 && o + 1 < cap) out[o++] = tmp[--n];
    if (o < cap) out[o] = '\0';
    return o;
}

static size_t dcl_u64_to_dec(uint64_t v, char *out, size_t cap) {
    char tmp[24];
    int n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v && n < (int)sizeof(tmp)) {
        tmp[n++] = (char)('0' + (int)(v % 10));
        v /= 10;
    }
    size_t o = 0;
    while (n > 0 && o + 1 < cap) out[o++] = tmp[--n];
    if (o < cap) out[o] = '\0';
    return o;
}

/// 定宽十进制（左侧补零）。文件名里的微秒段必须补满 6 位：
/// 日志列表按文件名字符串排序，不补零会把同一秒内的多次崩溃排出错序。
static size_t dcl_u64_to_dec_pad(uint64_t v, char *out, size_t cap, unsigned width) {
    char tmp[24];
    int n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v && n < (int)sizeof(tmp)) {
        tmp[n++] = (char)('0' + (int)(v % 10));
        v /= 10;
    }
    while ((unsigned)n < width && n < (int)sizeof(tmp)) tmp[n++] = '0';
    size_t o = 0;
    while (n > 0 && o + 1 < cap) out[o++] = tmp[--n];
    if (o < cap) out[o] = '\0';
    return o;
}

/// 有符号十进制（signal code 可能为负，不能用无符号版本）
static size_t dcl_i64_to_dec(int64_t v, char *out, size_t cap) {
    size_t o = 0;
    if (v < 0) {
        if (o + 1 < cap) out[o++] = '-';
        // INT64_MIN 取负会溢出，先转无符号再按正数打印
        return o + dcl_u64_to_dec((uint64_t)(-(v + 1)) + 1, out + o, cap - o);
    }
    return dcl_u64_to_dec((uint64_t)v, out, cap);
}

/// 把 C 串追加到缓冲区，返回新的写入偏移（始终保证尾部有 '\0'）
static size_t dcl_append_str(char *buf, size_t off, size_t cap, const char *s) {
    if (!s) return off;
    while (*s && off + 1 < cap) buf[off++] = *s++;
    if (off < cap) buf[off] = '\0';
    return off;
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

    // 手工拼路径，避开 snprintf
    char path[2048];
    size_t o = 0;
    o = dcl_append_str(path, o, sizeof(path), g_logDir);
    o = dcl_append_str(path, o, sizeof(path), "/crash_");
    o += dcl_u64_to_dec((uint64_t)epoch, path + o, sizeof(path) - o);
    o = dcl_append_str(path, o, sizeof(path), "_");
    o += dcl_u64_to_dec_pad((uint64_t)usec, path + o, sizeof(path) - o, 6);
    o = dcl_append_str(path, o, sizeof(path), "_P");
    o += dcl_u64_to_dec((uint64_t)getpid(), path + o, sizeof(path) - o);
    o = dcl_append_str(path, o, sizeof(path), ".log");
    if (o == 0 || o >= sizeof(path) - 1) return -1;

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
        // 同样手工拼接：snprintf 严格来说不在 async-signal-safe 白名单
        // （%llx/%d 可能触碰 locale、复杂格式可能分配内存）
        size_t o = 0;
        o = dcl_append_str(line, o, sizeof(line), "#");
        o += dcl_u64_to_dec((uint64_t)i, line + o, sizeof(line) - o);
        o = dcl_append_str(line, o, sizeof(line), "  0x");
        o += dcl_u64_to_hex((uint64_t)(uintptr_t)frames[i], line + o, sizeof(line) - o);
        o = dcl_append_str(line, o, sizeof(line), "\n");
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

/// 链式转发给接管前的处理器（宿主 / 其他插件）。
/// SIG_DFL、SIG_IGN、空指针一律不转发 —— 前者交给下面的默认处置，
/// 后者意味着本来就没人在乎这个信号。
static void dcl_call_previous_handler(int sig, siginfo_t *info, void *uctx) {
    if (sig <= 0 || sig >= NSIG) return;
    if (!g_old_sa_valid[sig]) return;

    struct sigaction old = g_old_sa[sig];
    void *h = (old.sa_flags & SA_SIGINFO) ? (void *)old.sa_sigaction
                                          : (void *)old.sa_handler;
    if (!h || h == (void *)SIG_DFL || h == (void *)SIG_IGN) return;

    if (old.sa_flags & SA_SIGINFO) {
        ((void (*)(int, siginfo_t *, void *))h)(sig, info, uctx);
    } else {
        ((void (*)(int))h)(sig);
    }
}

/// 恢复默认处置并重新触发，确保进程一定终止（绝不回到出错指令）。
static void dcl_reraise_and_die(int sig, int code) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, NULL);
    raise(sig);          // 让内核按默认行为处置，系统得以生成标准 crash report
    _exit(code);         // 兜底：万一默认行为被改回忽略，也必须死在这里
}

static void dcl_signal_handler(int sig, siginfo_t *info, void *uctx) {
    // 重入保护。这里的分支绝不能只是 return ——
    // 那会把控制权交回刚刚出错的那条指令，同一信号被无限重触发，
    // 进程会以 100% CPU 挂死且不退出（比崩溃更难归因）。
    if (__sync_fetch_and_or(&g_handling, 1)) {
        dcl_reraise_and_die(sig, 138);
    }

    void *frames[64];
    int n = backtrace(frames, 64);

    // 时间线打点：让崩溃也落在同一条轴上，事后能看出「崩溃前 200ms 是不是刚卡过、
    // 是不是刚切后台」。detail 传静态常量（dcl_signal_name 返回的是字面量），
    // 内部只做 strncpy 到定长缓冲 —— 不触碰 locale、不做堆分配，
    // 因此这里刻意不用 snprintf（理由见下方注释）。
    DCLTimelineRecordC(DCLTlKindCrash, sig, dcl_signal_name(sig));

    // 抢救时间线：此时缓冲区里装着崩溃前最后几秒的全部事件（播放暂停、卡顿、
    // 触摸、前后台……）。不写出去，进程一死就全蒸发 —— 而这几秒恰恰是
    // 归因最值钱的部分。必须在上面那条 Crash 打点之后调，好让「崩溃」本身
    // 也进到这份现场里。
    // 该函数的实现只用 open/write/close，不得引入任何非 async-signal-safe 的东西。
    const char *tlPath = DCLTimelineCrashDumpPath();
    if (tlPath) DCLTimelineEmergencyDump(tlPath);

    // 信号处理器内不使用 snprintf：它不在 POSIX async-signal-safe 白名单里，
    // 格式化可能触碰 locale / 内部分配。一律手工拼接（无锁、无分配、无 locale）。
    char type[48];
    size_t t = 0;
    t = dcl_append_str(type, t, sizeof(type), dcl_signal_name(sig));
    t = dcl_append_str(type, t, sizeof(type), "(");
    t += dcl_u64_to_dec((uint64_t)sig, type + t, sizeof(type) - t);
    t = dcl_append_str(type, t, sizeof(type), ")");

    char detail[160];
    size_t d = 0;
    detail[0] = '\0';
    if (info) {
        d = dcl_append_str(detail, d, sizeof(detail), "fault address: 0x");
        d += dcl_u64_to_hex((uint64_t)(uintptr_t)info->si_addr, detail + d, sizeof(detail) - d);
        d = dcl_append_str(detail, d, sizeof(detail), ", signal code: ");
        d += dcl_i64_to_dec((int64_t)info->si_code, detail + d, sizeof(detail) - d);
    }

    dcl_write_report_c(type, detail, frames, n);

    // 先给原处理器一个机会（宿主的崩溃上报、收尾逻辑都挂在这里），
    // 再恢复默认并重新触发，让系统生成标准 crash report 作为补充。
    dcl_call_previous_handler(sig, info, uctx);
    dcl_reraise_and_die(sig, 130);
}

/// 实际接管的致命信号。刻意不含 SIGPIPE：
/// iOS App 普遍把它设为 SIG_IGN（CFNetwork 等依赖此行为）。一旦接管，
/// 任何一次 socket 写失败都会被我们升级成进程终止 —— 那是凭空制造崩溃，
/// 而且看起来还像是「抖音又闪退了」。
static const int dcl_monitored_signals[] = {
    SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGFPE
};

static void dcl_install_signals(void) {
    // 备用栈（当前线程）。栈溢出崩溃靠它才能留下日志。
    stack_t ss;
    ss.ss_sp = g_sigstack;
    ss.ss_size = sizeof(g_sigstack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = dcl_signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);

    for (size_t i = 0; i < sizeof(dcl_monitored_signals) / sizeof(dcl_monitored_signals[0]); i++) {
        int sig = dcl_monitored_signals[i];
        struct sigaction old;
        memset(&old, 0, sizeof(old));
        // 第三个参数非空 = 顺便取回原处理器，用于链式转发
        if (sigaction(sig, &sa, &old) == 0) {
            g_old_sa[sig] = old;
            g_old_sa_valid[sig] = 1;
        }
    }
}

#pragma mark - OC 未捕获异常

static void dcl_uncaught_exception_handler(NSException *exception) {
    // 重入分支显式 abort，不依赖「runtime 一定会替我们 abort」这一隐式契约：
    // 显式 abort 触发 SIGABRT → 上面信号处理器重入分支 → reraise_and_die，进程必定终止。
    if (__sync_fetch_and_or(&g_handling, 1)) {
        abort();
    }

    // @try/@catch 包裹：捕获模块自身异常，避免覆盖原始崩溃栈
    @try {
        @autoreleasepool {
            // 时间线打点（OC 异常路径无信号重入约束，可以格式化）
            char cbuf[96];
            snprintf(cbuf, sizeof(cbuf), "未捕获异常 %s",
                     exception.name ? exception.name.UTF8String : "(无名)");
            DCLTimelineRecordC(DCLTlKindCrash, 0, cbuf);

            // OC 异常最终也会转 SIGABRT 走信号路径，但那一步可能因为各种原因
            // （宿主顶掉了信号处理器、abort 被拦截）到不了。这里先自行抢救一次：
            // 同一份证据有两条独立写出的路径，比只有一条可靠。
            const char *tlPath = DCLTimelineCrashDumpPath();
            if (tlPath) DCLTimelineEmergencyDump(tlPath);

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

    // 链式转发给接管前的 handler。NSSetUncaughtExceptionHandler 的返回值就是它，
    // 之前被丢弃了 —— 那等于静默切断宿主（或先于我们注入的其他插件）自己的
    // 异常统计与收尾逻辑，与信号路径上已修过的 g_old_sa 是同一类错误。
    // 转发必须在写完日志之后：原 handler 可能会直接终止进程。
    NSUncaughtExceptionHandler *prev = g_prev_uncaught;
    if (prev) prev(exception);
}

#pragma mark - 捕获处理器自愈（防止被其他注入模块顶替）

/// 自愈核心：OC 未捕获异常处理器若已被其他模块顶替，夺回并保留链式转发。
/// 返回是否发生了夺回。仅比对函数地址，不触碰 Foundation 之外的状态。
///
/// 关键：被顶替者（宿主或其他注入模块）可能是真正的崩溃上报方，夺回时必须把它
/// 存为新的 g_prev_uncaught，否则等于反过来切断了对方的链路 —— 与 install / 信号
/// 路径上「链式转发」的设计是一脉相承的，不能因为自卫就变成新的破坏者。
static BOOL dcl_reassert_uncaught_exception_handler(void) {
    if (!g_installed) return NO;
    void *ours = (void *)(uintptr_t)dcl_uncaught_exception_handler;
    void *cur = (void *)(uintptr_t)NSGetUncaughtExceptionHandler();
    if (cur == ours) return NO;
    g_prev_uncaught = (NSUncaughtExceptionHandler *)cur;
    NSSetUncaughtExceptionHandler(&dcl_uncaught_exception_handler);
    g_uncaught_heal_count++;
    return YES;
}

/// 自愈核心：致命信号处理器若被顶替，逐信号夺回并保留链式转发。
/// 返回是否发生了任何夺回。被顶替者的 sigaction 会被保存为新的 g_old_sa[sig]，
/// 供 dcl_call_previous_handler 继续链式转发。
static BOOL dcl_reassert_signals(void) {
    if (!g_installed) return NO;
    void *ours = (void *)(uintptr_t)dcl_signal_handler;
    BOOL any = NO;
    for (size_t i = 0; i < sizeof(dcl_monitored_signals) / sizeof(dcl_monitored_signals[0]); i++) {
        int sig = dcl_monitored_signals[i];
        struct sigaction cur;
        memset(&cur, 0, sizeof(cur));
        if (sigaction(sig, NULL, &cur) != 0) continue;
        void *installed = (cur.sa_flags & SA_SIGINFO)
                        ? (void *)cur.sa_sigaction
                        : (void *)cur.sa_handler;
        if (installed == ours) continue;
        g_old_sa[sig] = cur;          // 保存被顶替者，供链式转发
        g_old_sa_valid[sig] = 1;
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = dcl_signal_handler;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&sa.sa_mask);
        sigaction(sig, &sa, NULL);
        any = YES;
    }
    if (any) g_signal_heal_count++;
    return any;
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
            @"Reporter: DouyinCrashLogger %@\n"
            @"CaptureMode: %@\n",
            machine, dev.systemVersion ?: @"??", appName, bundle, appVer,
            DCLPluginVersion, [DCLConfig profileName] ?: @"(unknown)"];
        strncpy(g_meta, [meta UTF8String] ?: "", sizeof(g_meta) - 1);
        g_meta[sizeof(g_meta) - 1] = '\0';
    }
}

#pragma mark - 公开接口

@implementation DCLCrashReporter

#pragma mark - 捕获链路自证（供健康自检核对）

/// 实际接管的信号清单。刻意不含 SIGPIPE —— 详见 DCLCrashReporter.m 内注释。
/// 自检只核对这里列出的信号，避免把「按设计未接管」误报成「被别人抢走」。
+ (NSArray<NSNumber *> *)monitoredSignals {
    static const int sigs[] = {SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGFPE};
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:sizeof(sigs) / sizeof(sigs[0])];
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        [a addObject:@(sigs[i])];
    }
    return a;
}

/// 自建线程（看门狗等）装上备用栈 —— sigaltstack 是 per-thread 的，
/// 不逐个装就只有主线程能从栈溢出崩溃中留下日志。
+ (void)installSignalStackOnCurrentThread {
    stack_t ss;
    ss.ss_sp = g_sigstack;
    ss.ss_size = sizeof(g_sigstack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);
}

/// 当前实际注册的信号处理器地址，用于核对捕获链路未被其他注入模块接管
+ (void *)currentSignalHandlerPointer {
    return (void *)(uintptr_t)dcl_signal_handler;
}

/// 当前注册的未捕获异常处理器地址
+ (void *)currentUncaughtExceptionHandlerPointer {
    return (void *)(uintptr_t)dcl_uncaught_exception_handler;
}

#pragma mark - 捕获处理器自愈

+ (BOOL)healUncaughtExceptionHandlerIfNeeded {
    BOOL healed = NO;
    @try { healed = dcl_reassert_uncaught_exception_handler(); } @catch (id e) { (void)e; }
    if (healed) {
        [DCLLogger appendRuntimeLine:
         @"[DCL] self-heal: OC uncaught-exception handler was hijacked, reclaimed"];
    }
    return healed;
}

+ (BOOL)healSignalHandlersIfNeeded {
    BOOL healed = NO;
    @try { healed = dcl_reassert_signals(); } @catch (id e) { (void)e; }
    if (healed) {
        [DCLLogger appendRuntimeLine:
         @"[DCL] self-heal: signal handler(s) were hijacked, reclaimed"];
    }
    return healed;
}

+ (NSInteger)uncaughtExceptionHealCount {
    return g_uncaught_heal_count;
}

+ (NSInteger)signalHealCount {
    return g_signal_heal_count;
}

/// 低频率周期巡检：自动夺回被顶替的捕获处理器。靠「最后写入者胜出」这个事实，
/// 即便某个共存模块也周期性地抢，我们只要在崩溃发生前的某次巡检里赢一次，
/// OC 异常 / 致命信号就能回到我们的捕获链路里。
+ (void)startHandlerSelfHealing {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_queue_create("com.dcl.selfheal", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        if (!timer) return;
        // 首保 5s 后启动，之后每 15s 巡检一次：足以抓住绝大多数「装完又被抢」，
        // 又低频到对宿主 RunLoop 无感知。
        uint64_t start    = (uint64_t)(5  * NSEC_PER_SEC);
        uint64_t interval = (uint64_t)(15 * NSEC_PER_SEC);
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)start),
                                  interval, (uint64_t)(5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            @try {
                [self healUncaughtExceptionHandlerIfNeeded];
                [self healSignalHandlersIfNeeded];
            } @catch (id e) { (void)e; }
        });
        dispatch_resume(timer);
    });
}

#pragma mark - 目录

+ (NSString *)crashLogsDirectory {
    return [NSHomeDirectory() stringByAppendingPathComponent:DCLCrashLogsRelativeDir];
}

+ (void)cleanupOldLogs {
    @autoreleasepool {
        // 清理的三道闸门（份数 / 超龄 / 目录总量）统一交给日志管家，此处不重复实现。
        NSString *dir = [self crashLogsDirectory];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        @try { [DCLLogger cleanupLogs]; } @catch (id e) { (void)e; }

        // 与崩溃路径生死攸关的一件事留在本地：同步 C 缓冲区供信号处理路径使用
        strncpy(g_logDir, [dir UTF8String] ?: "", sizeof(g_logDir) - 1);
        g_logDir[sizeof(g_logDir) - 1] = '\0';
    }
}

+ (void)install {
    if (g_installed) return;
    g_installed = 1;

    // 本方法从 dyld constructor 调用，此处抛出的异常无人接住，会直接终止进程。
    // 每一步都单独兜底：宁可少收集一项元信息，也不能让抖音起不来。
    @try { dcl_prepare_meta(); } @catch (id e) { (void)e; }

    // 确保目录存在并填充 g_logDir
    @try {
        NSString *dir = [self crashLogsDirectory];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        strncpy(g_logDir, [dir UTF8String] ?: "", sizeof(g_logDir) - 1);
        g_logDir[sizeof(g_logDir) - 1] = '\0';
    } @catch (id e) { (void)e; }

    @try { dcl_prepare_images(); }                                  @catch (id e) { (void)e; }
    @try { dcl_install_signals(); }                                 @catch (id e) { (void)e; }
    @try {
        // 注意顺序与 API 语义：NSSetUncaughtExceptionHandler 返回 void，
        // 它「不」返回原 handler —— 原 handler 要用 NSGetUncaughtExceptionHandler() 先取。
        // （曾在这里直接把 setter 的返回值当原 handler 存下来，那是错的，
        //   链式转发会跳到一个非法地址上。）
        g_prev_uncaught = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&dcl_uncaught_exception_handler);
    } @catch (id e) { (void)e; }
}

#pragma mark - 退出标记 / 运行时日志

+ (NSString *)runtimeLogPath {
    return [[self crashLogsDirectory] stringByAppendingPathComponent:DCLRuntimeLogFileName];
}

+ (void)recordExitMarkAndRegisterTerminateObserver {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

        // —— 1. 读取上一轮遗留的状态 ——
        id val = [ud objectForKey:DCLLastExitNormalKey];
        if (val == nil) {
            g_first_launch = YES;
            g_prev_exit_normal = NO;
        } else {
            g_first_launch = NO;
            g_prev_exit_normal = [val boolValue];
        }

        id bg = [ud objectForKey:DCLLastExitWasBackgroundedKey];
        g_prev_was_backgrounded = [bg respondsToSelector:@selector(boolValue)] ? [bg boolValue] : NO;

        id lt = [ud objectForKey:DCLLastLaunchTimeKey];
        g_prev_launch_time = [lt respondsToSelector:@selector(doubleValue)] ? [lt doubleValue] : 0;

        id bt = [ud objectForKey:DCLLastEnterBackgroundTimeKey];
        g_prev_enter_bg_time = [bt respondsToSelector:@selector(doubleValue)] ? [bt doubleValue] : 0;

        id t = [ud objectForKey:DCLLastNormalExitTimeKey];
        if ([t isKindOfClass:[NSNumber class]]) {
            g_last_normal_exit_date = [NSDate dateWithTimeIntervalSince1970:[t doubleValue]];
        }

        // —— 2. 上一轮运行期间是否产出过崩溃文件 ——
        // 崩溃事件的“发现”只能靠启动时扫目录：signal handler 处于 async-signal-safe
        // 约束下，绝不能触碰 NSUserDefaults / Foundation。
        // 判据：崩溃目录中存在 mtime >= 上一轮启动时间 的 crash_*.log。
        g_prev_crashed = NO;
        if (g_prev_launch_time > 0 && !g_first_launch) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *dir = [self crashLogsDirectory];
            for (NSString *f in ([fm contentsOfDirectoryAtPath:dir error:nil] ?: @[])) {
                if (![f hasPrefix:@"crash_"]) continue;
                NSString *p = [dir stringByAppendingPathComponent:f];
                NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
                NSDate *mtime = a[NSFileModificationDate];
                if (mtime && [mtime timeIntervalSince1970] >= g_prev_launch_time - 1.0) {
                    g_prev_crashed = YES;
                    break;
                }
            }
        }

        // —— 3. 综合判定上一轮的真实退出性质 ——
        if (g_first_launch) {
            g_prev_exit_kind = DCLPreviousExitKindFirstLaunch;
        } else if (g_prev_exit_normal) {
            g_prev_exit_kind = DCLPreviousExitKindNormal;
        } else if (g_prev_was_backgrounded) {
            // 终止时 App 停在后台：用户清后台 / 系统回收内存，二者都无通知、都无法区分，
            // 也都不属于故障。只有当后台期间确实崩了才算崩溃。
            g_prev_exit_kind = g_prev_crashed ? DCLPreviousExitKindBackgroundCrashed
                                              : DCLPreviousExitKindBackgroundKilled;
        } else {
            g_prev_exit_kind = g_prev_crashed ? DCLPreviousExitKindForegroundCrashed
                                              : DCLPreviousExitKindSuspicious;
        }

        // —— 4. 为新的一轮重置标记 ——
        // 关键：先把“尚未正常终止 / 当前在前台”写回。若随后进程被 SIGKILL / OOM / 崩溃，
        // 这两个标记就不会被改写，下一轮据此判定。
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        [ud setObject:@(NO) forKey:DCLLastExitNormalKey];
        [ud setObject:@(NO) forKey:DCLLastExitWasBackgroundedKey];
        [ud setObject:@(now) forKey:DCLLastLaunchTimeKey];
        [ud synchronize];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        // 观察者挂在类对象（元类，进程生命周期内常驻）上，无需额外持有 token。
        [nc addObserver:self
               selector:@selector(dcl_appWillTerminate:)
                   name:UIApplicationWillTerminateNotification
                 object:nil];
        // 后台/前台状态跟踪：这是把“用户主动划掉”和“真闪退”区分开的唯一可靠依据。
        // 进后台的回调里必须 synchronize —— App 随时可能在此之后被直接杀死。
        [nc addObserver:self
               selector:@selector(dcl_appDidEnterBackgroundState:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(dcl_appDidBecomeActiveState:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];

    } @catch (id e) {
        (void)e;
    }
}

/// 把上次退出性质的结论追加到 plugin_runtime.log（极简版无 UI，这是唯一的可见出口）。
///
/// 关键改动：这里一律走 DCLLogger + 英文。原因很朴素 —— runtime log 里一半内容是
/// 宿主吐出来的，编码混乱；再混进去 UTF-8 中文，第三方工具一打开就是满屏
/// 「ä¸­æ–‡」式的乱码。DCLLogger 会把任何非 ASCII 字节转成 \xNN，
/// 与其让它把所有中文都转义成一串不可读的东西，不如给出英文原文。
+ (void)appendLaunchVerdictToRuntimeLog {
    @try {
        [DCLLogger appendRuntimeLine:@"----- [DCL] launch -----"];
        [DCLLogger appendRuntimeLine:
         [NSString stringWithFormat:@"[DCL] previous exit: %@", [self previousExitDescriptionASCIILine]]];

        if (g_last_normal_exit_date) {
            [DCLLogger appendRuntimeLine:
             [NSString stringWithFormat:@"[DCL] last normal exit: %@",
              [g_last_normal_exit_date description]]];
        }
        if (!g_first_launch && g_prev_enter_bg_time > 0 && g_prev_was_backgrounded) {
            NSTimeInterval stay = ([[NSDate date] timeIntervalSince1970] - g_prev_enter_bg_time);
            [DCLLogger appendRuntimeLine:
             [NSString stringWithFormat:@"[DCL] process ended after ~%.0fs in background", stay]];
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

/// App 进入后台：这里写下的标记，决定了下一轮能否识别出「用户主动划掉」
+ (void)dcl_appDidEnterBackgroundState:(NSNotification *)note {
    @try {
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        [u setObject:@(YES) forKey:DCLLastExitWasBackgroundedKey];
        [u setObject:@([[NSDate date] timeIntervalSince1970]) forKey:DCLLastEnterBackgroundTimeKey];
        [u synchronize];
    } @catch (id e) {
        (void)e;
    }
}

/// App 回到前台：清掉后台标记，使「前台异常终止」才能被识别为真闪退
+ (void)dcl_appDidBecomeActiveState:(NSNotification *)note {
    @try {
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        [u setObject:@(NO) forKey:DCLLastExitWasBackgroundedKey];
        [u synchronize];
    } @catch (id e) {
        (void)e;
    }
}

+ (DCLPreviousExitKind)previousExitKind {
    return g_prev_exit_kind;
}

+ (NSString *)previousExitDescription {
    switch (g_prev_exit_kind) {
        case DCLPreviousExitKindFirstLaunch:
            return @"首次运行（无历史记录）";
        case DCLPreviousExitKindNormal:
            return @"正常退出";
        case DCLPreviousExitKindBackgroundKilled:
            return @"后台期间被终止（大概率用户主动清后台或系统回收，非闪退）";
        case DCLPreviousExitKindBackgroundCrashed:
            return @"后台期间崩溃（已生成崩溃日志）";
        case DCLPreviousExitKindForegroundCrashed:
            return @"前台崩溃（已生成崩溃日志）";
        case DCLPreviousExitKindSuspicious:
            return [self dcl_suspiciousExitDescription];
    }
    return @"(未知)";
}

/// 把「疑似闪退」这一档再往下钻一层。
///
/// 为什么值得钻：OOM / watchdog / 早期崩溃三者虽然都表现为「前台异常终止且无报告」，
/// 但处置方向完全不同 —— OOM 要查内存大户，watchdog 要查主线程，
/// 早期崩溃要查启动路径。以前把它们装进同一句话里，等于把用户推回原点。
///
/// 依据是上一次还活着的进程最后留下的水位（见 DCLResourceProbe）：
/// SIGKILL 抓不住，能指望的只有进程死前自己记的那一笔。
+ (NSString *)dcl_suspiciousExitDescription {
    NSDictionary *w = [DCLResourceProbe previousSessionWatermark];
    if (!w) {
        return @"疑似闪退（前台异常终止且无崩溃记录，无可用水位数据）";
    }

    double fpMB   = [w[@"lastFootprint"] doubleValue] / (1024.0 * 1024.0);
    double peakMB = [w[@"peakFootprint"] doubleValue] / (1024.0 * 1024.0);
    double avMB   = [w[@"lastAvailable"] doubleValue] / (1024.0 * 1024.0);
    double stall  = [w[@"lastStallMs"] doubleValue];

    // OOM 判据：死前进程占用很高，或系统可用内存已被压到很低。
    // 阈值取经验值：占用超 600MB 或可用低于 50MB，二者居其一即高度可疑 ——
    // 这不是精确科学（真值随机型而异），给的是「优先从内存查起」的方向。
    BOOL oomSuspect = (fpMB >= 600.0) || (avMB > 0 && avMB < 50.0);

    // watchdog 判据：死前主线程刚经历过长卡顿（>2s 已进入被盯上的区间）。
    BOOL watchdogSuspect = (stall >= 2000.0);

    NSString *tail = [NSString stringWithFormat:
                      @"（证据：终止前进程占用 %.0fMB / 峰值 %.0fMB，"
                      @"系统可用 %.0fMB，主线程最后一次卡顿 %.0fms）",
                      fpMB, peakMB, avMB, stall];

    if (oomSuspect && watchdogSuspect) {
        return [@"高度疑似被系统终止：内存压力与主线程长卡顿同时成立，"
                @"OOM 与 watchdog 均需在查" stringByAppendingString:tail];
    }
    if (oomSuspect) {
        return [@"疑似 OOM（内存被系统杀死）：优先查内存大户，"
                @"尤其视频缓存 / 直播页 / 特效" stringByAppendingString:tail];
    }
    if (watchdogSuspect) {
        return [@"疑似 watchdog（主线程长时间无响应后被杀）："
                @"优先查主线程阻塞源" stringByAppendingString:tail];
    }
    return [@"疑似闪退但无明显内存/卡顿线索：可能是极早期崩溃"
            @"（崩溃捕获尚未安装完成）或被其他模块终止" stringByAppendingString:tail];
}

/// 同上，但是英文版 —— 专供 plugin_runtime.log 使用。
/// 那份文件会被各种日志查看工具打开，编码不可控；英文是最稳的唯一选择。
/// 面向人读的结构化报告（latest.log）仍用 previousExitDescription 的中文版本。
+ (NSString *)previousExitDescriptionASCIILine {
    switch (g_prev_exit_kind) {
        case DCLPreviousExitKindFirstLaunch:
            return @"first launch (no history)";
        case DCLPreviousExitKindNormal:
            return @"normal exit";
        case DCLPreviousExitKindBackgroundKilled:
            return @"killed while in background (user swipe-up or system reclaim; not a crash)";
        case DCLPreviousExitKindBackgroundCrashed:
            return @"crashed while in background (report written)";
        case DCLPreviousExitKindForegroundCrashed:
            return @"crashed in foreground (report written)";
        case DCLPreviousExitKindSuspicious:
            return @"suspicious foreground termination, no report (OOM / watchdog / very early crash)";
    }
    return @"(unknown)";
}

+ (BOOL)lastExitWasAbnormal {
    // 语义收窄：只有「前台崩溃」或「前台异常终止且抓不到原因」才算异常。
    // 后台被终止（用户主动划掉 / 系统回收）一律不算 —— 这正是本次误判的来源。
    switch (g_prev_exit_kind) {
        case DCLPreviousExitKindForegroundCrashed:
        case DCLPreviousExitKindSuspicious:
            return YES;
        default:
            return NO;
    }
}

+ (BOOL)firstLaunchEver {
    return g_first_launch;
}

+ (nullable NSDate *)lastNormalExitDate {
    return g_last_normal_exit_date;
}

+ (void)redirectStderrToRuntimeLog {
    @try {
        // 不再 freopen 直写：改由日志管家接管 stderr/stdout（管道 + 后台泵），
        // 从而有机会在落盘前过滤系统刷屏、折叠重复行、净化非 ASCII，并守住大小闸门。
        // 三条安全约束见 DCLLogger.h —— 尤其是「写端 O_NONBLOCK」这条，
        // 它保证泵线程出事时也绝不会反过来把宿主卡住。
        [DCLLogger installStderrCapture];

        // 立即落一行启动标记，便于区分每次运行
        fprintf(stderr, "\n--- [DCL] runtime log attached ---\n");
        fflush(stderr);
    } @catch (id e) {
        (void)e;
    }
}

#pragma mark - 最新状态快照（latest.log）

/// 【方案标识】写在所有章节之前：先说清「这份日志是按哪一档方案抓的」，
/// 否则「无」这个结论到底意味着「确实没有」还是「这一档抓不到」就无从分辨。
+ (void)dcl_appendCaptureProfile:(NSMutableString *)s {
    [s appendString:@"\n--- 采集方案 ---\n"];
    @try {
        [s appendFormat:@"当前方案: %@\n", [DCLConfig profileDisplayName]];
        [s appendString:@"已开启能力:\n"];
        for (NSString *c in [DCLConfig enabledCapabilities]) {
            [s appendFormat:@"  ✓ %@\n", c];
        }
        [s appendString:@"未覆盖（切换方案后可获得）:\n"];
        for (NSString *c in [DCLConfig disabledCapabilities]) {
            [s appendFormat:@"  · %@\n", c];
        }
        [s appendFormat:@"切换方式: %@\n", [DCLConfig switchGuide]];
    } @catch (id e) {
        (void)e;
        [s appendString:@"(读取采集方案配置失败，已按 A 方案 safe 兜底运行)\n"];
    }
}

/// 【章节 1】播放暂停 + 界面卡死诊断 —— 按需求置于日志最前方
+ (void)dcl_appendPlaybackDiagnosis:(NSMutableString *)s {
    [s appendString:@"\n========== 【1】播放暂停与界面卡死诊断 ==========\n"];

    BOOL hooksOn = [DCLConfig hooksEnabled];
    NSArray<DCLPauseEvent *> *events = [DCLPlaybackTracer recentEvents];
    NSArray<DCLStallRecord *> *stalls = [DCLWatchdog recentStalls];

    // 先交代「钩子蹲在哪几层」，再谈抓没抓到 —— 取证的结论必须能被独立验证。
    // 只输出「未观测到暂停」，用户看到的永远是「插件没干活」；
    // 而真相常常是「钩子压根不在调用路径上」，两者处置方向完全相反。
    if (hooksOn) {
        NSArray<NSString *> *hooked = [DCLPlaybackTracer hookedPlayerClasses];
        NSArray<NSString *> *skipped = [DCLPlaybackTracer skippedPlayerClasses];
        [s appendFormat:@"播放钩子挂载层：共 %lu 个方法，落在 %@\n",
         (unsigned long)[DCLPlaybackTracer hookedCount],
         hooked.count ? [hooked componentsJoinedByString:@", "] : @"（尚未挂上任何类）"];
        if (skipped.count) {
            [s appendFormat:@"  未单独挂载的类：%@\n"
                            @"  （多为子类未自己实现这些方法 —— 消息走继承链时已由父类钩子覆盖，属预期）\n",
             [skipped componentsJoinedByString:@", "]];
        }
    }

    if (events.count == 0 && stalls.count == 0) {
        if (!hooksOn) {
            [s appendString:@"结论：无（本次会话未观测到主线程卡死；"
                            @"「视频为何暂停」这一类当前为 A 方案零 hook，未挂载播放探针，"
                            @"不具备取证条件 —— 需要请切换 B 方案 full）\n"];
            // 即便没有播放钩子，系统层信号与时间线仍然有效 —— 照样输出，
            // 否则用户会误以为「什么都没采到」。
            [self dcl_appendTimelineSection:s];
            return;
        }
        // full 档却一条都没抓到 —— 这里必须说清是「确实没发生」还是「蹲错了楼层」。
        // 以前只写一句「未观测到视频暂停」，用户看到的是「插件没干活」，
        // 而真相很可能是「钩子根本不在调用路径上」。这两种情况的处理方向完全不同，
        // 日志必须把它们分开写，不能混成一句。
        if ([DCLTimeline avPlayerSeen]) {
            [s appendFormat:@"结论：本次会话未观测到视频暂停。\n"
                            @"  但本会话确实创建过 %lu 个 AVPlayer 实例，说明系统播放器路径是通的、"
                            @"钩子也挂上了 —— 那么结论是「这段时间确实没有走 pause/play 调用」，"
                            @"若画面仍然停了，应优先怀疑：① 自研播放器（不走 AVPlayer 的那一路）；"
                            @"② 画面被主线程冻住而非主动暂停（见下方时间线的卡顿记录）。\n",
             (unsigned long)[DCLTimeline avPlayerSeenCount]];
        } else {
            [s appendString:@"结论：本次会话未观测到视频暂停，且全程未见任何 AVPlayer 实例被创建。\n"
                            @"  这强烈提示抖音主播放不走系统 AVPlayer（自研播放引擎）。"
                            @"挂在 AVPlayer 上的 pause/play 钩子命中不了属于**预期结果**，"
                            @"不是探针写漏了 —— 在那条路径上再加多少钩子都是零。\n"
                            @"  非越狱条件下拿不到自研引擎内部的 pause 因果，这是硬限制。"
                            @"可退而求其次：用下方系统层信号（音频中断/前后台/锁屏）与时间线做侧证。\n"];
        }
        [self dcl_appendTimelineSection:s];
        return;
    }

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss.SSS";

    [s appendFormat:@"结论：本次会话观测到 %lu 次暂停/恢复、%lu 次主线程卡死\n",
     (unsigned long)events.count, (unsigned long)stalls.count];

    for (DCLPauseEvent *e in events) {
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:e.unixTime];
        [s appendFormat:@"\n[暂停事件] %@  action=%@  rate %.2f→%.2f  %@\n",
         [df stringFromDate:d], e.action, e.rateBefore, e.rateAfter,
         e.onMainThread ? @"(主线程)" : @"(非主线程)"];
        // 命中类名是这一版最值钱的新信息：暂停究竟由哪一层发起，
        // 直接决定下一步是查抖音业务逻辑还是查某个注入模块。
        if (e.playerClass.length) {
            [s appendFormat:@"  命中类：%@\n", e.playerClass];
        }

        NSString *src = @"";
        switch (e.source) {
            case DCLPauseSourceUserAction:      src = @"用户手势"; break;
            case DCLPauseSourceHostAppLogic:    src = @"抖音自身业务逻辑"; break;
            case DCLPauseSourceBackgroundMove:  src = @"切后台/锁屏"; break;
            case DCLPauseSourceAudioInterrupt:  src = @"音频会话中断/路由变更"; break;
            case DCLPauseSourceBufferStall:     src = @"缓冲不足或播放失败"; break;
            case DCLPauseSourceThirdPartyHook:  src = @"第三方注入模块发起"; break;
            case DCLPauseSourceMainThreadStall: src = @"伴随主线程卡死（画面被冻结）"; break;
            case DCLPauseSourceUnknown:         src = @"未能自动归因"; break;
        }
        [s appendFormat:@"  暂停来源：%@\n", src];
        [s appendFormat:@"  依据：%@\n", e.evidence];
        if (e.msSinceLastTouch >= 0) {
            [s appendFormat:@"  距最近一次触摸：%.0f ms\n", e.msSinceLastTouch];
        } else {
            [s appendString:@"  距最近一次触摸：无触摸记录\n"];
        }
        if (e.msSinceLastStall >= 0) {
            [s appendFormat:@"  距最近一次主线程卡死：%.0f ms\n", e.msSinceLastStall];
        }
        [s appendString:@"  调用栈（已符号化）：\n"];
        for (NSString *line in e.stack) {
            [s appendFormat:@"    %@\n", line];
        }
    }

    for (DCLStallRecord *r in stalls) {
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:r.startedAtUnix];
        [s appendFormat:@"\n[主线程卡死] %@  持续 %.0f ms\n",
         [df stringFromDate:d], r.durationMs];
        if (r.msSinceLastTouch >= 0) {
            [s appendFormat:@"  距最近一次触摸：%.0f ms%@\n", r.msSinceLastTouch,
             (r.msSinceLastTouch <= 300.0) ? @"  ← 高度相关，指向触摸处理链" : @""];
        }
        if (r.suspectImage.length) {
            [s appendFormat:@"  嫌疑模块：%@\n", r.suspectImage];
        }
        [s appendFormat:@"  判定：%@\n", r.verdict];
        if (r.stack.count) {
            [s appendString:@"  主线程栈：\n"];
            for (NSString *line in r.stack) {
                [s appendFormat:@"    %@\n", line];
            }
        } else {
            [s appendString:@"  主线程栈：未采集（当前为 A 方案零 hook，不 suspend 主线程采样）\n"];
        }
    }

    [self dcl_appendTimelineSection:s];
}

/// 统一时间线小节 —— 两档方案都输出。
///
/// 存在的意义：把「暂停那一刻前后到底发生了什么」从人脑对表变成代码可查。
/// 各探针记各的时间戳时，想回答「暂停前 200ms 有没有音频中断 / 主线程是不是正卡着」
/// 得手工拿 unix 时间去比，精度还对不齐；现在它们共用同一个单调时钟，
/// 相对毫秒一列直接给出答案。
+ (void)dcl_appendTimelineSection:(NSMutableString *)s {
    [s appendString:@"\n---------- 统一时间线（所有事件共用同一单调时钟）----------\n"];
    [s appendFormat:@"累计事件 %llu 条，缓冲内保留最近 %lu 条（环形缓冲，满则覆盖最旧）\n",
     [DCLTimeline totalRecorded], (unsigned long)[DCLTimeline bufferedCount]];

    NSArray<NSString *> *lines = [DCLTimeline formattedLinesLimit:60];
    if (lines.count == 0) {
        [s appendString:@"（暂无事件）\n"];
    } else {
        for (NSString *l in lines) [s appendFormat:@"%@\n", l];
    }

    [s appendFormat:@"\n系统层观测：%@\n", [DCLSystemSignal signalSummary]];

    // 暂停钩子命中过的话，把它前 500ms 的窗口单独摘出来 ——
    // 这一段才是回答「为什么停」时真正要盯的地方。
    NSArray<NSString *> *ctx = [DCLTimeline contextLinesBefore:DCLTlKindPauseHook
                                                     windowMs:500.0
                                                        limit:12];
    if (ctx.count) {
        [s appendString:@"\n最近一次「暂停钩子」命中前 500ms 的上下文：\n"];
        for (NSString *l in ctx) [s appendFormat:@"%@\n", l];
    } else if ([DCLTimeline avPlayerSeen]) {
        [s appendString:@"\n（暂停钩子本会话未命中过，故无「暂停前上下文」可给）\n"];
    }

    // 上次崩溃抢救出来的现场。这一段信息密度最高：
    // 它记录的是进程死之前最后几秒 —— 而那几秒在崩溃报告里通常是一片空白。
    NSString *crashTl = [DCLTimelinePersist takeLastCrashTimeline];
    if (crashTl.length) {
        [s appendString:@"\n---------- 上次崩溃前的最后现场（崩溃瞬间抢出，非推测）----------\n"];
        [s appendFormat:@"%@\n", crashTl];
    }
}

/// 【章节 2】插件自身健康检查 —— 证明「插件在工作」这件事本身
+ (void)dcl_appendHealthCheck:(NSMutableString *)s {
    [s appendString:@"\n========== 【2】插件健康自检 ==========\n"];
    NSArray<DCLHealthItem *> *items = [DCLHealthCheck run];
    NSUInteger fails = 0, warns = 0;
    for (DCLHealthItem *i in items) {
        if (i.level == DCLHealthLevelFail) fails++;
        if (i.level == DCLHealthLevelWarn) warns++;
    }
    [s appendFormat:@"总体：%@（共 %lu 项，%lu 项异常，%lu 项警告）\n",
     fails ? @"存在失效项" : (warns ? @"可通过（有警告）" : @"全部通过"),
     (unsigned long)items.count, (unsigned long)fails, (unsigned long)warns];
    for (DCLHealthItem *i in items) {
        NSString *tag = @"[OK]  ";
        if (i.level == DCLHealthLevelWarn) tag = @"[WARN]";
        if (i.level == DCLHealthLevelFail) tag = @"[FAIL]";
        [s appendFormat:@"%@ %@\n       依据：%@\n", tag, i.name, i.evidence];
    }
    if (fails == 0) {
        [s appendString:@"说明：捕获链路与探针均在位，本日志中的「未观测到崩溃」是可信结论，"
                         @"而非「插件没跑起来」造成的假阴性。\n"];
    }
}

/// 【章节 3】全线程快照 —— 融合 PerfDebugPlugin「冻屏全线程快照」的抓取手段。
/// 仅在「检测到主线程卡死自动缓存」或「用户截屏手动抓取」时生成，
/// 其余触发器（进后台/回前台/启动）不主动 suspend 全线程，避免无谓干扰。
/// 截屏正是「触摸失灵、没法点击只能截屏取证」场景下的天然触发器。
+ (void)dcl_appendAllThreadsSnapshot:(NSMutableString *)s reason:(NSString *)reason {
    [s appendString:@"\n========== 【3】全线程快照（卡死/截屏时抓取，仿 PerfDebugPlugin 手段） ==========\n"];

    if (![DCLConfig deepEvidenceEnabled]) {
        [s appendString:@"无（当前为 A 方案零 hook：不枚举线程、不 suspend 任何线程。"
                        @"需要这份冻结快照时，把 capture_mode.txt 改为 full 并重启抖音）\n"];
        return;
    }

    NSString *snap = nil;
    if ([DCLWatchdog stallCount] > 0) {
        snap = [DCLWatchdog lastAllThreadsSnapshot];   // 卡死时自动缓存的冻结上下文
    }
    if (!snap && reason && [reason containsString:@"截图"]) {
        snap = [DCLWatchdog captureAllThreadsSnapshot]; // 用户截屏：手动深度抓取
    }

    if (snap && snap.length) {
        [s appendString:snap];
    } else {
        [s appendString:@"本次未检测到主线程卡死，全线程快照仅在「检测到卡死自动捕获」"
                         @"或「截屏手动抓取」时生成（避免对全部线程无谓 suspend）。\n"];
    }
}

+ (NSString *)latestLogPath {
    return [[self crashLogsDirectory] stringByAppendingPathComponent:DCLSnapshotLogFileName];
}

+ (void)registerSnapshotTriggers {
    @try {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        // 截图：用户主动触发，且不与抖音任何手势冲突
        [nc addObserver:self
               selector:@selector(dcl_userDidTakeScreenshot:)
                   name:UIApplicationUserDidTakeScreenshotNotification
                 object:nil];
        // 进入后台：切走 / 锁屏即自动落盘，便于随后导出容器取最新日志
        [nc addObserver:self
               selector:@selector(dcl_appDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
        // 回到前台：用户描述的场景是「一触摸就卡」，回前台时自检一次最有针对性。
        // 同时解除看门狗的后台暂停 —— 后台 RunLoop 停转属正常，不应计入卡死。
        [nc addObserver:self
               selector:@selector(dcl_appWillEnterForeground:)
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];
    } @catch (id e) {
        (void)e;
    }
}

+ (void)dcl_userDidTakeScreenshot:(NSNotification *)note {
    [self writeLatestLogWithReason:@"用户截图"];
}

+ (void)dcl_appDidEnterBackground:(NSNotification *)note {
    [DCLWatchdog pauseForBackground];
    [self writeLatestLogWithReason:@"App 进入后台"];
}

+ (void)dcl_appWillEnterForeground:(NSNotification *)note {
    @try {
        // 延迟 1.5s：刚回前台时主线程正在做恢复动画，此时测响应必然偏慢，会误报
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                [DCLWatchdog resumeFromForeground];
                [self writeLatestLogWithReason:@"App 回到前台（含健康自检）"];
            } @catch (id e) { (void)e; }
        });
    } @catch (id e) {
        (void)e;
    }
}

/// 落盘用的串行队列：让「写日志」这件重活离开主线程。
static dispatch_queue_t dcl_snapshot_queue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.dcl.snapshot", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

+ (void)writeLatestLogWithReason:(NSString *)reason {
    // 进后台这一路必须同步落盘：App 随时会在此之后被挂起甚至杀死，
    // 走异步很可能只写了一半就被冻结 —— 那这份日志等于没有。
    BOOL mustBeSync = ([reason rangeOfString:@"后台"].location != NSNotFound);
    if (mustBeSync || ![NSThread isMainThread]) {
        [self dcl_writeLatestLogSync:reason];
        return;
    }
    // 其余场景一律丢后台串行队列。两个收益：
    //   1) 全线程快照要短暂挂起其余线程，不该发生在主线程上；
    //   2) 健康自检里的「主线程响应实测」只有在非主线程跑才有意义 ——
    //      在主线程自测自己的响应永远是 0，那是自欺欺人的假绿灯。
    dispatch_async(dcl_snapshot_queue(), ^{
        @try { [self dcl_writeLatestLogSync:reason]; }
        @catch (id e) { (void)e; }
    });
}

+ (void)dcl_writeLatestLogSync:(NSString *)reason {
    @try {
        NSString *dir = [self crashLogsDirectory];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

        struct timeval tv;
        gettimeofday(&tv, NULL);

        NSMutableString *s = [NSMutableString string];
        [s appendString:@"========== DouyinCrashLogger 最新状态快照 ==========\n"];
        [s appendFormat:@"触发方式: %@\n", reason ?: @"(未知)"];
        [s appendFormat:@"生成时间(unix): %lld.%06lld\n", (long long)tv.tv_sec, (long long)tv.tv_usec];
        [s appendFormat:@"进程 pid: %d\n", (int)getpid()];

        // 方案标识排在最前：先说清这份日志的取证边界，
        // 再看诊断与健康自检结论，最后才是背景数据
        [self dcl_appendCaptureProfile:s];
        [self dcl_appendPlaybackDiagnosis:s];
        [self dcl_appendHealthCheck:s];
        [self dcl_appendAllThreadsSnapshot:s reason:reason];

        [s appendString:@"\n========== 【4】上次退出性质 ==========\n"];
        [s appendFormat:@"%@\n", [self previousExitDescription]];
        switch (g_prev_exit_kind) {
            case DCLPreviousExitKindBackgroundKilled:
                [s appendString:@"  说明：App 是被系统/用户在后台结束的，未观测到崩溃，不属于闪退。\n"];
                break;
            case DCLPreviousExitKindSuspicious:
                [s appendString:@"  说明：App 停在前台却异常结束，且未抓到崩溃 —— 值得关注。\n"];
                break;
            case DCLPreviousExitKindForegroundCrashed:
            case DCLPreviousExitKindBackgroundCrashed:
                [s appendString:@"  说明：见下方「已落盘崩溃日志」，可直接取该文件分析。\n"];
                break;
            default:
                break;
        }
        if (g_last_normal_exit_date) {
            [s appendFormat:@"上次正常退出时间: %@\n", g_last_normal_exit_date];
        }
        if (!g_first_launch && g_prev_was_backgrounded && g_prev_enter_bg_time > 0) {
            [s appendFormat:@"后台停留时长: 约 %.0f 秒\n", tv.tv_sec - g_prev_enter_bg_time];
        }

        [s appendString:@"\n--- 环境信息 ---\n"];
        NSString *meta = [NSString stringWithUTF8String:g_meta];
        if (meta.length) [s appendFormat:@"%@\n", meta];

        void *frames[32];
        int n = backtrace(frames, 32);
        [s appendString:@"\n--- 触发时调用栈（原始地址，供 atos 符号化） ---\n"];
        for (int i = 0; i < n; i++) {
            [s appendFormat:@"#%-3d 0x%llx\n", i, (unsigned long long)(uintptr_t)frames[i]];
        }

        [s appendString:@"\n--- 已落盘崩溃日志 ---\n"];
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        NSMutableArray *crashFiles = [NSMutableArray array];
        for (NSString *f in files) {
            if ([f hasPrefix:@"crash_"]) [crashFiles addObject:f];
        }
        [crashFiles sortUsingSelector:@selector(compare:)];
        if (crashFiles.count == 0) {
            [s appendString:@"(暂无崩溃日志)\n"];
        } else {
            for (NSString *f in crashFiles) {
                NSString *p = [dir stringByAppendingPathComponent:f];
                NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
                [s appendFormat:@"%@  (%llu bytes, %@)\n", f,
                 [a[NSFileSize] unsignedLongLongValue], a[NSFileModificationDate] ?: @"(未知时间)"];
            }
        }

        [s appendString:@"\n--- 运行时日志 ---\n"];
        NSDictionary *ra = [fm attributesOfItemAtPath:[self runtimeLogPath] error:nil];
        if (ra) {
            [s appendFormat:@"plugin_runtime.log  存在  (%llu bytes)\n",
             [ra[NSFileSize] unsignedLongLongValue]];
        } else {
            [s appendString:@"plugin_runtime.log  不存在（可能尚未到重定向时机）\n"];
        }

        [s appendString:@"\n--- 已加载镜像基址表 ---\n"];
        NSString *imgs = [NSString stringWithUTF8String:g_image_table];
        if (imgs.length) [s appendFormat:@"%@\n", imgs];

        [s appendString:@"===================================================\n"];

        [s writeToFile:[self latestLogPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {
        (void)e;
    }
}

@end
