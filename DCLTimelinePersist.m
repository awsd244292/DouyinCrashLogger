//
//  DCLTimelinePersist.m
//  DouyinCrashLogger
//
//  实现要点见 DCLTimelinePersist.h。
//  这里只补充落地时几条不容商量的约束：
//
//  1) 崩溃路径与常规路径**代码各写各的**。不要试图用一个通用函数兼顾两边 ——
//     一边要 Foundation 的便利，一边连 malloc 都不能碰，硬凑的结果是让安全的那条
//     也被拖进不安全的实现里。重复一点点代码，换来「崩溃时能救回来」的确定性，值。
//
//  2) 数字转字符串自己实现。snprintf 看着省事，但它内部可能分配缓冲区，
//     在信号处理器里这就是一颗雷 —— 而且这颗雷只在真崩溃时炸，平时测试全绿。
//
//  3) 文件一律追加写 + 定长上限。取证日志把用户的磁盘写满是另一种事故。
//

#import "DCLTimelinePersist.h"
#import "DCLTimeline.h"
#import "DCLSupport.h"   // async-signal-safe 文本拼接：不在本文件里再抄一份
#import "DCLProbeCost.h"

#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>

#define DCL_TLP_PERIOD_SEC      5     ///< 常规落盘周期（秒）
#define DCL_TLP_MAX_BYTES   (256 * 1024)  ///< 单文件上限，超出轮转
#define DCL_TLP_EMERGENCY_MAX  64     ///< 崩溃时抢救的条数（见头文件取舍说明）
#define DCL_TLP_PATH_MAX      1024

static dispatch_queue_t  g_tlp_queue = NULL;
static dispatch_source_t g_tlp_timer = NULL;
static volatile int32_t  g_tlp_started = 0;

// 三个文件的路径，同时保留 C 字符串形式：
// 崩溃紧急落盘发生在信号处理器里，那时一个 ObjC 对象都不能创建。
static char g_crash_path[DCL_TLP_PATH_MAX] = {0};
static NSString *g_dir_ns = nil;
static NSString *g_main_path = nil;
static NSString *g_prev_path = nil;
static NSString *g_taken_path = nil;

static uint64_t g_last_seq = 0;   ///< 已落盘的最大 seq（增量依据）

#pragma mark - 崩溃紧急落盘（信号上下文专用）

/// 毫秒拆成「整数部分.一位小数」：只拼一个小数点，
/// 数字由 DCLSupport 的 async-signal-safe 版本产出 —— 这里不引进 snprintf。
static size_t dcl_ms_dec(double ms, char *out, size_t cap) {
    if (!out || cap == 0) return 0;
    int64_t whole = (int64_t)ms;
    if (whole < 0) whole = 0;
    size_t n = DCLI64ToDec(whole, out, cap);
    int64_t frac = (int64_t)((ms - (double)whole) * 10.0);
    if (frac < 0) frac = 0;
    if (frac > 9) frac = 9;
    if (n + 2 <= cap) {
        out[n++] = '.';
        out[n++] = (char)('0' + (int)frac);
    }
    return n;
}

/// 事件类型的可读名。返回静态常量 —— 不分配、不经 ObjC 派发。
static const char *dcl_kind_label_c(uint32_t kind) {
    switch (kind) {
        case DCLTlKindPauseHook:        return "暂停钩子";
        case DCLTlKindPlayHook:         return "播放钩子";
        case DCLTlKindItemReplace:      return "换源";
        case DCLTlKindAVPlayerSeen:     return "AVPlayer实例";
        case DCLTlKindTouch:            return "触摸";
        case DCLTlKindMainThreadStall:  return "主线程卡顿";
        case DCLTlKindAudioInterrupt:   return "音频中断";
        case DCLTlKindAudioRouteChange: return "音频路由变更";
        case DCLTlKindEnterBackground:  return "进入后台";
        case DCLTlKindEnterForeground:  return "回到前台";
        case DCLTlKindResignActive:     return "即将失活";
        case DCLTlKindBecomeActive:     return "重新激活";
        case DCLTlKindLockScreen:       return "锁屏";
        case DCLTlKindUnlockScreen:     return "解锁";
        case DCLTlKindMemoryWarning:    return "内存警告";
        case DCLTlKindCrash:            return "崩溃";
        case DCLTlKindSnapshot:         return "生成快照";
        case DCLTlKindHookInstalled:    return "钩子挂载";
    }
    return "未知类型";
}

#pragma mark - 崩溃紧急落盘（信号上下文专用）

void DCLTimelineEmergencyDump(const char *path) {
    if (!path || !path[0]) return;

    DCLTimelineEntry buf[DCL_TLP_EMERGENCY_MAX];
    memset(buf, 0, sizeof(buf));
    size_t n = DCLTimelineCopyEntriesUnsafe(buf, DCL_TLP_EMERGENCY_MAX);
    if (n == 0) return;

    // O_TRUNC：每次崩溃只留最后的现场，不和历史叠加。
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;

    uint64_t base = buf[0].mono_ns;
    char line[512];

    for (size_t i = 0; i < n; i++) {
        const DCLTimelineEntry *e = &buf[i];
        double relMs = 0.0;
        if (e->mono_ns >= base) {
            relMs = (double)(e->mono_ns - base) / 1000000.0;
        }

        size_t o = 0;
        o += DCLU64ToDec(e->seq, line + o, sizeof(line) - o);
        line[o++] = ' ';
        line[o++] = '+';
        o += dcl_ms_dec(relMs, line + o, sizeof(line) - o);
        line[o++] = 'm'; line[o++] = 's';
        line[o++] = ' ';

        const char *label = dcl_kind_label_c(e->kind);
        size_t ln = DCLStrLenSafe(label);
        for (size_t k = 0; k < ln && o + 1 < sizeof(line); k++) line[o++] = label[k];
        line[o++] = ' ';
        line[o++] = 'a'; line[o++] = 'u'; line[o++] = 'x'; line[o++] = '=';
        o += DCLI64ToDec((int64_t)e->aux, line + o, sizeof(line) - o);
        line[o++] = ' ';

        const char *d = e->detail;
        size_t dn = DCLStrLenSafe(d);
        for (size_t k = 0; k < dn && o + 1 < sizeof(line); k++) line[o++] = d[k];
        line[o++] = '\n';

        // write 被信号打断时返回值可能小于请求长度，只看短写/错误就行：
        // 这里漏一个字符都比多一次不可靠的重试强。
        ssize_t w = write(fd, line, o);
        if (w < 0 && errno != EINTR) break;
    }

    close(fd);
}

#pragma mark - 常规落盘（可用 Foundation）

/// 把 seq 大于 g_last_seq 的条目追加到 timeline.log。返回本次写入条数。
static NSUInteger dcl_tlp_append_new(void) {
    if (!g_main_path) return 0;

    uint64_t t0 = DCLTimelineMonoNow();

    NSUInteger cap = DCL_TL_CAPACITY;
    DCLTimelineEntry *buf = (DCLTimelineEntry *)calloc(cap, sizeof(DCLTimelineEntry));
    if (!buf) return 0;
    NSUInteger n = [DCLTimeline copyEntries:buf capacity:cap];
    if (n == 0) {
        free(buf);
        DCLProbeCostRecordC("时间线.落盘", (double)(DCLTimelineMonoNow() - t0) / 1000000.0);
        return 0;
    }

    NSFileManager *fm = [NSFileManager defaultManager];

    // 超限先轮转：取证日志把磁盘写满那是另一种事故
    BOOL needRotate = NO;
    NSDictionary *attr = [fm attributesOfItemAtPath:g_main_path error:nil];
    if (attr && [attr[NSFileSize] unsignedLongLongValue] > DCL_TLP_MAX_BYTES) {
        needRotate = YES;
    }
    if (needRotate) {
        [fm removeItemAtPath:g_prev_path error:nil];
        [fm moveItemAtPath:g_main_path toPath:g_prev_path error:nil];
    }

    NSMutableString *chunk = [NSMutableString string];
    uint64_t maxSeq = g_last_seq;
    NSUInteger written = 0;

    uint64_t base = buf[0].mono_ns;
    for (NSUInteger i = 0; i < n; i++) {
        DCLTimelineEntry *e = &buf[i];
        // 环形缓冲覆盖后 seq 会继续递增，这里跳过已写过的部分
        if (e->seq <= g_last_seq && g_last_seq > 0) continue;

        double relMs = (double)((e->mono_ns > base) ? (e->mono_ns - base) : 0) / 1000000.0;
        NSString *detail = e->detail[0] ? [NSString stringWithUTF8String:e->detail] : @"";
        [chunk appendFormat:@"%u +%.1fms %@ aux=%d %@\n",
         (unsigned)e->seq, relMs,
         [NSString stringWithUTF8String:dcl_kind_label_c(e->kind)],
         (int)e->aux, detail];

        if (e->seq > maxSeq) maxSeq = e->seq;
        written++;
    }
    free(buf);

    if (written == 0) {
        DCLProbeCostRecordC("时间线.落盘", (double)(DCLTimelineMonoNow() - t0) / 1000000.0);
        return 0;
    }

    NSData *data = [chunk dataUsingEncoding:NSUTF8StringEncoding];
    // 已存在 → 追加；不存在 → 直接落一个新文件。
    // 刻意不用 NSOutputStream：为「写几 KB 文本」拉一整套流 API，
    // 可读性没变好，反而多一处需要记得 close 的地方。
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_main_path];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    } else {
        [data writeToFile:g_main_path atomically:NO];
    }

    const char *DCLProbeCostRecordCName = "时间线.落盘";
    g_last_seq = maxSeq;
    DCLProbeCostRecordC(DCLProbeCostRecordCName,
                        (double)(DCLTimelineMonoNow() - t0) / 1000000.0);
    return written;
}

const char *DCLTimelineCrashDumpPath(void) {
    return g_crash_path[0] ? g_crash_path : NULL;
}

@implementation DCLTimelinePersist

+ (void)startWithDirectory:(NSString *)directory {
    if (!directory.length) return;
    if (__sync_fetch_and_or(&g_tlp_started, 1)) return;

    @try {
        g_dir_ns = [directory copy];
        g_main_path = [directory stringByAppendingPathComponent:@"timeline.log"];
        g_prev_path = [directory stringByAppendingPathComponent:@"timeline_prev.log"];
        g_taken_path = [directory stringByAppendingPathComponent:@"timeline.crash.archived"];

        NSString *crashNS = [directory stringByAppendingPathComponent:@"timeline.crash"];
        const char *cp = crashNS.fileSystemRepresentation;
        if (cp) {
            strncpy(g_crash_path, cp, sizeof(g_crash_path) - 1);
            g_crash_path[sizeof(g_crash_path) - 1] = '\0';
        }

        g_tlp_queue = dispatch_queue_create("com.dcl.timeline.persist", DISPATCH_QUEUE_SERIAL);

        // 先立刻写一次：把本次会话之前（含上一版插件留下的）内存事件固定下来
        dispatch_async(g_tlp_queue, ^{
            @autoreleasepool { (void)dcl_tlp_append_new(); }
        });

        // 周期定时器：严格来说用 timer 会比 dispatch_after 递归少些漂移，
        // 这里两者皆可，选 dispatch_source 是为了随时能 suspend 掉（内存紧张时）。
        g_tlp_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_tlp_queue);
        if (g_tlp_timer) {
            dispatch_source_set_timer(g_tlp_timer,
                                      dispatch_time(DISPATCH_TIME_NOW, 0),
                                      (uint64_t)DCL_TLP_PERIOD_SEC * NSEC_PER_SEC,
                                      (uint64_t)1 * NSEC_PER_SEC);
            dispatch_source_set_event_handler(g_tlp_timer, ^{
                @autoreleasepool { (void)dcl_tlp_append_new(); }
            });
            dispatch_resume(g_tlp_timer);
        }
    } @catch (id e) {
        (void)e;
    }
}

+ (void)flushNow {
    if (!g_tlp_started) return;
    if (!g_tlp_queue) { (void)dcl_tlp_append_new(); return; }
    dispatch_async(g_tlp_queue, ^{
        @autoreleasepool { (void)dcl_tlp_append_new(); }
    });
}

+ (NSString *)takeLastCrashTimeline {
    if (!g_main_path) return nil;
    NSString *crashPath = [g_dir_ns stringByAppendingPathComponent:@"timeline.crash"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:crashPath]) return nil;

    NSData *d = [NSData dataWithContentsOfFile:crashPath];
    NSString *text = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;

    // 取走即归档：同一次崩溃的时间线不该在下一次生成快照时又被复读一遍
    [fm removeItemAtPath:g_taken_path error:nil];
    [fm moveItemAtPath:crashPath toPath:g_taken_path error:nil];
    return text.length ? text : nil;
}

+ (NSString *)timelineLogPath {
    if (!g_main_path) return nil;
    return [[NSFileManager defaultManager] fileExistsAtPath:g_main_path] ? g_main_path : nil;
}

@end
