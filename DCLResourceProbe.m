//
//  DCLResourceProbe.m
//  DouyinCrashLogger
//
//  实现要点见 DCLResourceProbe.h。此处补充三条落地约束：
//
//  1) 内存口径用 phys_footprint 而不是 resident_size。
//     iOS 的 Jetsam（内存杀手）就是按这种口径算账的；resident_size 把可被回收的
//     干净页也算进来，数值虚高，拿它当 OOM 判据容易把普通内存占用误判成 OOM。
//
//  2) 每次采样立刻 synchronize。App 被 SIGKILL 时没有「稍后再写一次」的机会，
//     不落地就等于这次采样白做 —— 这件事上宁可多付些 IO，也不能赌系统会替你 flush。
//
//  3) 采样间隔 15 秒是取舍结果：内存变化以秒计完全够看，更密的采样收益递减，
//     代价却是更多的定时唤醒与更多次磁盘写入。
//

#import "DCLResourceProbe.h"
#import "DCLWatchdog.h"

#import <mach/mach.h>
#import <mach/mach_host.h>
#import <os/proc.h>
#import <dispatch/dispatch.h>

#define DCL_RP_PERIOD_SEC 15

// NSUserDefaults key：与退出标记放在一起，进程被杀后由系统统一兜住
static NSString * const DCLPrevFootprintKey   = @"DCLPrevFootprintBytes";
static NSString * const DCLPrevAvailableKey   = @"DCLPrevAvailableBytes";
static NSString * const DCLPrevPeakKey        = @"DCLPrevPeakFootprintBytes";
static NSString * const DCLPrevStallKey       = @"DCLPrevLastStallMs";
static NSString * const DCLPrevSamplesKey     = @"DCLPrevSamples";

static dispatch_queue_t   g_rp_queue = NULL;
static dispatch_source_t  g_rp_timer = NULL;
static volatile int32_t   g_rp_started = 0;

static volatile uint64_t  g_peak_footprint = 0;
static volatile uint64_t  g_last_available = 0;

#pragma mark - 采样

/// 读出进程物理内存占用（phys_footprint，单位字节）
static uint64_t dcl_footprint_bytes(void) {
    task_vm_info_data_t vminfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&vminfo, &count);
    if (kr != KERN_SUCCESS) return 0;
    return (uint64_t)vminfo.phys_footprint;
}

/// 系统当前还剩多少可用内存给本进程（iOS 13+ 公开 API）
static uint64_t dcl_available_bytes(void) {
    return (uint64_t)os_proc_available_memory();
}

static NSDictionary *dcl_read_previous(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:DCLPrevFootprintKey] == nil) return nil;   // 从未安装过

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    unsigned long long footprint = [[ud objectForKey:DCLPrevFootprintKey] unsignedLongLongValue];
    unsigned long long available = [[ud objectForKey:DCLPrevAvailableKey] unsignedLongLongValue];
    unsigned long long peak      = [[ud objectForKey:DCLPrevPeakKey] unsignedLongLongValue];
    double stall                 = [[ud objectForKey:DCLPrevStallKey] doubleValue];
    NSUInteger samples           = [[ud objectForKey:DCLPrevSamplesKey] unsignedIntegerValue];

    d[@"lastFootprint"]  = @(footprint);
    d[@"lastAvailable"]  = @(available);
    d[@"peakFootprint"]  = @(peak);
    d[@"lastStallMs"]    = @(stall);
    d[@"samples"]        = @(samples);
    return d;
}

/// 本会话第一件事：把上一轮遗留的水位取出来先保管好，再重置计数。
/// 顺序不能反 —— 上一轮的记录一旦被本轮写覆盖，证据就永久丢了。
static NSDictionary *g_prev_snapshot = nil;

static void dcl_take_previous_snapshot(void) {
    if (g_prev_snapshot) return;
    g_prev_snapshot = dcl_read_previous();

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:@(0) forKey:DCLPrevFootprintKey];
    [ud setObject:@(0) forKey:DCLPrevAvailableKey];
    [ud setObject:@(0) forKey:DCLPrevPeakKey];
    [ud setObject:@(0.0) forKey:DCLPrevStallKey];
    [ud setObject:@(0) forKey:DCLPrevSamplesKey];
    [ud synchronize];
}

static void dcl_sample_once(void) {
    uint64_t fp = dcl_footprint_bytes();
    uint64_t av = dcl_available_bytes();

    if (fp > g_peak_footprint) g_peak_footprint = fp;
    g_last_available = av;

    // 主线程健康：取最近一次卡顿时长。
    // watchdog 杀进程的特征就是「临死前主线程长时间不响应」，
    // 这条数字是事后区分 OOM 与 watchdog 的关键证据之一。
    double stallMs = 0.0;
    NSArray<DCLStallRecord *> *stalls = [DCLWatchdog recentStalls];
    if (stalls.count) stallMs = stalls.lastObject.durationMs;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:@(fp) forKey:DCLPrevFootprintKey];
    [ud setObject:@(av) forKey:DCLPrevAvailableKey];
    [ud setObject:@(g_peak_footprint) forKey:DCLPrevPeakKey];
    [ud setObject:@(stallMs) forKey:DCLPrevStallKey];
    [ud setObject:@(([[ud objectForKey:DCLPrevSamplesKey] unsignedIntegerValue]) + 1)
           forKey:DCLPrevSamplesKey];
    [ud synchronize];
}

@implementation DCLResourceProbe

+ (void)start {
    if (__sync_fetch_and_or(&g_rp_started, 1)) return;

    @try {
        // 先把上一轮的水位接管过来，再开始本轮采样 —— 顺序见函数注释
        dcl_take_previous_snapshot();

        g_rp_queue = dispatch_queue_create("com.dcl.resourceprobe", DISPATCH_QUEUE_SERIAL);

        // 立刻采一次：让 Short-lived 会话（刚启动就崩）也有一条水位留下，
        // 否则第一份记录要等到 15 秒后 —— 而很多崩溃发生在这之前。
        dispatch_async(g_rp_queue, ^{
            @autoreleasepool { dcl_sample_once(); }
        });

        g_rp_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_rp_queue);
        if (g_rp_timer) {
            dispatch_source_set_timer(g_rp_timer,
                                      dispatch_time(DISPATCH_TIME_NOW, 0),
                                      (uint64_t)DCL_RP_PERIOD_SEC * NSEC_PER_SEC,
                                      (uint64_t)2 * NSEC_PER_SEC);
            dispatch_source_set_event_handler(g_rp_timer, ^{
                @autoreleasepool { dcl_sample_once(); }
            });
            dispatch_resume(g_rp_timer);
        }
    } @catch (id e) {
        (void)e;
    }
}

+ (NSDictionary<NSString *, id> *)previousSessionWatermark {
    if (!g_prev_snapshot) dcl_take_previous_snapshot();
    return g_prev_snapshot;
}

+ (unsigned long long)peakFootprintBytes { return (unsigned long long)g_peak_footprint; }

+ (unsigned long long)lastAvailableBytes { return (unsigned long long)g_last_available; }

+ (NSString *)currentStatusLine {
    unsigned long long fp = (unsigned long long)g_peak_footprint;
    unsigned long long av = (unsigned long long)g_last_available;
    if (fp == 0) return @"内存：尚未采样";
    return [NSString stringWithFormat:
            @"内存峰值 %.1f MB，最近一次采样时系统可用 %.1f MB",
            (double)fp / (1024.0 * 1024.0),
            (double)av / (1024.0 * 1024.0)];
}

@end
