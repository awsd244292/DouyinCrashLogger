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

static int g_pipe_read = -1;
static int g_pipe_write = -1;   // 刻意长期持有：写端不关，管道就永远不会被 EOF
static int g_saved_err = -1;
static int g_saved_out = -1;
static int32_t g_capture_ok = 0;

#pragma mark - 文件 IO（只在队列内调用）

static NSString *dcl_runtime_path(void) { return [DCLLogger runtimeLogPath]; }

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
    NSString *path = dcl_runtime_path();
    int fd = open([path fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return NO;
    ssize_t w = write(fd, bytes, (size_t)len);
    close(fd);
    if (w <= 0) return NO;
    g_current_bytes += w;
    if (g_current_bytes > (off_t)DCLRuntimeLogMaxBytes) {
        off_t newSize = 0;
        dcl_trim_file_to_tail_locked(path, DCLRuntimeLogKeepBytes,
                                     "\n----- [DCL] size cap reached: dropped oldest lines -----\n",
                                     &newSize);
        g_current_bytes = newSize;
    }
    return YES;
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

static void dcl_handle_line_locked(NSString *line) {
    if (line.length == 0) return;

    if (dcl_is_known_system_noise(line)) { g_noise_dropped++; return; }

    // 连续重复行折叠：只写第一行，结束时补一句重复计数。
    // 注意保留「重复发生」这个事实，而不是静默删掉 —— 排查时「同一行吐了 3000 次」
    // 本身就是一条重要线索。
    if (g_last_line && [line isEqualToString:g_last_line]) {
        g_last_repeat++;
        return;
    }
    if (g_last_repeat > 1) {
        NSString *note = [NSString stringWithFormat:
                          @"  ... [DCL] previous line repeated %lu more times\n",
                          (unsigned long)(g_last_repeat - 1)];
        dcl_write_raw_locked([note UTF8String], [note lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
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

/// 一段数据切成若干行交给管家。跨 read 的半行由 stage 承接。
static void dcl_pump_feed(NSMutableData *stage, const char *bytes, size_t len) {
    char nl = '\n';
    for (size_t i = 0; i < len; i++) {
        if (bytes[i] == nl) {
            NSUInteger l = [stage length];
            if (l) {
                // 先剥掉 Windows 式行尾的 \r：留下的话它会被 ASCII 净化换成换行，
                // 于是一行日志变成两行，重复折叠也会被它搅乱。
                unsigned char last = ((const unsigned char *)[stage bytes])[l - 1];
                if (last == '\r') l -= 1;
            }
            if (l) {
                NSString *s = [[NSString alloc] initWithBytes:[stage bytes] length:l
                                                     encoding:NSUTF8StringEncoding];
                if (!s) {
                    s = [[NSString alloc] initWithBytes:[stage bytes] length:l
                                                encoding:NSISOLatin1StringEncoding];
                }
                [DCLLogger appendRuntimeLine:s];
            }
            [stage setLength:0];
            continue;
        }
        if ([stage length] >= DCLRuntimeLogMaxLineBytes) {
            // 超长无换行：先吐一段并打标，绝不让单行把内存吃掉
            NSString *s = [[NSString alloc] initWithBytes:[stage bytes] length:[stage length]
                                                 encoding:NSUTF8StringEncoding]
                          ?: @"(undecodable)";
            [DCLLogger appendRuntimeLine:s];
            [DCLLogger appendRuntimeLine:@"[DCL] previous line was truncated (no newline)"];
            [stage setLength:0];
        }
        [stage appendBytes:(bytes + i) length:1];
    }
}

static void *dcl_log_pump(void *ctx) {
    (void)ctx;
    pthread_setname_np("com.dcl.log-pump");

    char chunk[4096];
    NSMutableData *stage = [NSMutableData dataWithCapacity:DCLRuntimeLogMaxLineBytes * 2];

    while (1) {
        @autoreleasepool {
            ssize_t n = read(g_pipe_read, chunk, sizeof(chunk));
            if (n > 0) {
                dcl_pump_feed(stage, chunk, (size_t)n);
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
            [DCLLogger appendRuntimeLine:s ?: @"(undecodable tail)"];
        }
        dcl_restore_original_streams();
    }
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
    } @catch (id e) {
        (void)e;
    }
}

+ (void)installStderrCapture {
    static dispatch_once_t onceInstall;
    dispatch_once(&onceInstall, ^{
        @try {
            [[NSFileManager defaultManager] createDirectoryAtPath:[self logsDirectory]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];

            int fds[2];
            if (pipe(fds) != 0) return;

            // 关键安全阀：写端非阻塞。泵线程万一出事，宿主的 fprintf 也只会拿到
            // EAGAIN 直接失败，绝不会出现「写日志把抖音 UI 线程卡住」这种反向事故。
            int fl = fcntl(fds[1], F_GETFL, 0);
            if (fl >= 0) fcntl(fds[1], F_SETFL, fl | O_NONBLOCK);

            int savedErr = dup(STDERR_FILENO);
            int savedOut = dup(STDOUT_FILENO);
            if (dup2(fds[1], STDERR_FILENO) < 0) {
                close(fds[0]); close(fds[1]); close(savedErr); close(savedOut);
                return;
            }
            if (dup2(fds[1], STDOUT_FILENO) < 0) {
                dup2(savedErr, STDERR_FILENO);
                close(fds[0]); close(fds[1]); close(savedErr); close(savedOut);
                return;
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
            BOOL ok = (pthread_create(&th, &attr, dcl_log_pump, NULL) == 0);
            pthread_attr_destroy(&attr);

            if (ok) {
                __sync_fetch_and_or(&g_capture_ok, 1);
            } else {
                dcl_restore_original_streams();
                close(g_pipe_read); g_pipe_read = -1;
                close(g_pipe_write); g_pipe_write = -1;
            }
        } @catch (id e) {
            (void)e;
        }
    });
}

+ (BOOL)stderrCaptureInstalled {
    return g_capture_ok != 0;
}

+ (NSUInteger)runtimeLogMaxBytes {
    return DCLRuntimeLogMaxBytes;
}

#pragma mark - 写入

+ (void)appendRuntimeLine:(NSString *)line {
    if (!line) return;
    NSString *captured = [line copy];
    dispatch_async(dcl_log_queue(), ^{
        @autoreleasepool {
            // ASCII 净化必须排在折叠之前：若先折叠，同一条中文行在不同字符集下
            // 会各占一份，折叠规则就失效了。
            NSString *ascii = DCLASCIISanitized(captured);
            dcl_handle_line_locked(ascii);
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
