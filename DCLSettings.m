//
//  DCLSettings.m
//  DouyinCrashLogger
//
//  设置入口 + 设置面板。本文件是唯一与「App 内 UI」相关的代码：
//    · DCLSettings         —— 向 DYStorage 运行时注册入口、并 present 面板；
//    · DCLSettingsViewController —— 纯展示面板（状态 / 切换方案 / 刷新 / 导出 / 清空）。
//
//  关于「不链接 DYStorage」：下面声明的 DYStorageManager 接口只是运行时契约的
//  镜像，本插件从不 #import 它的头、也不在链接期引用它的符号。取类、取单例、
//  调注册方法全走 NSClassFromString / performSelector 风格（此处直接声明接口后
//  正常发消息，编译器只需签名、运行期方法由真实类提供）。DYStorage 缺席时
//  NSClassFromString 返回 Nil，整段注册直接跳过，本插件保持纯后台运行。
//

#import "DCLSettings.h"

#import "DCLConfig.h"
#import "DCLCrashReporter.h"
#import "DCLConstants.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---- 与 DYStorage 运行时的契约（仅声明，不链接）----
typedef void (^DYStorageAction)(void);

@interface DYStorageManager : NSObject
+ (instancetype)sharedManager;
- (BOOL)registerActionWithIdentifier:(NSString *)identifier
                               title:(NSString *)title
                             version:(NSString *)version
                              action:(DYStorageAction)action;
@end

static NSString *const kDCLStorageIdentifier = @"com.awsd244292.douyincrashlogger";
static NSString *const kDCLStorageEntryTitle = @"DCL 崩溃日志";

// 前置声明必须带父类与成员属性 —— 光给 @class 只能声明「有这么个类」，
// 不能继承、不能定义类扩展、不能 @implementation（编译器会报 root class / 
// unknown class）。presentSettings 定义在本文件上半部，需在它之前看到完整接口。
@interface DCLSettingsViewController : UIViewController
@property (nonatomic, strong) UITextView *statusView;
@property (nonatomic, strong) UIButton *profileButton;
@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, strong) UIButton *exportButton;
@property (nonatomic, strong) UIButton *clearButton;
@end

#pragma mark - DCLSettings

@implementation DCLSettings

+ (void)registerEntry {
    @try {
        // 1) DYStorage 未安装 → Nil，自然跳过。多插件共存场景下本插件无需依赖它。
        Class mgrClass = NSClassFromString(@"DYStorageManager");
        if (mgrClass == Nil) return;
        if (![mgrClass respondsToSelector:@selector(sharedManager)]) return;

        // 2) 取单例。DYStorage 注入顺序在我们之前，此时 sharedManager 必已就绪。
        id mgr = [mgrClass sharedManager];
        if (mgr == nil) return;

        // 3) 注册「点击时展示本插件设置页」的 block。版本号跟随 control，方便排查。
        SEL sel = @selector(registerActionWithIdentifier:title:version:action:);
        if (![mgr respondsToSelector:sel]) return;

        [mgr registerActionWithIdentifier:kDCLStorageIdentifier
                                    title:kDCLStorageEntryTitle
                                  version:DCLPluginVersion
                                   action:^{
            // DYStorage 的点击回调线程不确定，统一切回主线程再 present。
            dispatch_async(dispatch_get_main_queue(), ^{
                [DCLSettings presentSettings];
            });
        }];
    } @catch (id e) {
        (void)e;   // 注册失败不影响取证主功能，静默吞掉
    }
}

/// 找当前 keyWindow 的最上层已 present 的 VC（兼容 iOS 13+ 多 scene）。
+ (nullable UIViewController *)topViewController {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
        }
        if (!window) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                NSArray<UIWindow *> *ws = ((UIWindowScene *)scene).windows;
                if (ws.count) { window = ws.firstObject; break; }
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        window = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    }
    if (!window) return nil;

    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

+ (void)presentSettings {
    @try {
        UIViewController *top = [self topViewController];
        if (!top) return;

        DCLSettingsViewController *panel = [[DCLSettingsViewController alloc] init];
        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:panel];
        if (@available(iOS 13.0, *)) {
            nav.modalPresentationStyle = UIModalPresentationPageSheet;
        }
        [top presentViewController:nav animated:YES completion:nil];
    } @catch (id e) {
        (void)e;
    }
}

@end

#pragma mark - DCLSettingsViewController

// 属性已在文件顶部的前置声明中给出，此处不再重复类扩展。

@implementation DCLSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = kDCLStorageEntryTitle;
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(dismissSelf)];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    self.statusView = [[UITextView alloc] init];
    self.statusView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusView.editable = NO;
    self.statusView.selectable = YES;
    self.statusView.font = [UIFont systemFontOfSize:13];
    self.statusView.textColor = [UIColor labelColor];
    self.statusView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.statusView.layer.cornerRadius = 10;
    self.statusView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);

    self.profileButton = [self makeButton:@"切换采集方案（safe ⇄ full）"
                                   action:@selector(toggleProfile)];
    self.refreshButton = [self makeButton:@"刷新 latest.log 快照"
                                   action:@selector(refreshSnapshot)];
    self.exportButton  = [self makeButton:@"导出日志目录"
                                   action:@selector(exportLogs)];
    self.clearButton   = [self makeButton:@"清空取证日志"
                                   action:@selector(clearLogs)];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.statusView, self.profileButton, self.refreshButton,
        self.exportButton, self.clearButton
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    UILayoutGuide *content = scroll.contentLayoutGuide;
    UILayoutGuide *frame = scroll.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        // 用 frameLayoutGuide 锁宽，避免 stack 在 scroll 内被无限拉伸
        [stack.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-32],
    ]];
    [self.statusView.heightAnchor constraintEqualToConstant:220].active = YES;

    [self refreshStatus];
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    b.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    b.layer.cornerRadius = 10;
    b.contentEdgeInsets = UIEdgeInsetsMake(12, 12, 12, 12);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)refreshStatus {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"DouyinCrashLogger · 崩溃取证\n"];
    [s appendFormat:@"版本：%@\n", DCLPluginVersion];
    [s appendFormat:@"当前采集方案：%@\n", [DCLConfig profileDisplayName]];
    [s appendFormat:@"上次退出性质：%@\n", [DCLCrashReporter previousExitDescription]];
    [s appendFormat:@"日志目录：%@\n", [DCLCrashReporter crashLogsDirectory]];
    self.statusView.text = s;
}

- (void)toggleProfile {
    [DCLConfig toggleProfile];
    [self refreshStatus];
}

- (void)refreshSnapshot {
    [DCLCrashReporter writeLatestLogWithReason:@"设置页手动刷新"];
    [self refreshStatus];
}

- (void)exportLogs {
    NSString *dir = [DCLCrashReporter crashLogsDirectory];
    NSURL *url = [NSURL fileURLWithPath:dir isDirectory:YES];
    UIActivityViewController *avc =
        [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                          applicationActivities:nil];
    [self presentViewController:avc animated:YES completion:nil];
}

- (void)clearLogs {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"清空取证日志"
                                           message:@"将删除所有崩溃报告与历史运行日志（保留 latest.log 快照），此操作不可撤销。"
                                    preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction * _Nonnull action) {
            [self _doClearLogs];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_doClearLogs {
    NSString *dir = [DCLCrashReporter crashLogsDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator<NSString *> *en = [fm enumeratorAtPath:dir];
    for (NSString *name in en) {
        if ([name hasPrefix:@"crash_"] || [name hasPrefix:@"plugin_runtime"]) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
        }
    }
    [DCLCrashReporter writeLatestLogWithReason:@"设置页手动清空后重建快照"];
    [self refreshStatus];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
