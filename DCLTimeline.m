//
//  DCLTimeline.m
//  DouyinCrashLogger
//
//  实现要点见 DCLTimeline.h。此处只补充几条落地时的硬约束：
//
//  1) 环形缓冲用定长 C 结构体数组，不用 NSMutableArray。
//     写入可能发生在崩溃信号上下文 / 任意钩子线程上，那里不能分配堆内存、
//     不能拿 ObjC 锁（拿锁时崩溃再来一次就是死锁）。定长数组 + unfair lock
//     的临界区只有「填字段 + 推进下标」，短到不会成为风险点。
//
//  2) 单调时钟用 mach_absolute_time 而非 CFAbsoluteTimeGetCurrent / NSDate。
//     后者跟随系统时间，用户改时间或设备跨休眠都会跳变，一跳变整条时间线的
//     因果关系就废了。mach_absolute_time 只随 CPU 走，进程内严格单调。
//
//  3) 每条事件额外存一份 wallclock 毫秒。单调时钟人没法读，
//     日志里必须有能对着手机看的时间，否则用户永远对不上「刚才那次」。
//

#import "DCLTimeline.h"

#import <mach/mach.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <sys/time.h>
#import <string.h>

#define DCL_TL_CAP     512    ///< 环形缓冲槽位数（约 512 条，超出覆盖最旧）
#define DCL_TL_DETAIL   96    ///< 单条事件说明的最大长度（含结尾 \0）

typedef struct {
    uint64_t mono_ns;                  ///< 单调时间（纳秒）
    uint64_t wall_ms;                  ///< 墙钟时间（毫秒，unix epoch）
    uint32_t kind;                     ///< DCLTimelineEventKind
    uint32_t seq;                      ///< 全局递增序号
    int32_t  aux;                      ///< 数值辅助字段（卡顿毫秒 / rate*100 / 中断类型…）
    char     detail[DCL_TL_DETAIL];    ///< 短说明
} DCLTlEntry;

static DCLTlEntry   g_buf[DCL_TL_CAP];
static uint32_t     g_head  = 0;   ///< 下一个写入的槽位
static uint64_t     g_total = 0;   ///< 累计写入条数（含已被覆盖的）
static uint32_t     g_seq   = 0;
static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static mach_timebase_info_data_t g_tb = { 0, 0 };

__attribute__((constructor)) static void dcl_timeline_init(void) {
    // 换算分子/分母。失败就退化成 1:1 —— 时间会不准，但绝不让探针挂掉。
    if (mach_timebase_info(&g_tb) != KERN_SUCCESS || g_tb.denom == 0) {
        g_tb.numer = 1;
        g_tb.denom = 1;
    }
}

#pragma mark - C 入口

uint64_t DCLTimelineMonoNow(void) {
    uint64_t t = mach_absolute_time();
    // 构造器理论上先跑，但注入顺序不保证 —— 这里兜底，读到 0 就当 1:1。
    uint64_t numer = g_tb.numer ? (uint64_t)g_tb.numer : 1ULL;
    uint64_t denom = g_tb.denom ? (uint64_t)g_tb.denom : 1ULL;
    return (t * numer) / denom;
}

void DCLTimelineRecordC(DCLTimelineEventKind kind, int32_t aux, const char *detail) {
    uint64_t mono = DCLTimelineMonoNow();
    struct timeval tv;
    gettimeofday(&tv, NULL);
    uint64_t wall = (uint64_t)tv.tv_sec * 1000ULL + (uint64_t)(tv.tv_usec / 1000);

    os_unfair_lock_lock(&g_lock);
    DCLTlEntry *e = &g_buf[g_head];
    e->mono_ns = mono;
    e->wall_ms = wall;
    e->kind    = (uint32_t)kind;
    e->aux     = aux;
    e->seq     = g_seq++;
    if (detail && detail[0]) {
        strncpy(e->detail, detail, DCL_TL_DETAIL - 1);
        e->detail[DCL_TL_DETAIL - 1] = '\0';
    } else {
        e->detail[0] = '\0';
    }
    g_head = (g_head + 1) % DCL_TL_CAP;
    g_total++;
    os_unfair_lock_unlock(&g_lock);
}

#pragma mark - 内部：快照拷贝

/// 把当前缓冲按时间正序拷一份出来，返回条数。
static NSUInteger dcl_tl_snapshot(DCLTlEntry *out, NSUInteger cap) {
    if (!out || cap == 0) return 0;
    os_unfair_lock_lock(&g_lock);
    NSUInteger n = g_total > (uint64_t)DCL_TL_CAP ? (NSUInteger)DCL_TL_CAP : (NSUInteger)g_total;
    NSUInteger start = (NSUInteger)((g_head + DCL_TL_CAP - (uint32_t)n) % DCL_TL_CAP);
    NSUInteger m = n < cap ? n : cap;
    for (NSUInteger i = 0; i < m; i++) {
        out[i] = g_buf[(start + i) % DCL_TL_CAP];
    }
    os_unfair_lock_unlock(&g_lock);
    return m;
}

static NSString *dcl_tl_kind_name(uint32_t kind) {
    switch ((DCLTimelineEventKind)kind) {
        case DCLTlKindPauseHook:        return @"暂停钩子";
        case DCLTlKindPlayHook:         return @"播放钩子";
        case DCLTlKindItemReplace:      return @"换源";
        case DCLTlKindAVPlayerSeen:     return @"AVPlayer实例";
        case DCLTlKindTouch:            return @"触摸";
        case DCLTlKindMainThreadStall:  return @"主线程卡顿";
        case DCLTlKindAudioInterrupt:   return @"音频中断";
        case DCLTlKindAudioRouteChange: return @"音频路由变更";
        case DCLTlKindEnterBackground:  return @"进入后台";
        case DCLTlKindEnterForeground:  return @"回到前台";
        case DCLTlKindResignActive:     return @"即将失活";
        case DCLTlKindBecomeActive:     return @"重新激活";
        case DCLTlKindLockScreen:       return @"锁屏";
        case DCLTlKindUnlockScreen:     return @"解锁";
        case DCLTlKindMemoryWarning:    return @"内存警告";
        case DCLTlKindCrash:            return @"崩溃";
        case DCLTlKindSnapshot:         return @"生成快照";
    }
    return [NSString stringWithFormat:@"类型%u", (unsigned)kind];
}

/// 把一条事件格式化成时间线行。baseMono 为时间基准（缓冲内第一条），
/// 相对毫秒以它为 0 —— 「暂停前 200ms 发生了什么」靠这一列读出来。
static NSString *dcl_tl_format(const DCLTlEntry *e, uint64_t baseMono, NSUInteger idx) {
    double relMs = 0.0;
    if (e->mono_ns >= baseMono) {
        relMs = (double)(e->mono_ns - baseMono) / 1000000.0;
    } else {
        relMs = -(double)(baseMono - e->mono_ns) / 1000000.0;
    }

    uint64_t ms = e->wall_ms;
    time_t sec = (time_t)(ms / 1000ULL);
    struct tm tmv;
    localtime_r(&sec, &tmv);

    NSString *detail = e->detail[0] ? [NSString stringWithUTF8String:e->detail] : @"";
    return [NSString stringWithFormat:
            @"#%03lu +%9.1fms %02d:%02d:%02d.%03llu %-10@ aux=%-6d %@",
            (unsigned long)idx,
            relMs,
            tmv.tm_hour, tmv.tm_min, tmv.tm_sec,
            (unsigned long long)(ms % 1000ULL),
            dcl_tl_kind_name(e->kind),
            e->aux,
            detail];
}

#pragma mark - ObjC 接口

@implementation DCLTimeline

+ (void)recordKind:(DCLTimelineEventKind)kind
               aux:(int32_t)aux
            detail:(NSString *)detail {
    // 走 C 入口：ObjC 入口只是为了让调用方写起来顺手，底层同一条路径。
    DCLTimelineRecordC(kind, aux, detail ? detail.UTF8String : NULL);
}

+ (uint64_t)totalRecorded { return g_total; }

+ (NSUInteger)bufferedCount {
    return g_total > (uint64_t)DCL_TL_CAP ? (NSUInteger)DCL_TL_CAP : (NSUInteger)g_total;
}

+ (NSArray<NSString *> *)formattedLines {
    return [self formattedLinesLimit:DCL_TL_CAP];
}

+ (NSArray<NSString *> *)formattedLinesLimit:(NSUInteger)limit {
    NSUInteger cap = limit > DCL_TL_CAP ? DCL_TL_CAP : limit;
    if (cap == 0) return @[];

    // 整缓冲拷出来再取尾部 cap 条：想要的是「最近 N 条」，
    // 若直接拷 cap 条拿到的是最旧的一批，相对时间基准也就跟着偏了。
    DCLTlEntry *all = (DCLTlEntry *)calloc(DCL_TL_CAP, sizeof(DCLTlEntry));
    if (!all) return @[];
    NSUInteger total = dcl_tl_snapshot(all, DCL_TL_CAP);
    if (total == 0) { free(all); return @[]; }

    NSUInteger skip = total > cap ? total - cap : 0;
    NSUInteger n = total - skip;
    uint64_t base = all[skip].mono_ns;

    NSMutableArray *lines = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        [lines addObject:dcl_tl_format(&all[skip + i], base, i)];
    }
    free(all);
    return lines;
}

+ (NSString *)kindName:(DCLTimelineEventKind)kind {
    return dcl_tl_kind_name((uint32_t)kind);
}

+ (BOOL)avPlayerSeen { return [self avPlayerSeenCount] > 0; }

+ (NSUInteger)avPlayerSeenCount {
    DCLTlEntry *all = (DCLTlEntry *)calloc(DCL_TL_CAP, sizeof(DCLTlEntry));
    if (!all) return 0;
    NSUInteger n = dcl_tl_snapshot(all, DCL_TL_CAP);
    NSUInteger c = 0;
    for (NSUInteger i = 0; i < n; i++) {
        if (all[i].kind == (uint32_t)DCLTlKindAVPlayerSeen) c++;
    }
    free(all);
    return c;
}

+ (double)millisecondsSinceLastKind:(DCLTimelineEventKind)kind {
    DCLTlEntry *all = (DCLTlEntry *)calloc(DCL_TL_CAP, sizeof(DCLTlEntry));
    if (!all) return -1.0;
    NSUInteger n = dcl_tl_snapshot(all, DCL_TL_CAP);
    uint64_t now = DCLTimelineMonoNow();
    double best = -1.0;
    for (NSUInteger i = 0; i < n; i++) {
        if (all[i].kind != (uint32_t)kind) continue;
        if (all[i].mono_ns > now) continue;
        double d = (double)(now - all[i].mono_ns) / 1000000.0;
        if (best < 0 || d < best) best = d;
    }
    free(all);
    return best;
}

+ (NSArray<NSString *> *)contextLinesBefore:(DCLTimelineEventKind)anchor
                                   windowMs:(double)windowMs
                                      limit:(NSUInteger)limit {
    DCLTlEntry *all = (DCLTlEntry *)calloc(DCL_TL_CAP, sizeof(DCLTlEntry));
    if (!all) return @[];
    NSUInteger n = dcl_tl_snapshot(all, DCL_TL_CAP);
    if (n == 0) { free(all); return @[]; }

    // 找最近一次锚点事件
    NSInteger anchorIdx = -1;
    for (NSInteger i = (NSInteger)n - 1; i >= 0; i--) {
        if (all[i].kind == (uint32_t)anchor) { anchorIdx = i; break; }
    }
    if (anchorIdx < 0) { free(all); return @[]; }

    uint64_t anchorMono = all[anchorIdx].mono_ns;
    uint64_t window = (uint64_t)(windowMs * 1000000.0);

    NSMutableArray *picked = [NSMutableArray array];
    for (NSInteger i = 0; i <= anchorIdx; i++) {
        if (all[i].mono_ns + window < anchorMono) continue;   // 窗口外，跳过
        [picked addObject:[NSValue valueWithBytes:&all[i] objCType:@encode(DCLTlEntry)]];
    }
    free(all);

    // 只保留窗口内最后 limit 条
    NSUInteger keep = picked.count > limit ? limit : picked.count;
    NSUInteger start = picked.count - keep;
    NSMutableArray *lines = [NSMutableArray arrayWithCapacity:keep];
    for (NSUInteger i = start; i < picked.count; i++) {
        DCLTlEntry e;
        [picked[i] getValue:&e];
        [lines addObject:dcl_tl_format(&e, anchorMono, i - start)];
    }
    return lines;
}

@end
