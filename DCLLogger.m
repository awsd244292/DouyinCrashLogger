//
//  DCLLogger.m
//  DouyinCrashLogger
//
//  实现见 DCLLogger.h。此处按「文件 IO → 行处理 → 管道泵」分段。
//

#import "DCLLogger.h"
#import "DCLConstants.h"
#import "DCLSupport.h"

#import <errno.h>
#import <fcntl.h>
#import <pthread.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#pragma mark - 闸门常量

/// 单会话 runtime 日志上限：超过就丢头部、留尾部
static const NSUInteger DCLRuntimeLogMaxBytes = 512 * 1024;
/// 触顶后保留的尾部大小
static const NSUInteger DCLRuntimeLogKeepBytes = 160 * 1024;
/// 单行上限：宿主吐出一个不换行的巨行时，按此长度切段，防止累积缓冲区失控
static const NSUInteger DCLRuntimeLogMaxLineBytes = 4096;
/// 崩溃日志保留时长：超过即删（无论份数）
static const NSTimeInterval DCLCrashLogMaxAgeSeconds = 7 * 24 * 60 * 60;
/// 崩溃日志目录总量闸门：超过就继续删最旧的，直到落到上限以下
static const unsigned long long DCLCrashLogsTotalCapBytes = 8ULL * 1024 * 1024;

#pragma mark - 降频常量（用真机日志标定，不是拍脑袋）

/// 同一「形态」的行（数字与十六进制地址归一化后相同）前 N 次全量保留。
/// N=3 的依据：排查时至少要看到「它开始出现」和「它不是偶发」两件事。
static const NSUInteger DCLRepeatShapeFullPass = 3;

/// 超过全量次数之后，每 N 行抽 1 行写盘。
/// 为什么要抽样而不是一刀切掉：宿主那种「renderer 每帧建一次(filter node)」的行，
/// 一旦完全不写，事后就说不清它到底停在哪一帧、有没有停 —— 抽样保留了「还在持续」这个事实。
static const NSUInteger DCLRepeatShapeSampleEvery = 10;

/// 形态表容量上限，到顶整表清零重开。
/// 字典是会长大的，而宿主能吐出的形态种类没有上限，不封顶就是慢性内存泄漏。
static const NSUInteger DCLThrottleTableMaxKeys = 512;

/// 形态计数窗口（秒）。到点清零计数。
/// 不做窗口的话，三小时前刷过一轮的行会被永久降权，之后它哪怕只在崩溃前才出现一次也漏写。
static const NSTimeInterval DCLThrottleWindowSeconds = 300.0;

#pragma mark - 内部状态

/// 所有写盘 / 截断都在这条串行队列里完成，天然互斥，不必再上锁。
static dispatch_queue_t dcl_log_queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.dcl.logger", DISPATCH_QUEUE_SERIAL);
        // 后台优先级：日志绝不能跟抢主线程的活抢资源
        dispatch_set_target_queue(q, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    });
    return q;
}

static off_t g_current_bytes = 0;      // 当前会话文件已写字节（仅队列内访问）
static NSString *g_last_line = nil;    // 上一次真正写出去的行（用于折叠重复）
static NSUInteger g_last_repeat = 0;   // 该行已连续出现的次数（含首次）
static NSUInteger g_noise_dropped = 0; // 被判为系统刷屏而丢弃的行数

/// 常驻写句柄。旧实现每行都是 open/write/close 三连 syscall，
/// 而这几万次 open/close 换来的东西跟用一个长命 fd 完全一样。
static int g_write_fd = -1;

/// 形态 -> 已出现次数。只统计「已决定不限制写入的那些配額」，别无他用。
static NSMutableDictionary<NSString *, NSNumber *> *g_shape_counts = nil;
static NSTimeInterval g_window_start = 0;      // 当前计数窗口起点（0 = 还没开表）
static NSUInteger g_window_throttled = 0;      // 本窗口被抽样掉的行数

// 这三条只用于健康自检展示，会被别的线程读；允许拿到略旧的值，故只加 volatile。
static volatile NSUInteger g_written_lines = 0;   // 本会话真正落盘的行数
static volatile NSUInteger g_throttled_lines = 0; // 被形态抽样压掉的行数

static int g_pipe_read = -1;
static int g_pipe_write = -1;   // 刻意长期持有：写端不关，管道就永远不会被 EOF
static int g_saved_err = -1;
static int g_saved_out = -1;
static int32_t g_capture_ok = 0;

// —— 总开关 off 相关的两个闸门 ——
// g_logging_enabled：off 后所有 append 一律丢弃（连泵收尾补的半行残留也不写）。
// g_pump_stop：让泵线程在下一轮循环体里自行退出，不靠外部硬杀线程。
static volatile int32_t g_logging_enabled = 1;
static volatile int32_t g_pump_stop = 0;

// 接管 / 归还都动 fd，且 off → on 切换时要能重新接管（故不能是 dispatch_once），
// 用一把互斥锁守住，避免「重装与停泵」撞在一起时 fd 被覆盖成半新半旧。
static pthread_mutex_t g_capture_lock = PTHREAD_MUTEX_INITIALIZER;

#pragma mark - 文件 IO（只在队列内调用）

static NSString *dcl_runtime_path(void) { return [DCLLogger runtimeLogPath]; }

/// 常驻写句柄：开着就不用每行 open 一次。拉不起来（目录被删）就老实返回 NO，让调用方放弃这一行。
static BOOL dcl_ensure_write_fd_locked(void) {
    if (g_write_fd >= 0) return YES;
    int fd = open([dcl_runtime_path() fileSystemRepresentation],
                  O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return NO;
    g_write_fd = fd;
    return YES;
}

static void dcl_close_write_fd_locked(void) {
    if (g_write_fd >= 0) { close(g_write_fd); g_write_fd = -1; }
}

/// 保留文件尾部 keep 字节、丢掉头部。有界内存：一次最多吃 keep 字节（见调用处的常量）。
/// 这不是「优雅瘦身」，是保命 —— 宿主一次崩溃前可能刷出几 MB，
/// 不设上限的话纯粹是替它把磁盘写满。
static void dcl_trim_file_to_tail_locked(NSString *path, NSUInteger keep, const char *marker,
                                         off_t * _Nullable outNewSize) {
    if (!path || keep == 0) return;
    const char *p = [path fileSystemRepresentation];
    int rfd = open(p, O_RDONLY);
    if (rfd < 0) return;

    struct stat st;
    if (fstat(rfd, &st) != 0 || st.st_size <= (off_t)keep) { close(rfd); return; }

    off_t skip = st.st_size - (off_t)keep;
    if (lseek(rfd, skip, SEEK_SET) < 0) { close(rfd); return; }

    NSMutableData *tail = [NSMutableData dataWithLength:keep];
    uint8_t *buf = (uint8_t *)tail.mutableBytes;
    off_t got = 0;
    while (got < (off_t)keep) {
        ssize_t n = read(rfd, buf + got, (size_t)((off_t)keep - got));
        if (n > 0) { got += n; continue; }
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    close(rfd);
    if (got <= 0) return;

    int wfd = open(p, O_WRONLY | O_TRUNC);
    if (wfd < 0) return;
    ssize_t w1 = 0, w2 = 0;
    if (marker) w1 = write(wfd, marker, strlen(marker));
    w2 = write(wfd, buf, (size_t)got);
    close(wfd);
    // 无论写成功多少，文件的真实大小就以「实际写进去的字节」为准 ——
    // 误差会导致闸门提前或延后触发，宁可按实测值算。
    off_t newSize = (w1 > 0 ? (off_t)w1 : 0) + (w2 > 0 ? (off_t)w2 : 0);
    if (outNewSize) *outNewSize = newSize;
}

/// 真正落盘一行。返回是否成功写出。
static BOOL dcl_write_raw_locked(const char *bytes, NSUInteger len) {
    if (!bytes || len == 0) return NO;
    if (!dcl_ensure_write_fd_locked()) return NO;

    ssize_t w = write(g_write_fd, bytes, (size_t)len);
    if (w < 0) {
        // 最常见的原因是日志目录被人在外面清掉了：老 fd 还指着那个已被 unlink 的 inode，
        // 写得进去但永远看不见。重开一次拿新 inode，再失败就认输，绝不在这里重试打转。
        dcl_close_write_fd_locked();
        if (!dcl_ensure_write_fd_locked()) return NO;
        w = write(g_write_fd, bytes, (size_t)len);
    }
    if (w <= 0) return NO;

    g_written_lines++;
    g_current_bytes += w;
    if (g_current_bytes > (off_t)DCLRuntimeLogMaxBytes) {
        off_t newSize = 0;
        dcl_trim_file_to_tail_locked(dcl_runtime_path(), DCLRuntimeLogKeepBytes,
                                     "\n----- [DCL] size cap reached: dropped oldest lines -----\n",
                                     &newSize);
        g_current_bytes = newSize;
        // 裁剪时 g_written_lines 刻意不回退：它统计的是「写出去过多少行」，
        // 被闸门删掉是另一件事，两笔账不能混。
    }
    return YES;
}

/// 写我们自己的批注（限流摘要、重复计数等）。
/// 关键是写完要把折叠链断开 —— 否则下一行会拿批注前的那行做重复比对，数量就串了。
static void dcl_write_note_locked(NSString *note) {
    if (note.length == 0) return;
    NSString *out = [note stringByAppendingString:@"\n"];
    NSUInteger byteLen = [out lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    dcl_write_raw_locked([out UTF8String], byteLen);
    g_last_line = nil;
    g_last_repeat = 0;
}

#pragma mark - 行处理（只在队列内调用）

/// 宿主吐出来的、与我们毫无关系的系统级刷屏。
/// 真机上实测：objc runtime 对宿主 category 属性的抱怨一启动就能吐几千行，
/// 它们既不影响排查，也把有价值的行挤到了视线之外。
static BOOL dcl_is_known_system_noise(NSString *line) {
    static NSArray<NSString *> *patterns;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        patterns = @[
            @"Unrecognized attribute string flag",
        ];
    });
    for (NSString *pat in patterns) {
        if ([line rangeOfString:pat options:NSCaseInsensitiveSearch].length) return YES;
    }
    return NO;
}

/// 疑似崩溃 / 取证相关的行：一律不降级。
/// 宁可多留几十行，也绝不能让命案现场的证词被当成重复噪音扔掉 —— 这是降频唯一的红线。
static BOOL dcl_is_forensic_line(NSString *line) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[
            @"EXC_", @"SIGABRT", @"SIGSEGV", @"SIGBUS", @"SIGILL", @"SIGTRAP", @"signal",
            @"NSException", @"uncaught exception", @"assert", @"fatal",
            @"abort", @"backtrace", @"stack trace", @"panic",
            @"error:", @"fail",
        ];
    });
    for (NSString *k in keys) {
        if ([line rangeOfString:k options:NSCaseInsensitiveSearch].length) return YES;
    }
    return NO;
}

/// 行的「形态」key：连续数字归一成 #，十六进制地址归一成 0x#，并截断到定长。
/// 存在的目的只有一个 —— 让「同一处代码吐出的同一句话」在不同参数下落进同一个计数桶。
/// 真机实测：12 分钟里有 2177 行宿主日志，形态却只有 607 种，重复率 72%。
static NSString *dcl_shape_key(NSString *line) {
    const char *utf8 = [line UTF8String];
    if (!utf8 || !*utf8) return nil;

    const size_t cap = 120;
    char buf[cap + 1];
    size_t o = 0;
    BOOL inNum = NO;

    for (size_t i = 0; utf8[i] != '\0' && o < cap; ) {
        unsigned char c = (unsigned char)utf8[i];
        if (c >= '0' && c <= '9') {
            if (!inNum) { buf[o++] = '#'; inNum = YES; }
            i++;
            continue;
        }
        inNum = NO;

        if (c == '0' && (utf8[i + 1] == 'x' || utf8[i + 1] == 'X')) {
            size_t j = i + 2;
            BOOL anyHex = NO;
            while (utf8[j]) {
                unsigned char h = (unsigned char)utf8[j];
                BOOL isHex = (h >= '0' && h <= '9') ||
                             (h >= 'a' && h <= 'f') ||
                             (h >= 'A' && h <= 'F');
                if (!isHex) break;
                anyHex = YES; j++;
            }
            if (anyHex) {
                if (o + 3 <= cap) { buf[o++] = '0'; buf[o++] = 'x'; buf[o++] = '#'; }
                i = j;
                continue;
            }
        }

        buf[o++] = (char)c;
        i++;
    }
    buf[o] = '\0';
    if (o == 0) return nil;
    return [NSString stringWithUTF8String:buf];
}

/// 窗口到点：结掉本轮统计。
/// 写摘要而不是给每行打标记 —— 给每个被限流的形态都打一行的话，
/// 光标记本身就能占掉几百行，等于把省下来的份额又吐回去。
static void dcl_roll_throttle_window_locked(NSTimeInterval now) {
    if (g_window_start <= 0) { g_window_start = now; return; }
    NSTimeInterval span = now - g_window_start;
    if (span < DCLThrottleWindowSeconds) return;

    if (g_window_throttled > 0) {
        NSString *note = [NSString stringWithFormat:
                          @"[DCL] log throttle: %lu lines sampled out in the last %.0fs "
                          @"(repeated lines keep first %lu hits, then 1/%lu)",
                          (unsigned long)g_window_throttled, span,
                          (unsigned long)DCLRepeatShapeFullPass,
                          (unsigned long)DCLRepeatShapeSampleEvery];
        dcl_write_note_locked(note);
    }
    [g_shape_counts removeAllObjects];
    g_window_start = now;
    g_window_throttled = 0;
}

/// 这一行要不要被本轮抽样跳过。
static BOOL dcl_should_throttle_locked(NSString *line) {
    if ([line hasPrefix:@"[DCL]"]) return NO;          // 自己写的行一个字都不许动
    if (dcl_is_forensic_line(line)) return NO;         // 疑似崩溃证据，放行

    NSString *key = dcl_shape_key(line);
    if (key.length == 0) return NO;

    if (!g_shape_counts) {
        g_shape_counts = [NSMutableDictionary dictionaryWithCapacity:64];
    } else if (g_shape_counts.count >= DCLThrottleTableMaxKeys) {
        // 到顶就整表清零重开：字典必须是有界的，这是硬要求
        [g_shape_counts removeAllObjects];
    }

    NSUInteger n = [g_shape_counts[key] unsignedIntegerValue] + 1;
    g_shape_counts[key] = @(n);
    if (n <= DCLRepeatShapeFullPass) return NO;
    return ((n - DCLRepeatShapeFullPass) % DCLRepeatShapeSampleEvery) != 0;
}

/// now：进入队列时的秒级时间戳。一次批量只取一次时钟，避免每行一次 syscall。
static void dcl_handle_line_locked(NSString *line, NSTimeInterval now) {
    if (line.length == 0) return;

    dcl_roll_throttle_window_locked(now);

    if (dcl_is_known_system_noise(line)) { g_noise_dropped++; return; }

    if (dcl_should_throttle_locked(line)) {
        g_throttled_lines++;
        g_window_throttled++;
        return;   // 刻意不动 g_last_line：抽样不影响连续折叠的判断基准
    }

    // 连续重复行折叠：只写第一行，结束时补一句重复计数。
    // 注意保留「重复发生」这个事实，而不是静默删掉 —— 排查时「同一行吐了 3000 次」
    // 本身就是一条重要线索。
    if (g_last_line && [line isEqualToString:g_last_line]) {
        g_last_repeat++;
        return;
    }
    if (g_last_repeat > 1) {
        dcl_write_note_locked([NSString stringWithFormat:
                               @"  ... [DCL] previous line repeated %lu more times",
                               (unsigned long)(g_last_repeat - 1)]);
    }

    NSString *out = [line stringByAppendingString:@"\n"];
    NSUInteger byteLen = [out lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (byteLen > 0 && dcl_write_raw_locked([out UTF8String], byteLen)) {
        g_last_line = [line copy];
        g_last_repeat = 1;
    }
}

#pragma mark - 管道泵（stdlib 线程，不依赖 GCD）

static void dcl_restore_original_streams(void) {
    // 泵退出时必须把宿主的输出通道还回去。丢了他 stderr 等于永久致盲，不可逆。
    if (g_saved_err >= 0) { dup2(g_saved_err, STDERR_FILENO); close(g_saved_err); g_saved_err = -1; }
    if (g_saved_out >= 0) { dup2(g_saved_out, STDOUT_FILENO); close(g_saved_out); g_saved_out = -1; }
}

/// 把「stage 里攒的半行」+「本次刚读到的一段」拼成一行。stage 为空时直接用读缓冲，不拷贝。
static NSString * _Nullable dcl_line_from_parts(NSMutableData *stage, const char *bytes, size_t len) {
    NSUInteger staged = [stage length];
    NSUInteger l = staged;
    const void *raw = NULL;

    if (staged == 0) {
        l = len;
        raw = bytes;
    } else {
        if (len) [stage appendBytes:bytes length:len];
        l = [stage length];
        raw = [stage bytes];
    }
    // 先剥掉 Windows 式行尾的 \r：留下的话它会被 ASCII 净化换成换行，
    // 于是一行日志变成两行，重复折叠也会被它搅乱。
    if (l && ((const unsigned char *)raw)[l - 1] == '\r') l -= 1;
    if (l == 0) return nil;

    NSString *s = [[NSString alloc] initWithBytes:raw length:l encoding:NSUTF8StringEncoding];
    return s ?: [[NSString alloc] initWithBytes:raw length:l encoding:NSISOLatin1StringEncoding];
}

/// 一段数据切成若干行塞进 outLines。跨 read 的半行由 stage 承接。
///
/// 旧实现是逐字节 appendData：真机 12 分钟吐了 316 KB，那就是 31 万次 ObjC 消息
/// 外加同样多次的容量检查 —— 干的活跟 memchr 找换行一模一样，成本却高了三个数量级。
static void dcl_pump_feed(NSMutableData *stage, const char *bytes, size_t len,
                          NSMutableArray<NSString *> *outLines) {
    size_t i = 0;
    while (i < len) {
        const char *nl = (const char *)memchr(bytes + i, '\n', len - i);
        if (!nl) break;    // 剩下的是半行，交给 stage 兜到下一次 read

        size_t segLen = (size_t)(nl - (bytes + i));
        NSString *s = dcl_line_from_parts(stage, bytes + i, segLen);
        if (s) [outLines addObject:s];
        [stage setLength:0];
        i += segLen + 1;   // 跳过换行符本身
    }

    if (i < len) {
        // 超长无换行保护：stage 已顶到上限就先把旧的这截吐出去，再收新的，
        // 绝不让单行把内存吃掉。
        if ([stage length] >= DCLRuntimeLogMaxLineBytes) {
            NSString *s = dcl_line_from_parts(stage, "", 0);
            if (s) [outLines addObject:s];
            [outLines addObject:@"[DCL] previous line was truncated (no newline)"];
            [stage setLength:0];
        }
        [stage appendBytes:(bytes + i) length:(len - i)];
    }
}

static void *dcl_log_pump(void *ctx) {
    // 读端 fd 由创建时随参带进来，而不是循环里去读全局 g_pipe_read。
    // 原因很实在：off → on 切换会重新 pipe，全局值会被换成新 fd；若泵读的是全局，
    // 上一轮还没退干净的老泵就会去读新管道，两边的日志互相抢字节。
    int fd = (int)(intptr_t)ctx;
    pthread_setname_np("com.dcl.log-pump");

    char chunk[4096];
    NSMutableData *stage = [NSMutableData dataWithCapacity:DCLRuntimeLogMaxLineBytes * 2];
    NSMutableArray<NSString *> *batch = [NSMutableArray arrayWithCapacity:32];

    while (1) {
        @autoreleasepool {
            if (g_pump_stop) break;   // 总开关已归零，收工
            ssize_t n = read(fd, chunk, sizeof(chunk));
            if (n > 0) {
                dcl_pump_feed(stage, chunk, (size_t)n, batch);
                if (batch.count) {
                    // 一次 read 切出来的所有行只投递一次到账：
                    // 省掉「每行一次 block 分配 + 一次队列入队」这笔最冤的成本。
                    [DCLLogger appendRuntimeLines:batch];
                    [batch removeAllObjects];
                }
            } else if (n == 0) {
                break;   // 写端全关（异常场景），恢复宿主原流后退出
            } else if (errno == EINTR) {
                // 被打断，重试即可
            } else {
                break;
            }
        }
    }

    @autoreleasepool {
        if ([stage length]) {
            NSString *s = [[NSString alloc] initWithBytes:[stage bytes] length:[stage length]
                                                 encoding:NSUTF8StringEncoding];
            // off 之后这一行会被 setLoggingEnabled:NO 挡掉，不会漏进别人的文件里。
            [DCLLogger appendRuntimeLine:s ?: @"(undecodable tail)"];
        }
        dcl_restore_original_streams();
    }
    if (fd >= 0) close(fd);   // 自己的读端自己收，别去碰可能被换过的全局值
    return NULL;
}

@implementation DCLLogger

#pragma mark - 路径

+ (NSString *)logsDirectory {
    return [NSHomeDirectory() stringByAppendingPathComponent:DCLCrashLogsRelativeDir];
}

+ (NSString *)runtimeLogPath {
    return [[self logsDirectory] stringByAppendingPathComponent:DCLRuntimeLogFileName];
}

+ (NSString *)previousRuntimeLogPath {
    // plugin_runtime_prev.log：只留上一会话，再老的不追溯 —— 这正是反馈里
    // 「每次文件都很大」的解药：当前会话永远从干净的一页开始写。
    NSString *base = DCLRuntimeLogFileName;
    NSString *name = [[base stringByDeletingPathExtension] stringByAppendingString:@"_prev"];
    NSString *ext = [base pathExtension];
    NSString *full = ext.length ? [name stringByAppendingPathExtension:ext] : name;
    return [[self logsDirectory] stringByAppendingPathComponent:full];
}

#pragma mark - 生命周期

+ (void)rotateRuntimeLogAtLaunch {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [self logsDirectory];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *cur = [self runtimeLogPath];
        NSString *prev = [self previousRuntimeLogPath];
        if ([fm fileExistsAtPath:cur]) {
            [fm removeItemAtPath:prev error:nil];
            [fm moveItemAtPath:cur toPath:prev error:nil];
        }
        // 上一会话那份也压一下：它有可能在宿主刷屏的那一轮里就涨到了几 MB
        if ([fm fileExistsAtPath:prev]) {
            off_t ignored = 0;   // 这里刻意不回填 g_current_bytes：那是「当前会话」的计数
            dcl_trim_file_to_tail_locked(prev, DCLRuntimeLogKeepBytes, NULL, &ignored);
        }
        g_current_bytes = 0;   // 尚未有任何写入竞争：构造函数阶段还没有别的调用者

        // 会话换了，计数与常驻 fd 都得跟着换：旧 fd 指的还是那个已被 rename 成
        // _prev 的 inode，留着写就变成「本轮日志写进上一轮文件」。
        // 这里用 sync 是因为这些变量按约定只在队列内访问；rotate 由构造函数调用，
        // 彼时队列必然是空的，不会自锁。
        dispatch_sync(dcl_log_queue(), ^{
            dcl_close_write_fd_locked();
            [g_shape_counts removeAllObjects];
            g_window_start = 0;
            g_last_line = nil;
            g_last_repeat = 0;
            g_noise_dropped = 0;
            g_window_throttled = 0;
            g_written_lines = 0;
            g_throttled_lines = 0;
        });
    } @catch (id e) {
        (void)e;
    }
}

/// 真正接管的活儿（调用方已持 g_capture_lock）。拆成独立函数是为了让中途的失败
/// 能直接 return —— 锁内 return 会漏解锁，那是必现死锁。
static BOOL dcl_attach_capture_locked(void) {
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:[DCLLogger logsDirectory]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        int fds[2];
        if (pipe(fds) != 0) return NO;

        // 关键安全阀：写端非阻塞。泵线程万一出事，宿主的 fprintf 也只会拿到
        // EAGAIN 直接失败，绝不会出现「写日志把抖音 UI 线程卡住」这种反向事故。
        int fl = fcntl(fds[1], F_GETFL, 0);
        if (fl >= 0) fcntl(fds[1], F_SETFL, fl | O_NONBLOCK);

        int savedErr = dup(STDERR_FILENO);
        int savedOut = dup(STDOUT_FILENO);
        if (dup2(fds[1], STDERR_FILENO) < 0) {
            close(fds[0]); close(fds[1]); close(savedErr); close(savedOut);
            return NO;
        }
        if (dup2(fds[1], STDOUT_FILENO) < 0) {
            dup2(savedErr, STDERR_FILENO);
            close(fds[0]); close(fds[1]); close(savedErr); close(savedOut);
            return NO;
        }

        g_pipe_read = fds[0];
        g_pipe_write = fds[1];   // 保留，不关：管道不会被 EOF
        g_saved_err = savedErr;
        g_saved_out = savedOut;

        pthread_t th;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_attr_setstacksize(&attr, 512 * 1024);
        // 读端 fd 随参带进泵里（理由见 dcl_log_pump 开头），不让它回头读全局。
        BOOL ok = (pthread_create(&th, &attr, dcl_log_pump,
                                  (void *)(intptr_t)fds[0]) == 0);
        pthread_attr_destroy(&attr);

        if (ok) {
            __sync_fetch_and_or(&g_capture_ok, 1);
            return YES;
        }
        dcl_restore_original_streams();
        close(g_pipe_read); g_pipe_read = -1;
        close(g_pipe_write); g_pipe_write = -1;
        return NO;
    } @catch (id e) {
        (void)e;
        return NO;
    }
}

+ (void)installStderrCapture {
    pthread_mutex_lock(&g_capture_lock);
    if (g_pump_stop || g_capture_ok) {           // 已归零 / 已接管，都不再动
        pthread_mutex_unlock(&g_capture_lock);
        return;
    }
    dcl_attach_capture_locked();
    pthread_mutex_unlock(&g_capture_lock);
}

+ (void)stopStderrCapture {
    pthread_mutex_lock(&g_capture_lock);
    if (g_capture_ok) {
        // 先立停止标志，再动 fd：泵线程下一轮就会自己退出。
        g_pump_stop = 1;

        // 归还通道必须排在关写端之前 —— 收不回 stderr 是不可逆的致盲。
        dcl_restore_original_streams();

        // 关写端，让阻塞在 read 上的泵拿到 EOF（0），从而干净退出而不是被硬杀。
        if (g_pipe_write >= 0) { close(g_pipe_write); g_pipe_write = -1; }
        g_pipe_read = -1;                        // 读端由泵自己 close（见 dcl_log_pump 末尾）
        __sync_fetch_and_and(&g_capture_ok, 0);
    }
    pthread_mutex_unlock(&g_capture_lock);
}

+ (BOOL)stderrCaptureInstalled {
    return g_capture_ok != 0;
}

+ (void)setLoggingEnabled:(BOOL)enabled {
    g_logging_enabled = enabled ? 1 : 0;
}

+ (NSUInteger)runtimeLogMaxBytes {
    return DCLRuntimeLogMaxBytes;
}

#pragma mark - 降频统计（自检展示用）

+ (NSUInteger)writtenLineCount   { return g_written_lines; }
+ (NSUInteger)throttledLineCount { return g_throttled_lines; }
+ (NSUInteger)noiseDroppedCount  { return g_noise_dropped; }

#pragma mark - 写入

+ (void)appendRuntimeLine:(NSString *)line {
    if (!line) return;
    if (!g_logging_enabled) return;   // 总开关 off：一个字节都不再往里写
    NSString *captured = [line copy];
    dispatch_async(dcl_log_queue(), ^{
        @autoreleasepool {
            // ASCII 净化必须排在折叠之前：若先折叠，同一条中文行在不同字符集下
            // 会各占一份，折叠规则就失效了。
            NSString *ascii = DCLASCIISanitized(captured);
            dcl_handle_line_locked(ascii, (NSTimeInterval)DCLNowUs() / 1000000.0);
        }
    });
}

/// 批量版：一次 read 切出来的若干行只用一次 dispatch_async。
///
/// 这是整轮 IO 优化里最实在的一笔账。旧版每行都要一次 block 分配 + 一次队列入队，
/// 而这些行的处理逻辑本身（净化、限流判定、写盘）是同一个队列范围内的连续动作，
/// 完全没有必要为它们各自排一次队。
+ (void)appendRuntimeLines:(NSArray<NSString *> *)lines {
    if (lines.count == 0) return;
    if (!g_logging_enabled) return;
    NSArray<NSString *> *captured = [lines copy];
    dispatch_async(dcl_log_queue(), ^{
        @autoreleasepool {
            // 整批只取一次时钟：窗口判定只需要秒级精度，没必要每行一次 gettimeofday
            NSTimeInterval now = (NSTimeInterval)DCLNowUs() / 1000000.0;
            for (NSString *l in captured) {
                NSString *ascii = DCLASCIISanitized(l);
                dcl_handle_line_locked(ascii, now);
            }
        }
    });
}

#pragma mark - 清理

+ (void)cleanupLogs {
    @try {
        NSString *dir = [self logsDirectory];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            return;
        }

        NSDate *now = [NSDate date];
        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        unsigned long long total = 0;

        for (NSString *f in ([fm contentsOfDirectoryAtPath:dir error:nil] ?: @[])) {
            if (![f hasPrefix:@"crash_"]) continue;   // 只碰自己产出的崩溃日志，绝不误伤
            NSString *p = [dir stringByAppendingPathComponent:f];
            NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
            NSDate *mtime = a[NSFileModificationDate];
            unsigned long long size = [a fileSize];

            // 1) 超龄一律删：真机放一周没人看的日志，价值为零，只有占空间的价值
            if (mtime && [now timeIntervalSinceDate:mtime] > DCLCrashLogMaxAgeSeconds) {
                [fm removeItemAtPath:p error:nil];
                continue;
            }
            total += size;
            [items addObject:@{@"path": p,
                               @"date": mtime ?: [NSDate distantPast],
                               @"size": @(size)}];
        }

        // 倒序：索引 0 是最新的一份
        [items sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"date" ascending:NO]]];

        // 2) 份数闸门
        for (NSUInteger i = DCLMaxRetainedLogs; i < items.count; i++) {
            unsigned long long sz = [items[i][@"size"] unsignedLongLongValue];
            [fm removeItemAtPath:items[i][@"path"] error:nil];
            total = (total > sz) ? (total - sz) : 0;
        }

        // 3) 总量闸门：从最旧的一份往回删，直到落地于上限
        NSUInteger i = MIN(DCLMaxRetainedLogs, items.count);
        while (i > 0 && total > DCLCrashLogsTotalCapBytes) {
            i--;
            unsigned long long sz = [items[i][@"size"] unsignedLongLongValue];
            [fm removeItemAtPath:items[i][@"path"] error:nil];
            total = (total > sz) ? (total - sz) : 0;
        }
    } @catch (id e) {
        (void)e;
    }
}

@end
