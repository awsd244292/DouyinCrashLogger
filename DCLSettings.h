//
//  DCLSettings.h
//  DouyinCrashLogger
//
//  设置入口接入 DYStorage（抖音插件收纳容器）。
//
//  为什么走 DYStorage 而不是直接 Hook 抖音设置页：
//    之前「每个插件各自 Hook 设置 VC」的写法，多插件一起注入时会对同一个
//    AWESettingsViewModel 反复 swizzle，顺序不定极易崩。DYStorage 由 xlzs001 维护，
//    只 Hook 一次设置页、提供全局注册入口，其它插件（DYYY / Yuki / 本插件）只注册
//    菜单项、由它统一渲染与派发点击。抖音升级也只需更新 DYStorage 一个库。
//
//  接入原则（对齐 DYStorage 官方 README）：
//    · 不链接 DYStorage —— 通过 NSClassFromString 在运行时取类，未安装则自然跳过；
//    · 注册一个「负责展示本插件设置页的 block」，点击时由 DYStorage 回调本插件；
//    · 不在全局保存控制器 / view model，只在用户点击的瞬间创建并 present。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCLSettings : NSObject

/// 向 DYStorage 注册本插件的设置入口。
/// DYStorage 未安装（或版本过旧无对应接口）时静默返回，不影响本插件任何功能。
/// 幂等，可重复调用；建议在主线程 runloop 稳定后（延迟块内）调用。
+ (void)registerEntry;

/// 找到当前最上层 UIViewController 并 present 本插件的设置面板。
/// 由 DYStorage 的点击回调触发；内部已保证在主线程执行。
+ (void)presentSettings;

@end

NS_ASSUME_NONNULL_END
