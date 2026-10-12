//
//  DCLHotSwitch.h
//  DouyinCrashLogger
//
//  热切换：摇一摇 → 翻转采集方案（safe ↔ full）→ 顶部轻提示 + 三连触感反馈。
//
//  为什么需要它：capture_mode.txt 改文件的方式在 iPhone 上极不方便
//  （要 Filza 或导出整个容器），详见 DCLConfig.h 的档位说明。
//  这里提供一个 App 内免文件、免重启的切换入口。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCLHotSwitch : NSObject

/// 安装摇一摇监听（始终安装，独立于采集两档）。
/// 之所以不受档位控制：用户恰恰是在 safe 档想切到 full，
/// 若监听仅在 full 档生效，safe 档下将永远摇不出入口。
///
/// 监听点：UIApplication sendEvent:（UIWindow 同名方法兜底），只看事件是不是
/// motion/shake。之所以选 sendEvent:：它是所有事件（含 motion）的唯一总入口，
/// 且投递与否「与宿主是否消费摇一摇无关」—— 抖音自己吞掉摇一摇我们也看得到。
///
/// 不再用三指轻点：三指要跟抖音自带的手势识别器（上下滑切视频、双击点赞、长按菜单）
/// 抢事件，真机上根本抢不到；也不再挂 UIView touchesEnded:withEvent: —— 该方法
/// 几乎被所有 UIResponder 子类重写，挂在 UIView 本类上等于守了个没人经过的路口。
+ (void)install;

/// 是否已安装（调试 / 健康自检用）
+ (BOOL)isInstalled;

/// 一句人话描述安装状态：挂在哪、失败的话为什么。
/// 摇了没反应时先看这里 —— 比去猜「是不是没提示」直接得多。
+ (NSString *)installStateDescription;

/// 入口说明（供开关文件、日志头部复用，避免各处各写一套文案）
+ (NSString *)triggerGuide;

@end

NS_ASSUME_NONNULL_END
