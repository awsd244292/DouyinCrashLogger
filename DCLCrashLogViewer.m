//
//  DCLCrashLogViewer.m
//  DouyinCrashLogger
//
//  独立日志查看页（原生 UIKit，非 SwiftUI）：
//  - 顶部状态区：展示「上次退出状态」（正常 / 疑似闪退无 ips / 首次运行）+ SIGKILL/OOM 限制说明。
//  - 崩溃记录区：列出沙盒内所有 crash_*.log（ips 文本），点击查看详情。
//  - 运行时日志区：展示重定向后的 plugin_runtime.log 末尾内容。
//  - 底部工具栏：清空日志 / 复制全部 / 导出。
//
//  防坑（遵循注入规范）：
//  - 文件读取全部走后台队列，绝不在主线程 / viewDidLoad 同步读大文件。
//  - 在最上层 VC（而非 rootVC）上 present，兼容抖音多窗口 / 浮窗播放。
//  - 全程 @try/@catch 包裹，插件自身异常不影响宿主。
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

#pragma mark - 主页面

@interface DCLLogMasterVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSString *> *crashNames;
@property (nonatomic, assign) BOOL hasRuntime;
@end

@implementation DCLLogMasterVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"插件日志查看器";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                              style:UITableViewStyleGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    [self.view addSubview:_tableView];

    // 底部工具栏：清空 / 复制全部 / 导出
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"清空"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(onClear:)];
    clear.tintColor = [UIColor systemRedColor];
    UIBarButtonItem *copyAll = [[UIBarButtonItem alloc] initWithTitle:@"复制全部"
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(onCopyAll:)];
    UIBarButtonItem *exportAll = [[UIBarButtonItem alloc] initWithTitle:@"导出"
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(onExportAll:)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[clear, flex, copyAll, flex, exportAll];

    [self reloadDataAsync];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.toolbarHidden = NO;
}

#pragma mark - 数据加载（后台读取，避免主线程卡顿）

- (void)reloadDataAsync {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *names = [DCLCrashLogViewer sortedLogNames];
        NSString *rt = [DCLCrashReporter runtimeLogPath];
        BOOL has = [[NSFileManager defaultManager] fileExistsAtPath:rt];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.crashNames = names;
            self.hasRuntime = has;
            [self.tableView reloadData];
        });
    });
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2 + (self.hasRuntime ? 1 : 0);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;          // 状态
    if (section == 1) return MAX(self.crashNames.count, 1); // 至少一行“暂无”
    return 1;                            // 运行时日志
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"上次退出状态";
    if (section == 1) return @"崩溃记录（ips）";
    return @"运行时日志";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"⚠️ SIGKILL、内存溢出(OOM/Jetsam) 以及 Mach-O 加载极早期崩溃不会产生 ips 日志，"
                "也无法被信号处理器捕获。若显示「疑似闪退」但无记录，多为上述情况，需用 sysdiagnose 进一步定位。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"dcl_cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (indexPath.section == 0) {
        // 状态
        if ([DCLCrashReporter firstLaunchEver]) {
            cell.textLabel.text = @"首次运行，暂无退出记录";
            cell.detailTextLabel.text = nil;
        } else if ([DCLCrashReporter lastExitWasAbnormal]) {
            cell.textLabel.text = @"上次退出：疑似闪退（无 ips 日志）";
            cell.detailTextLabel.text = @"进程未走正常终止流程（可能被 SIGKILL / OOM / 早期崩溃）";
        } else {
            cell.textLabel.text = @"上次退出：正常";
            NSDate *d = [DCLCrashReporter lastNormalExitDate];
            cell.detailTextLabel.text = d ? [NSString stringWithFormat:@"正常退出时间：%@", d] : nil;
        }
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1) {
        if (self.crashNames.count == 0) {
            cell.textLabel.text = @"（暂无崩溃记录）";
            cell.detailTextLabel.text = nil;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            NSString *name = self.crashNames[indexPath.row];
            cell.textLabel.text = name;
            cell.detailTextLabel.text = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else {
        cell.textLabel.text = @"plugin_runtime.log（stderr/stdout 重定向）";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"显示末尾 %lu KB",
                                     (unsigned long)(DCLMaxRuntimeLogTailBytes / 1024)];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && self.crashNames.count > 0) {
        [DCLCrashLogViewer presentDetailWithName:self.crashNames[indexPath.row] from:self];
    } else if (indexPath.section == 2) {
        [DCLCrashLogViewer presentRuntimeDetailFrom:self];
    }
}

#pragma mark - 工具栏动作

- (void)onClear:(id)sender {
    [DCLCrashLogViewer clearAll];
    [self reloadDataAsync];
}

- (void)onCopyAll:(id)sender {
    [DCLCrashLogViewer buildCombinedText:^(NSString *text) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (text.length == 0) {
                [self dcl_toast:@"没有可复制的日志"];
                return;
            }
            [UIPasteboard generalPasteboard].string = text;
            [self dcl_toast:[NSString stringWithFormat:@"已复制 %lu 字符", (unsigned long)text.length]];
        });
    }];
}

- (void)onExportAll:(id)sender {
    [DCLCrashLogViewer buildCombinedText:^(NSString *text) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (text.length == 0) { [self dcl_toast:@"没有可导出的日志"]; return; }
            NSString *dir = [DCLCrashReporter crashLogsDirectory];
            NSString *name = [NSString stringWithFormat:@"DCL_export_%lld.txt",
                              (long long)[NSDate date].timeIntervalSince1970];
            NSString *path = [dir stringByAppendingPathComponent:name];
            [text writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];

            NSURL *url = [NSURL fileURLWithPath:path];
            UIActivityViewController *avc =
                [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                applicationActivities:nil];
            if (avc.popoverPresentationController) {
                avc.popoverPresentationController.barButtonItem = sender;
            }
            [self presentViewController:avc animated:YES completion:nil];
        });
    }];
}

- (void)dcl_toast:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                             message:msg
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [a dismissViewControllerAnimated:YES completion:nil]; });
    }];
}

@end

#pragma mark - 公开接口 + 详情页

@implementation DCLCrashLogViewer

+ (NSArray<NSString *> *)sortedLogNames {
    NSString *dir = [DCLCrashReporter crashLogsDirectory];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *logs = [NSMutableArray array];
    for (NSString *f in files) {
        if ([f hasPrefix:@"crash_"]) [logs addObject:f];
    }
    [logs sortUsingSelector:@selector(compare:)];
    return logs;
}

+ (BOOL)hasLogs {
    return [self sortedLogNames].count > 0;
}

+ (void)present {
    UIViewController *top = dcl_current_top_vc();
    if (!top) return;
    @try {
        DCLLogMasterVC *master = [[DCLLogMasterVC alloc] init];
        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:master];
        nav.toolbarHidden = NO;
        [top presentViewController:nav animated:YES completion:nil];
    } @catch (id e) {
        (void)e;
    }
}

#pragma mark - 详情（后台读取后 push）

+ (void)presentDetailWithName:(NSString *)name from:(UIViewController *)top {
    NSString *dir = [DCLCrashReporter crashLogsDirectory];
    NSString *path = [dir stringByAppendingPathComponent:name];
    UIViewController *detail = [[UIViewController alloc] init];
    detail.title = name;
    detail.view.backgroundColor = [UIColor systemBackgroundColor];
    UITextView *tv = [[UITextView alloc] initWithFrame:detail.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    tv.textColor = [UIColor labelColor];
    tv.text = @"（读取中…）";
    [detail.view addSubview:tv];

    UIBarButtonItem *share = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:self
                             action:@selector(shareCurrent:)];
    share.accessibilityHint = path;
    detail.navigationItem.rightBarButtonItem = share;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:detail];
    [top presentViewController:nav animated:YES completion:nil];

    // 后台限制读取大小，避免大文件撑爆主线程/内存
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *content = [self dcl_readFileCapped:path maxBytes:DCLMaxCrashLogBytesForUI];
        dispatch_async(dispatch_get_main_queue(), ^{
            tv.text = content ?: @"(无法读取文件)";
        });
    });
}

+ (void)presentRuntimeDetailFrom:(UIViewController *)top {
    NSString *path = [DCLCrashReporter runtimeLogPath];
    UIViewController *detail = [[UIViewController alloc] init];
    detail.title = @"plugin_runtime.log";
    detail.view.backgroundColor = [UIColor systemBackgroundColor];
    UITextView *tv = [[UITextView alloc] initWithFrame:detail.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    tv.textColor = [UIColor labelColor];
    tv.text = @"（读取中…）";
    [detail.view addSubview:tv];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:detail];
    [top presentViewController:nav animated:YES completion:nil];

    // 只读取末尾，避免整文件载入
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *content = [self dcl_readFileTail:path maxBytes:DCLMaxRuntimeLogTailBytes];
        dispatch_async(dispatch_get_main_queue(), ^{
            tv.text = content ?: @"(无运行时日志 / 无法读取)";
        });
    });
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

#pragma mark - 清空 / 汇总

+ (void)clearAll {
    NSString *dir = [DCLCrashReporter crashLogsDirectory];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *f in files) {
        if ([f hasPrefix:@"crash_"] || [f isEqualToString:DCLRuntimeLogFileName]) {
            [[NSFileManager defaultManager]
                removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
        }
    }
}

// 汇总全部日志文本（状态 + 崩溃记录 + 运行时尾部），后台执行
+ (void)buildCombinedText:(void (^)(NSString *))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"===== DouyinCrashLogger 汇总 %@ =====\n", [NSDate date]];
        if ([DCLCrashReporter firstLaunchEver]) {
            [s appendString:@"上次退出状态：首次运行（无记录）\n"];
        } else if ([DCLCrashReporter lastExitWasAbnormal]) {
            [s appendString:@"上次退出状态：疑似闪退（无 ips 日志，可能 SIGKILL/OOM/早期崩溃）\n"];
        } else {
            [s appendString:@"上次退出状态：正常\n"];
        }
        [s appendString:@"\n"];

        NSString *dir = [DCLCrashReporter crashLogsDirectory];
        for (NSString *name in [self sortedLogNames]) {
            NSString *p = [dir stringByAppendingPathComponent:name];
            NSString *c = [self dcl_readFileCapped:p maxBytes:DCLMaxCrashLogBytesForUI];
            [s appendFormat:@"\n----- %@ -----\n%@\n", name, c ?: @"(读取失败)"];
        }

        NSString *rt = [DCLCrashReporter runtimeLogPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:rt]) {
            NSString *rtc = [self dcl_readFileTail:rt maxBytes:DCLMaxRuntimeLogTailBytes];
            [s appendFormat:@"\n----- plugin_runtime.log (tail) -----\n%@\n", rtc ?: @"(读取失败)"];
        }

        if (completion) completion(s);
    });
}

#pragma mark - 文件读取工具（限制大小 / 读尾部）

+ (NSString *)dcl_readFileCapped:(NSString *)path maxBytes:(NSUInteger)maxBytes {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        NSData *data;
        if (size > maxBytes) {
            // 仅读取头部 maxBytes，避免超大文件
            NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
            if (!fh) return nil;
            data = [fh readDataOfLength:maxBytes];
            [fh closeFile];
        } else {
            data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        }
        return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    } @catch (id e) {
        return nil;
    }
}

+ (NSString *)dcl_readFileTail:(NSString *)path maxBytes:(NSUInteger)maxBytes {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        if (size == 0) return @"(空文件)";
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!fh) return nil;
        unsigned long long start = size > maxBytes ? (size - maxBytes) : 0;
        [fh seekToOffset:start error:nil];
        NSData *data = [fh readDataToEndOfFile];
        [fh closeFile];
        return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    } @catch (id e) {
        return nil;
    }
}

@end
