//
//  DCLSupport.h
//  DouyinCrashLogger
//
//  全插件共用的底层工具（纯 C 层，不依赖任何业务类）。
//
//  为什么单拎一个文件：DCLWatchdog / DCLPlaybackTracer / DCLHotSwitch / DCLLogger
//  里原本各自抄了一份「微秒时钟」和「类自有方法判定 / 安全替换」，改动其中一份，
//  另外几份不会跟着改 —— 这类重复正是最容易养 bug 的土壤。此处收敛成唯一实现。
//
//  约束：本文件所有函数均不得触碰 Foundation（除 DCLASCIISanitized 明确标注），
//  以便将来在信号等敏感上下文复用时不必再审查一遍依赖链。
//

#ifndef DCLSupport_h
#define DCLSupport_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 时间

/// 微秒级单调参考时间戳。基于 gettimeofday（async-signal-safe），
/// 可用于钩子体、runloop 回调等非信号处理上下文。
uint64_t DCLNowUs(void);

#pragma mark - Runtime 交换

/// 本类是否「自己拥有」该实例方法的实现（不含从父类继承来的）。
/// class_getInstanceMethod 会一路向上找到父类实现，拿它去替换会改到父类 ——
/// 那是会波及所有子类的实质破坏，替换前必须先问这一句。
BOOL DCLClassOwnsInstanceMethod(Class cls, SEL sel);

/// 从实例的真实所属类出发、沿继承链向上，找到「最靠下」的那个真正实现了 sel 的类。
///
/// 为什么不能永远只钩 UIApplication 本类：宿主完全可能写一个 UIApplication 子类并
/// 重写 sendEvent: —— 那时消息会直接落进子类的实现，根本不路过我们替换掉的那个
/// 「父类」实现（除非子类恰好调用了 [super sendEvent:]，而调不调、什么时候调都不由
/// 我们决定）。沿着「实例 → 真实类 → 拥有该实现的那一层」去找，才钩得住真正会被
/// 派发到的位置。stopAtInclusive 用于把搜索范围卡死在某个基类以内。
Class _Nullable DCLMostDerivedMethodOwner(id obj, SEL sel, Class _Nullable stopAtInclusive);

/// 唯一的实例方法替换入口，替各模块把三件事做全：
///   1) 只换本类自有实现，绝不碰父类（换到父类 = 影响全部子类）；
///   2) 取原 IMP 交给调用方透传 —— 取不到就宁可不挂，绝不可吞掉宿主行为；
///   3) 已挂过的守卫：orig == newImp 说明会自环，直接拒绝。
/// typeEncoding 传 NULL 时自动沿用现方法的 encoding。
/// 出参用 void ** 而非 IMP *：clang 下 IMP 是 void(*)(void)，与具体签名不兼容且 -Werror 会报错。
BOOL DCLReplaceInstanceMethod(Class cls,
                              SEL sel,
                              const char * _Nullable typeEncoding,
                              void *newImp,
                              void * _Nonnull * _Nonnull outOrig);

#pragma mark - 文本

/// 转成纯 ASCII：非 ASCII 字节一律转义成 \xNN，控制字符只保留 \n / \t。
///
/// 用途：运行时日志（plugin_runtime.log）写的东西一半是宿主吐出来的，
/// 里面既有 UTF-8 中文也有真·乱码字节。落到文件里一旦被第三方查看工具按
/// Latin-1 / GBK 解，就变成满屏「ä¸­æ–‡」。宁愿损失一点可读性，
/// 也要保证任何工具打开都是干净的一张 ASCII 表。
/// （面向人读的结构化报告 latest.log 仍保留中文 UTF-8，不走这里。）
NSString *DCLASCIISanitized(NSString * _Nullable s);

#pragma mark - async-signal-safe 文本拼接

// 下面这几个不是「简化版 snprintf」，而是**唯一允许**用在某些上下文里的那套东西：
// 信号处理器里能调的函数由 POSIX 明文规定（sigaction(2) 手册有清单），
// snprintf 不在其中 —— 它可能触碰 locale、也可能在内部分配缓冲。
// 现实很骨感：这类违规平时测不出来，只在真崩溃那一刻失真，
// 而那正是最需要证据准确的时刻。所以宁可手写、宁可啰嗦。
//
// 全部约定：调用方提供目标缓冲与其容量，函数只负责按容量追加并返回新偏移，
// 绝不分配内存、绝不触碰 locale、绝不调用任何 ObjC。

/// 安全的strlen（容忍 NULL）
size_t DCLStrLenSafe(const char * _Nullable s);

/// 追加字符串到 buf[off]，返回新偏移。容量不足时按边界截断，绝不越界写。
size_t DCLAppendStr(char *buf, size_t off, size_t cap, const char * _Nullable src);

/// 十进制格式化（含负数处理：刻意绕开 -INT64_MIN 溢出）
size_t DCLU64ToDec(uint64_t v, char *out, size_t cap);
size_t DCLI64ToDec(int64_t v, char *out, size_t cap);

NS_ASSUME_NONNULL_END

#endif /* DCLSupport_h */
