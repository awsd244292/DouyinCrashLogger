//
//  DCLCrashLogViewer.m
//  DouyinCrashLogger
//

#import "DCLCrashLogViewer.h"
#import "DCLCrashReporter.h"
#import "DCLConstants.h"

#pragma mark - 辅助：找到最上层 presented VC

static UIViewController *dcl_top_view_controller(UIViewController *root) {
    UIViewController *vc = root;
    while (vc) {
        UIViewController *presented = vc.presentedViewController;
        if (presented && !presented.isBeingDismissed) {
            // 处理 UINavigationController / UITabBarController 内部 present
            if ([presented isKindOfClass:[UINavigationController class]]) {
                UINavigationController *nav = (UINavigationController *)presented;
                vc = dcl_top_view_controller(nav.topViewController ?: nav.viewControllers.lastObject);
                continue;
            }
            vc = presented;
        } else {
            if ([vc isKindOfClass:[UINavigationController class]]) {
                UINavigationController *nav = (UINavigationController *)vc;
                vc = nav.topViewController ?: vc;
                continue;
            }
            if ([vc isKindOfClass:[UITabBarController class]]) {
                UITabBarController *tab = (UITabBarController *)vc;
                vc = tab.selectedViewController ?: vc;
                continue;
            }
            break;
        }
    }
    return vc;
}

static UIViewController *dcl_current_top_vc(void) {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *window = app.keyWindow;
    if (!window) {
        for (UIWindow *w in app.windows) {
            if (w.isKeyWindow || w.windowLevel == UIWindowLevelNormal) { window = w; break; }
        }
    }
    if (!window) return nil;
    return dcl_top_view_controller(window.rootViewController);
}

#pragma mark - 日志文件列表

@interface DCLCrashLogViewer ()
@end

@implementation DCLCrashLogViewer

+ (NSArray<NSString *> *)sortedLogNames {
    NSString *dir = [DCLCrashReporter crashLogsDirectory];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *logs = [NSMutableArray array];
    for (NSString *f in files) {
        if ([f hasPrefix:@"crash_"]) [logs addObject:f];
    }
    // 文件名含 unix 时间戳，字典序即时间序
    [logs sortUsingSelector:@selector(compare:)];
    return logs;
}

+ (BOOL)hasLogs {
    return [self sortedLogNames].count > 0;
}

+ (void)present {
    NSArray<NSString *> *logs = [self sortedLogNames];
    UIViewController *top = dcl_current_top_vc();
    if (!top) return;

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"抖音崩溃日志"
                         message:[NSString stringWithFormat:@"检测到 %lu 条崩溃记录",
                                   (unsigned long)logs.count]
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *name in logs) {
        [sheet addAction:[UIAlertAction actionWithTitle:name
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            [self presentDetailWithName:name from:top];
        }]];
    }

    if (logs.count > 0) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"全部导出"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            [self shareAllFrom:top];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"清除全部"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *a) {
            [self clearAll];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    // iPad 需要 sourceView
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = top.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(
            CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 0, 0);
    }

    [top presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 详情

+ (void)presentDetailWithName:(NSString *)name from:(UIViewController *)top {
    NSString *dir = [DCLCrashReporter crashLogsDirectory];
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSString *content = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    if (!content) content = @"(无法读取文件)";

    UIViewController *detail = [[UIViewController alloc] init];
    detail.title = name;
    detail.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:detail.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.text = content;
    tv.editable = NO;
    tv.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    tv.textColor = [UIColor labelColor];
    [detail.view addSubview:tv];

    UIBarButtonItem *share = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:self
                             action:@selector(shareCurrent:)];
    share.accessibilityHint = path; // 借用 hint 传递路径
    detail.navigationItem.rightBarButtonItem = share;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:detail];
    [top presentViewController:nav animated:YES completion:nil];
}

+ (void)shareCurrent:(UIBarButtonItem *)sender {
    NSString *path = sender.accessibilityHint;
    if (!path) return;
    UIViewController *top = dcl_current_top_vc();
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *avc =
        [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                        applicationActivities:nil];
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.barButtonItem = sender;
    }
    [top presentViewController:avc animated:YES completion:nil];
}

#pragma mark - 批量导出 / 清除

+ (void)shareAllFrom:(UIViewController *)top {
    NSString *dir = [DCLCrashReporter crashLogsDirectory];
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *name in [self sortedLogNames]) {
        [urls addObject:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]]];
    }
    if (urls.count == 0) return;

    UIActivityViewController *avc =
        [[UIActivityViewController alloc] initWithActivityItems:urls
                                        applicationActivities:nil];
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = top.view;
        avc.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 0, 0);
    }
    [top presentViewController:avc animated:YES completion:nil];
}

+ (void)clearAll {
    NSString *dir = [DCLCrashReporter crashLogsDirectory];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *f in files) {
        if ([f hasPrefix:@"crash_"]) {
            [[NSFileManager defaultManager]
                removeItemAtPath:[dir stringByAppendingPathComponent:f]
                          error:nil];
        }
    }
}

@end
