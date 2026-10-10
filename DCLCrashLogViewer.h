//
//  DCLCrashLogViewer.h
//  DouyinCrashLogger
//
//  独立日志查看页（原生 UIKit）：状态区 + 崩溃记录列表 + 运行时日志，工具栏含清空/复制/导出。
//  通过抖音“设置”页右上角「📋 崩溃日志」按钮唤起。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCLCrashLogViewer : NSObject

/// 呈现独立日志查看页（自动定位最上层 VC 并 present）。
+ (void)present;

/// 是否已有崩溃日志
+ (BOOL)hasLogs;

@end

NS_ASSUME_NONNULL_END
