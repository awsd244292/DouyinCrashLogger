//
//  DCLProbeCost.m
//  DouyinCrashLogger
//
//  实现要点见 DCLProbeCost.h。此处几条落地说明：
//
//  1) 用定长结构数组而非字典。取样点可能在钩子体、信号上下文这类地方，
//     那里不应该有哈希查找，更不应该有内存分配。名字用 strncmp 比对，
//     槽位上限 8 个 —— 探针环节本来就不该多到记不下。
//
//  2) 计数与求和全用 __sync 系列原子操作。不用 os_unfair_lock：
//     度量路径一旦要拿锁，就意味着「测一次开销要先付一次抢锁」，
//     被测的那条路径就已经被污染了。
//
//  3) 最大值更新用 CAS 自旋。并发下的「读-比较-写」必须成环，
//     否则两个线程先后写回各自的旧最大值，结果会停在偏小的那个数上 ——
//     而偏小的数字恰好会让「探针没什么开销」这个错误结论显得很可信。
//

#import "DCLProbeCost.h"

#import <string.h>

#define DCL_PC_SLOTS 8
#define DCL_PC_NAME  32

typedef struct {
    char     name[DCL_PC_NAME];
    uint64_t count;
    double   total_ms;
    double   max_ms;
} DCLProbeCostSlot;

static DCLProbeCostSlot g_slots[DCL_PC_SLOTS];
static volatile int32_t g_used = 0;

#pragma mark - 记账

/// 找不到就占一个新槽（初次占用时的并发竞最多让一个线程少记几笔，
/// 换来的是「以后每次都不必比较列表」，这个交换是划算的）
static DCLProbeCostSlot *dcl_pc_slot(const char *name) {
    if (!name || !name[0]) return NULL;

    int32_t used = g_used;
    for (int32_t i = 0; i < used; i++) {
        if (strncmp(g_slots[i].name, name, DCL_PC_NAME) == 0) return &g_slots[i];
    }

    int32_t slot = __sync_fetch_and_add(&g_used, 1);
    if (slot >= DCL_PC_SLOTS) {
        __sync_fetch_and_sub(&g_used, 1);     // 满了：退回计数，不再增长
        return NULL;
    }
    memset(&g_slots[slot], 0, sizeof(DCLProbeCostSlot));
    strncpy(g_slots[slot].name, name, DCL_PC_NAME - 1);
    return &g_slots[slot];
}

void DCLProbeCostRecordC(const char *name, double ms) {
    DCLProbeCostSlot *s = dcl_pc_slot(name);
    if (!s) return;

    __sync_fetch_and_add(&s->count, 1ULL);

    // 浮点没有标准的原子加，这里用整数化逼近：毫秒 × 1000 取整累加，误差 <1us，
    // 对「判断探针是否过重」这个目的来说绰绰有余，换来的却是无锁。
    __sync_fetch_and_add((int64_t volatile *)&s->total_ms,
                         (int64_t)(ms * 1000.0));

    // 最大值：CAS 自旋直到成功或被别人刷成更大的值
    double cur = s->max_ms;
    while (ms > cur) {
        if (__sync_bool_compare_and_swap((int64_t volatile *)&s->max_ms,
                                         (int64_t)(cur * 1000.0),
                                         (int64_t)(ms * 1000.0))) break;
        cur = s->max_ms;
    }
}

#pragma mark - 报告

@implementation DCLProbeCost

+ (void)record:(NSString *)name milliseconds:(double)ms {
    if (!name.length) return;
    DCLProbeCostRecordC(name.UTF8String, ms);
}

+ (NSArray<NSString *> *)reportLines {
    NSMutableArray *out = [NSMutableArray array];
    int32_t used = g_used;

    // 按总耗时降序：最贵的那一项必须排在最上面，
    // 人看日志的习惯是从前几行抓重点，把无关紧要的放前面等于藏证据。
    NSInteger idx[DCL_PC_SLOTS];
    int n = 0;
    for (int32_t i = 0; i < used; i++) {
        if (g_slots[i].count == 0) continue;
        idx[n++] = (NSInteger)i;
    }
    for (int a = 1; a < n; a++) {
        NSInteger key = idx[a];
        int b = a - 1;
        while (b >= 0 && g_slots[idx[b]].total_ms < g_slots[key].total_ms) {
            idx[b + 1] = idx[b];
            b--;
        }
        idx[b + 1] = key;
    }

    for (int i = 0; i < n; i++) {
        DCLProbeCostSlot *s = &g_slots[idx[i]];
        double total = (double)s->total_ms / 1000.0;
        double max   = (double)s->max_ms / 1000.0;
        double avg   = s->count ? (total / (double)s->count) : 0.0;
        [out addObject:[NSString stringWithFormat:
                        @"  %-24@ 次数 %6llu  平均 %7.3f ms  最大 %7.3f ms  累计 %8.1f ms",
                        [NSString stringWithUTF8String:s->name],
                        (unsigned long long)s->count, avg, max, total]];
    }
    return out;
}

+ (NSString *)verdictLine {
    int32_t used = g_used;
    BOOL heavy = NO;
    NSMutableString *who = [NSMutableString string];

    for (int32_t i = 0; i < used; i++) {
        DCLProbeCostSlot *s = &g_slots[i];
        if (s->count == 0) continue;
        double total = (double)s->total_ms / 1000.0;
        double avg = total / (double)s->count;

        // 判据：单线程路径上的「重」看单次最大值（会直接表现为一次掉帧），
        // 「压」看平均值（会平摊到每一次调用里）。
        // 阈值取经验值：单次 >5ms 已接近一帧的 1/3；平均 >0.5ms 在高频调用下会累积成可感知开销。
        if (s->max_ms / 1000.0 > 5.0 || avg > 0.5) {
            heavy = YES;
            [who appendFormat:@"%@%@（平均 %.3fms，最大 %.3fms）",
             who.length ? @"、" : @"",
             [NSString stringWithUTF8String:s->name], avg, (double)s->max_ms / 1000.0];
        }
    }

    if (!heavy) {
        return @"探针自身开销在可接受区间（无环节单次超 5ms 或平均超 0.5ms）";
    }
    return [@"探针自身可能已成为卡顿来源，超标段位：" stringByAppendingString:who];
}

@end
