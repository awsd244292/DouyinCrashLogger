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

NS_ASSUME_NONNULL_END

#endif /* DCLSupport_h */
