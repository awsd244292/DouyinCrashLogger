//
//  DCLCrashLogViewer.h
//  DouyinCrashLogger
//
//  崩溃日志查看 / 导出 UI。摇一摇触发：列出日志 → 查看详情 → 分享 / 清除。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCLCrashLogViewer : NSObject

/// 呈现崩溃日志列表面板（ActionSheet）。自动定位最上层 VC 并 present。
+ (void)present;

/// 是否已有日志
+ (BOOL)hasLogs;

@end

NS_ASSUME_NONNULL_END
