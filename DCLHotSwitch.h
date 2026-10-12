//
//  DCLHotSwitch.h
//  DouyinCrashLogger
//
//  热切换：三指轻点 → 翻转采集方案（safe ↔ full）→ 震 3 下反馈。
//
//  为什么需要它：capture_mode.txt 改文件的方式在 iPhone 上极不方便
//  （要 Filza 或导出整个容器），详见 DCLConfig.h 的档位说明。
//  这里提供一个 App 内免文件、免重启的切换入口。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCLHotSwitch : NSObject

/// 安装三指轻点监听（始终安装，独立于采集两档）。
/// 之所以不受档位控制：用户恰恰是在 safe 档想切到 full，
/// 若监听仅在 full 档生效，safe 档下将永远摇/点不出入口。
///
/// 监听点：UIApplication sendEvent:（UIWindow 同名方法兜底）。
/// 不再用 UIView touchesEnded:withEvent: —— 该方法几乎被所有 UIResponder 子类重写，
/// 挂在 UIView 本类上等于守了个没人经过的路口，真机上完全不触发。
+ (void)install;

/// 是否已安装（调试 / 健康自检用）
+ (BOOL)isInstalled;

/// 一句人话描述安装状态：挂在哪、失败的话为什么。
/// 三指没反应时先看这里 —— 比去猜「是不是没震动」直接得多。
+ (NSString *)installStateDescription;

@end

NS_ASSUME_NONNULL_END
