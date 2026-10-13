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
#import "DCLPlaybackTracer.h"
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
- (BOOL)registerControllerWithIdentifier:(NSString *)identifier
                                   title:(NSString *)title
                                 version:(NSString *)version
                              controller:(NSString *)controllerClassName;
@end

static NSString *const kDCLStorageIdentifier = @"com.awsd244292.douyincrashlogger";
static NSString *const kDCLStorageEntryTitle = @"DCL 崩溃日志";

// 前置声明必须带父类与成员属性 —— 光给 @class 只能声明「有这么个类」，
// 不能继承、不能定义类扩展、不能 @implementation（编译器会报 root class / 
// unknown class）。presentSettings 定义在本文件上半部，需在它之前看到完整接口。
@interface DCLSettingsViewController : UIViewController
@property (nonatomic, strong) UITextView *statusView;
@property (nonatomic, strong) UISwitch *hookSwitch;
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

        // 3) 优先 registerController：把设置页 VC 类名交给 DYStorage 统一渲染跳转
        //    （push 进其设置页导航栈 / 包进全屏 modal present），本插件不再自 present，
        //    更贴合「统一渲染」设计，也避免自己 present 与 DYStorage 导航栈打架。
        SEL selCtl = @selector(registerControllerWithIdentifier:title:version:controller:);
        if ([mgr respondsToSelector:selCtl]) {
            [mgr registerControllerWithIdentifier:kDCLStorageIdentifier
                                           title:kDCLStorageEntryTitle
                                         version:DCLPluginVersion
                                      controller:NSStringFromClass([DCLSettingsViewController class])];
            return;
        }

        // 4) 兜底 registerAction：旧版 DYStorage 无 registerController 时，注册一个
        //    点击回调 block，由 DYStorage 回调本插件后再自 present（与改造前行为一致）。
        SEL selAct = @selector(registerActionWithIdentifier:title:version:action:);
        if (![mgr respondsToSelector:selAct]) return;
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

    // 显式 Hook 开关行：开 = full（Hook 全开）/ 关 = safe（零 Hook）。
    // 这是「hook ⇄ 0hook」的直观入口，与摇一摇、capture_mode.txt 三选一等效。
    self.hookSwitch = [[UISwitch alloc] init];
    self.hookSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [self.hookSwitch addTarget:self
                        action:@selector(onHookChanged)
              forControlEvents:UIControlEventValueChanged];
    UIView *hookRow = [self switchRowWithTitle:@"方法交换（Hook）" control:self.hookSwitch];

    self.refreshButton = [self makeButton:@"刷新 latest.log 快照"
                                   action:@selector(refreshSnapshot)];
    self.exportButton  = [self makeButton:@"导出日志目录"
                                   action:@selector(exportLogs)];
    self.clearButton   = [self makeButton:@"清空取证日志"
                                   action:@selector(clearLogs)];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.statusView, hookRow, self.refreshButton,
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

- (UIView *)switchRowWithTitle:(NSString *)title control:(UISwitch *)sw {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    row.layer.cornerRadius = 10;

    UILabel *lab = [[UILabel alloc] init];
    lab.translatesAutoresizingMaskIntoConstraints = NO;
    lab.text = title;
    lab.font = [UIFont systemFontOfSize:15];
    lab.textColor = [UIColor labelColor];

    [row addSubview:lab];
    [row addSubview:sw];
    [NSLayoutConstraint activateConstraints:@[
        [lab.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [lab.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintEqualToConstant:48],
    ]];
    return row;
}

- (void)refreshStatus {
    BOOL hooksOn = [DCLConfig hooksEnabled];
    self.hookSwitch.on = hooksOn;

    NSMutableString *s = [NSMutableString string];
    [s appendString:@"DouyinCrashLogger · 崩溃取证\n"];
    [s appendFormat:@"版本：%@\n", DCLPluginVersion];
    [s appendFormat:@"采集方案：%@\n", [DCLConfig profileDisplayName]];
    [s appendFormat:@"方法交换（Hook）：%@\n", hooksOn ? @"开启（full）" : @"关闭（safe · 零 hook）"];

    // 配置期望 vs 运行时已挂载：讲清「配置已改，但当前进程是否已换」的差异，
    // 避免用户以为「切了开关 Hook 就立刻增减」——方法交换在启动早期装一次。
    NSUInteger hooked = [DCLPlaybackTracer hookedCount];
    if (hooksOn && hooked == 0) {
        [s appendString:@"⚠️ 当前进程未挂载 Hook（本次启动为零 Hook），重启抖音后开启完全生效\n"];
    } else if (!hooksOn && hooked > 0) {
        [s appendString:@"⚠️ 当前进程 Hook 仍在运行（本次启动为 full），重启抖音后关闭\n"];
    } else {
        [s appendFormat:@"运行时 Hook 状态：已挂载 %lu 处（与配置一致）\n", (unsigned long)hooked];
    }

    [s appendFormat:@"上次退出性质：%@\n", [DCLCrashReporter previousExitDescription]];
    [s appendFormat:@"日志目录：%@\n", [DCLCrashReporter crashLogsDirectory]];
    [s appendString:@"\n提示：摇一摇也可快速切换档位；切换后重启抖音完全生效"];
    self.statusView.text = s;
}

/// Hook 开关拨动：直接翻转 safe/full 档位。
/// 诚实告知：方法交换在抖音启动早期一次性安装，本会话即时生效的是「配置 + 日志显示」，
/// 真正的 Hook 增减要等下次启动抖音重新评估（详见 DCLMain 延迟安装分支）。
- (void)onHookChanged {
    BOOL on = self.hookSwitch.on;
    [DCLConfig setProfile: on ? DCLCaptureProfileFull : DCLCaptureProfileSafe];
    [self refreshStatus];

    NSString *title = on ? @"已切换到 Hook 全开（full）" : @"已切换到 零 Hook（safe）";
    NSString *msg = @"采集档位已保存。Hook 在抖音启动早期一次性安装，本会话即时生效的是「配置与日志显示」；"
                    "Hook 实际增减将在「下次启动抖音」时完全切换。";
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                           message:msg
                                    preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
    // 入口通道（Tweak.xm DYStoragePresentController）保证我们的 VC 永远在导航栈内，
    // 分两种落点，关闭逻辑必须兼顾：
    //   · Case A：顶层 VC 自带 nav → pushViewController，本 VC 是栈内非根 → pop 返回；
    //   · Case B：顶层 VC 无 nav → 包一层新 UINavigationController 全屏 modal present，
    //     本 VC 是「新 nav 的栈底」。此时 self.presentingViewController 为 nil、
    //     self.navigationController 虽存在却不可 pop（空操作），必须沿 nav 的
    //     presentingViewController 把最外层整层 dismiss 掉。
    UINavigationController *nav = self.navigationController;
    if (nav && nav.viewControllers.firstObject != self) {
        [nav popViewControllerAnimated:YES];
    } else if (nav.presentingViewController) {
        [nav.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

@end
