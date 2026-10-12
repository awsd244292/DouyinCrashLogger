//
//  DCLProbeCost.h
//  DouyinCrashLogger
//
//  探针自身开销度量。
//
//  为什么值得单拎一个模块：
//    取证探针最容易犯的错，是把自己变成新的问题来源。这点团队是有过教训的 ——
//    之前那次冻屏，探针自身开销大概率就在里面掺了一脚。而每个探针的作者都倾向于
//    认为「我这几行很轻」，没人算过总账，最后账单以「抖音怎么又卡了」的形式寄给用户。
//
//  所以这里不给任何人留自我辩解的余地：钩子体里那一记 backtrace 到底花了多久、
//    落盘一次花了多久，全部记账，进 latest.log，超标就在日志里直接报警。
//
//  度量本身必须比被度量的东西还轻：
//    只做「读一次时钟 + 几次原子加」，不分配内存、不拿锁、不做 IO、不打日志。
//    如果连开销度量都需要日志系统才能工作，那它本身就成了新的开销。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCLProbeCost : NSObject

/// 记一笔某个探针环节的耗时（毫秒）。线程安全，可在任意调用上下文使用。
/// 刻意保留 C 入口（见下方 DCLProbeCostRecordC）：钩子体里不希望有任何 ObjC 派发。
+ (void)record:(NSString *)name milliseconds:(double)ms;

/// 所有已记录的探针环节，按总耗时从高到低输出。每行含：次数 / 平均 / 最大 / 累计。
+ (NSArray<NSString *> *)reportLines;

/// 一句话结论：探针自身是否可能在制造卡顿。平静与否都说依据，不粉饰。
+ (NSString *)verdictLine;

@end

#pragma mark - C 快捷入口

/// 钩子体/信号上下文里使用：纯原子累加，不做任何内存分配。
void DCLProbeCostRecordC(const char *name, double ms);

NS_ASSUME_NONNULL_END
