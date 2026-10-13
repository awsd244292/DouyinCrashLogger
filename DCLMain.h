//
//  DCLMain.h
//  DouyinCrashLogger
//
//  装配编排层：把「装」和「卸」这两件事各自收敛到一个地方。
//
//  为什么要单独抽一层：
//    插件一共 7 个模块，每个都自带 install。若「冷启动装哪些」和「热切换装哪些」
//    各写一遍，两处迟早会走偏 —— 典型症状是冷启动装了 A、热切换回来却漏了 A，
//    于是「切一次再切回来，插件就少了一半功能」，而且极难复现。
//    现在两条路径共用同一组函数，装的清单只有一份定义。
//
//  总开关 off 的语义（详见 DCLConfig.isDisabled）：
//    卸到「这个插件从未注入过」的程度 —— 崩溃捕获（信号 / OC 异常）、卡死看门狗、
//    播放方法交换、系统信号探针、时间线落盘、资源采样、stderr 接管、日志写入，全卸。
//    刻意保留的两处例外：摇一摇检测、设置页入口 —— 它们是仅剩的自救通道。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCLOrchestrator : NSObject

/// 按当前档位把该装的都装上。冷启动延迟块与「从 off 切回来」共用这一条路径。
///
/// 幂等：每个模块的 install 自带守卫，重复调用不会重复挂载；
/// 从 safe 切到 full 时，播放探针也是在这里补装的（方法交换即时生效）。
/// 必须在主 runloop 稳定之后调用 —— 播放探针要交换 UIApplication 的方法实现，
/// stderr 接管同样禁止在 constructor / +load 阶段做。
+ (void)startupAll;

/// 彻底归零：卸掉一切，只留摇一摇与设置页入口。
///
/// 本身不写任何日志（off 冷启动时不该在别人上一轮的日志尾巴上添字）；
/// 需要留痕的调用方（热切换）应在调用前自己写那一行，再关掉写入闸门。
+ (void)shutdownAll;

/// 热切换入口：读当前档位，决定装还是卸，并留下一条可验证的日志行。
/// 摇一摇与设置页开关都走这里，保证两条通道的行为完全一致。
+ (void)applyCurrentProfile;

@end

NS_ASSUME_NONNULL_END
