//
//  DCLMain.m
//  DouyinCrashLogger
//
//  入口设计：
//  1) 崩溃捕获（signal / UncaughtException）必须在 dylib 加载早期安装，不能延迟，
//     否则启动阶段的崩溃抓不到。
//  2) UI 入口（设置页按钮 + 摇一摇）延迟到主 runloop 起来后再交换，遵循“加载阶段
//     不早 hook / 不早执行业务逻辑”的防闪退原则。
//
//  防闪退要点（遵循注入规范）：
//  - 不 Hook 抖音任何私有类/方法；只交换 UIViewController（系统公开类）的
//    -viewWillAppear:，再用 title 识别“设置”页，最大限度降低与抖音内部实现的耦合。
//  - 进程过滤（bundle id）、类/方法存在性检查、isKindOfClass、判空、主线程、@try/@catch。
//  - 全程 Objective-C runtime 原生 API（method_setImplementation），不依赖 CydiaSubstrate。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "DCLCrashReporter.h"
#import "DCLCrashLogViewer.h"
#import "DCLConstants.h"

#pragma mark - 入口按钮的 target（全局单例，避免强引用 VC 造成无法释放）

@interface DCLLogOpener : NSObject
- (void)dcl_openCrashLogs:(id)sender;
@end
@implementation DCLLogOpener
- (void)dcl_openCrashLogs:(id)sender {
    [DCLCrashLogViewer present];
}
@end
static DCLLogOpener *g_opener = nil;

#pragma mark - 原始实现指针

static void (*orig_viewWillAppear)(UIViewController *, SEL, BOOL) = NULL;
static void (*orig_sendEvent)(UIApplication *, SEL, UIEvent *) = NULL;

static const void *kDCLButtonAdded = &kDCLButtonAdded;

#pragma mark - 防护 / 识别

static BOOL dcl_is_douyin(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    return [bid isEqualToString:@"com.ss.iphone.ugc.Aweme"] ||
           [bid isEqualToString:@"com.ss.iphone.ugc.Sharee"];
}

// 通过 title 命中“设置”页，跨抖音版本兼容（只要设置页标题是“设置 / Settings”）。
// 不依赖任何抖音私有类名，避免版本迭代改名导致 hook 失败或闪退。
static BOOL dcl_is_settings_vc(UIViewController *vc) {
    if (![vc isKindOfClass:[UIViewController class]]) return NO;
    NSString *title = vc.title ?: vc.navigationItem.title;
    if ([title isEqualToString:@"设置"] || [title isEqualToString:@"Settings"]) return YES;
    return NO;
}

// 给设置页右上角追加“📋 崩溃日志”按钮（保留原有 right items，不覆盖抖音自身按钮）
static void dcl_ensure_entry_button(UIViewController *vc) {
    @try {
        if (!vc.navigationItem) return;
        if (objc_getAssociatedObject(vc, kDCLButtonAdded)) return; // 已加过，防重复添加
        objc_setAssociatedObject(vc, kDCLButtonAdded, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (!g_opener) g_opener = [[DCLLogOpener alloc] init];
        UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"📋 崩溃日志"
                                                                style:UIBarButtonItemStylePlain
                                                               target:g_opener
                                                               action:@selector(dcl_openCrashLogs:)];
        NSMutableArray *items = [NSMutableArray array];
        if (vc.navigationItem.rightBarButtonItem) {
            [items addObject:vc.navigationItem.rightBarButtonItem];
        }
        [items addObjectsFromArray:vc.navigationItem.rightBarButtonItems ?: @[]];
        [items addObject:item];
        vc.navigationItem.rightBarButtonItems = items;
    } @catch (id e) {
        (void)e;
    }
}

#pragma mark - 交换实现

static void dcl_viewWillAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_viewWillAppear) orig_viewWillAppear(self, _cmd, animated);
    @try {
        // 进程过滤 + 仅“设置”页处理。UI 操作放到主线程并稍延迟，
        // 避开导航栏布局尚未完成的窗口期。
        if (dcl_is_douyin() && dcl_is_settings_vc(self)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { dcl_ensure_entry_button(self); } @catch (id e) {}
            });
        }
    } @catch (id e) {
        (void)e;
    }
}

static void dcl_sendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if (event && event.type == UIEventTypeMotion &&
        event.subtype == UIEventSubtypeMotionShake) {
        static NSTimeInterval lastTrigger = 0;
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if (now - lastTrigger > DCLShakeDebounceInterval) {
            lastTrigger = now;
            dispatch_async(dispatch_get_main_queue(), ^{
                [DCLCrashLogViewer present];
            });
        }
    }
    if (orig_sendEvent) {
        orig_sendEvent(self, _cmd, event);
    }
}

#pragma mark - 入口注册（延迟到主 runloop 后执行，避免注入早期闪退）

static void dcl_register_ui_entry(void) {
    @try {
        // 设置页入口：交换 UIViewController -viewWillAppear:（系统公开类，非抖音私有）
        Class vcCls = [UIViewController class];
        SEL vwa = @selector(viewWillAppear:);
        Method m = class_getInstanceMethod(vcCls, vwa);
        if (m) {
            orig_viewWillAppear = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)dcl_viewWillAppear);
        }
        // 摇一摇入口（备选）：交换 UIApplication -sendEvent:
        Class appCls = [UIApplication class];
        SEL se = @selector(sendEvent:);
        Method m2 = class_getInstanceMethod(appCls, se);
        if (m2) {
            orig_sendEvent = (void *)method_getImplementation(m2);
            method_setImplementation(m2, (IMP)dcl_sendEvent);
        }
        if (!g_opener) g_opener = [[DCLLogOpener alloc] init];
    } @catch (id e) {
        (void)e;
    }
}

__attribute__((constructor)) static void dcl_entry(void) {
    // 1) 崩溃捕获必须尽早安装（不能延迟！否则启动早期崩溃抓不到）
    [DCLCrashReporter install];
    [DCLCrashReporter cleanupOldLogs];

    // 2) UI 入口延迟 1s，等 App 主 runloop 跑起来、视图引擎就绪后再交换，
    //    避免注入早期直接闪退。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        dcl_register_ui_entry();
    });
}
