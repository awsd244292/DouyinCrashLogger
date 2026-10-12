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
+ (void)install;

/// 是否已安装（调试 / 健康自检用）
+ (BOOL)isInstalled;

@end

NS_ASSUME_NONNULL_END
