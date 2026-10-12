//
//  DCLHotSwitch.m
//  DouyinCrashLogger
//
//  热切换：摇一摇 → 翻转采集方案（safe ↔ full）→ 顶部轻提示 + 三连触感反馈。
//
//  【为什么从三指改成摇一摇】
//  真机上三指完全点不出来，原因不在反馈而在「抢不到事件」：抖音几乎所有页面
//  都挂着自己的手势识别器（上下滑切视频、双击点赞、长按菜单），三根指头一按
//  下去，事件先被宿主的手势吃掉，压根轮不到我们做判定。摇一摇不参与任何视图
//  层级和手势竞争 —— 系统把 motion 事件直接投递到 UIApplication，是最稳的
//  物理入口，也不要求某个 view 成为 first responder。
//
//  【为什么仍在 sendEvent: 上做检测】
//  常见写法是 hook 某个 UIResponder 的 motionEnded:withEvent:，但那要求对应的
//  responder 正好在响应链上。UIApplication sendEvent: 是所有事件的唯一总入口，
//  且它的投递「与宿主是否消费摇一摇无关」—— 即便抖音自己重写了 motionEnded
//  把摇一摇吞了，我们照样能在分发前看到这次事件。这是选它的决定性理由。
//
//  设计铁律（沿用三轮审查定下的规矩）：
//  1) 独立于两档采集始终安装 —— 否则 safe 档下用户摇不出入口，就永远切不到 full。
//  2) 绝不吞事件：钩子体第一步就透传原实现，检测与翻转都在透传之后。
//  3) 与 DCLPlaybackTracer 的 sendEvent: 钩子共存：双方都取原实现做链式透传，
//     先装的后装各自只包一层，不会互相覆盖也不会自环（见 DCLReplaceInstanceMethod 守卫）。
//  4) 提示走独立 UIWindow 且 userInteractionEnabled = NO —— 绝不拦截宿主触摸，
//     也不往宿主的视图层级里塞东西，避免和抖音自己的 HUD 打架。
//  5) 每次翻转都往 runtime 日志留痕：即便提示没弹出来、设备也关了震动，
//     「到底翻没翻」依然一眼可查。
//

#import "DCLHotSwitch.h"
#import "DCLConfig.h"
#import "DCLSupport.h"
#import "DCLLogger.h"

#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>

/// 去抖：一次摇动动作里系统会投递多次 motion 事件，这段时间内只认第一次
static const uint64_t DCL_HS_DEBOUNCE_US = 1200000ULL;     // 1.2s
/// 三下触感之间的间隔
static const int64_t DCL_HS_BUZZ_GAP_MS = 180;
/// 提示停留时长（秒）
static const NSTimeInterval DCL_HS_TOAST_STAY = 1.8;

#pragma mark - 状态

static void (*dcl_hs_orig_sendEvent)(id, SEL, id) = NULL;
static volatile int32_t dcl_hs_installed = 0;
static volatile int32_t dcl_hs_install_succeeded = 0;
static NSString *dcl_hs_install_target = @"(not installed)";

static _Atomic(uint64_t) dcl_hs_last_trigger = 0;

/// 当前正在显示的提示窗口（强引用：ARC 下文件作用域指针默认 strong，
/// 必须持有到动画结束，否则 Toast 刚淡入就被释放、一闪而过）。
static UIWindow *dcl_hs_toast_window = nil;

#pragma mark - 反馈：三连触感

/// 三连震 / 三连触感。
/// 优先用 UIImpactFeedbackGenerator：抖音这类 App 里它比 AudioServices 的那声
/// 「老式蜂鸣」更可靠、辨识度也高；取不到该类时退到 AudioServices。
static void dcl_hs_feedback(void) {
    dispatch_block_t buzzLegacy = ^{
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    };
    dispatch_block_t buzzHaptic = ^{
        UIImpactFeedbackGenerator *gen = nil;
        @try {
            gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [gen prepare];
        } @catch (id e) {
            gen = nil;
        }
        if (!gen) { buzzLegacy(); return; }
        for (int i = 0; i < 3; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)i * DCL_HS_BUZZ_GAP_MS * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (i > 0) [gen prepare];
                    [gen impactOccurred];
                } @catch (id e) {
                    buzzLegacy();
                }
            });
        }
    };

    dispatch_async(dispatch_get_main_queue(), buzzHaptic);
}

#pragma mark - 提示（切换后的可见反馈）

/// 造一枚独立的提示窗口。
/// iOS 13 起 UIWindow 必须挂在某个 UIWindowScene 上才正常显示，故优先取前台活跃的
/// scene；取不到（理论上的老系统 / 极端场景）再退回按屏幕 bounds 创建。
static UIWindow *dcl_hs_make_toast_window(void) {
    UIWindow *win = nil;
    @try {
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]] &&
                    s.activationState == UISceneActivationStateForegroundActive) {
                    scene = (UIWindowScene *)s;
                    break;
                }
            }
            if (scene) win = [[UIWindow alloc] initWithWindowScene:scene];
        }
    } @catch (id e) {
        win = nil;
    }
    if (!win) win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    return win;
}

/// 顶部轻提示。全程主线程、全程 @try 包裹 —— 提示只是锦上添花，
/// 绝不允许因为画个框把宿主搞崩。
static void dcl_hs_show_toast(NSString *title, NSString *subtitle) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 先撤掉上一枚：连续摇动不该堆成一串窗口
            if (dcl_hs_toast_window) {
                dcl_hs_toast_window.hidden = YES;
                dcl_hs_toast_window = nil;
            }

            UIWindow *win = dcl_hs_make_toast_window();
            if (!win) return;

            CGRect screen = [UIScreen mainScreen].bounds;
            win.frame = screen;
            win.windowLevel = UIWindowLevelAlert + 1.0;
            win.backgroundColor = [UIColor clearColor];
            win.userInteractionEnabled = NO;   // 铁律：绝不拦截宿主触摸
            win.hidden = NO;

            UIFont *tFont = [UIFont boldSystemFontOfSize:16.0];
            UIFont *sFont = [UIFont systemFontOfSize:12.0];
            CGFloat maxW = CGRectGetWidth(screen) - 64.0;

            CGRect tRect = [title boundingRectWithSize:CGSizeMake(maxW, 120.0)
                                              options:NSStringDrawingUsesLineFragmentOrigin
                                           attributes:@{NSFontAttributeName: tFont}
                                              context:nil];
            CGRect sRect = [subtitle boundingRectWithSize:CGSizeMake(maxW, 120.0)
                                                  options:NSStringDrawingUsesLineFragmentOrigin
                                               attributes:@{NSFontAttributeName: sFont}
                                                  context:nil];

            CGFloat boxW = ceil(MAX(CGRectGetWidth(tRect), CGRectGetWidth(sRect))) + 36.0;
            CGFloat boxH = ceil(CGRectGetHeight(tRect) + CGRectGetHeight(sRect)) + 30.0;
            UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, boxW, boxH)];
            box.center = CGPointMake(CGRectGetMidX(screen), CGRectGetHeight(screen) * 0.26);
            box.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.86];
            box.layer.cornerRadius = 14.0;
            box.layer.masksToBounds = YES;
            box.alpha = 0.0;

            UILabel *tl = [[UILabel alloc] initWithFrame:
                           CGRectMake(18.0, 14.0,
                                      ceil(CGRectGetWidth(tRect)), ceil(CGRectGetHeight(tRect)))];
            tl.text = title;
            tl.textColor = [UIColor whiteColor];
            tl.font = tFont;
            tl.textAlignment = NSTextAlignmentCenter;
            tl.numberOfLines = 0;

            UILabel *sl = [[UILabel alloc] initWithFrame:
                           CGRectMake(18.0, CGRectGetMaxY(tl.frame) + 4.0,
                                      ceil(CGRectGetWidth(sRect)), ceil(CGRectGetHeight(sRect)))];
            sl.text = subtitle;
            sl.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.80];
            sl.font = sFont;
            sl.textAlignment = NSTextAlignmentCenter;
            sl.numberOfLines = 0;

            [box addSubview:tl];
            [box addSubview:sl];
            [win addSubview:box];
            dcl_hs_toast_window = win;

            [UIView animateWithDuration:0.18
                                  delay:0
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{ box.alpha = 1.0; }
                             completion:^(BOOL finished) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(DCL_HS_TOAST_STAY * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:0.35
                                          delay:0
                                        options:UIViewAnimationOptionCurveEaseIn
                                     animations:^{ box.alpha = 0.0; }
                                     completion:^(BOOL f2) {
                        @try {
                            win.hidden = YES;
                            // 只有「自己仍是当前那一枚」时才清空，避免误撤后起的新提示
                            if (dcl_hs_toast_window == win) dcl_hs_toast_window = nil;
                        } @catch (id e) {
                            (void)e;
                        }
                    }];
                });
            }];
        } @catch (id e) {
            (void)e;
        }
    });
}

/// 把翻转后的档位「说清楚」：用户要的是知道现在到底是哪一档、多了什么能力。
static void dcl_hs_announce(DCLCaptureProfile profile) {
    NSString *title = nil, *subtitle = nil;
    if (profile == DCLCaptureProfileFull) {
        title = @"采集档位：完整采集";
        subtitle = @"播放/触摸归因 · 卡死栈取证 已开启";
    } else {
        title = @"采集档位：基础采集";
        subtitle = @"仅崩溃与退出取证 · 零 hook";
    }
    dcl_hs_show_toast(title, subtitle);
}

#pragma mark - 摇一摇判定

/// 这次事件是不是一次「摇一摇」。
/// 只看 type 与 subtype，不碰 responder 链 —— 与宿主是否消费摇一摇无关。
static BOOL dcl_hs_is_shake(UIEvent *event) {
    if (!event) return NO;
    if ([event type] != UIEventTypeMotion) return NO;
    if ([event subtype] != UIEventSubtypeMotionShake) return NO;
    return YES;
}

#pragma mark - 钩子体（原样透传，零吞事件）

static void dcl_hs_sendEvent(id self, SEL _cmd, UIEvent *event) {
    static __thread int in_hook = 0;
    if (in_hook) {
        if (dcl_hs_orig_sendEvent) dcl_hs_orig_sendEvent(self, _cmd, event);
        return;
    }
    in_hook = 1;

    // 铁律：先透传，绝不吞事件
    if (dcl_hs_orig_sendEvent) dcl_hs_orig_sendEvent(self, _cmd, event);

    @try {
        if (dcl_hs_is_shake(event)) {
            uint64_t now = DCLNowUs();
            uint64_t last = atomic_load(&dcl_hs_last_trigger);
            if (now - last > DCL_HS_DEBOUNCE_US) {
                atomic_store(&dcl_hs_last_trigger, now);

                DCLCaptureProfile before = [DCLConfig captureProfile];
                [DCLConfig toggleProfile];
                DCLCaptureProfile after = [DCLConfig captureProfile];

                dcl_hs_feedback();
                dcl_hs_announce(after);

                // 留痕：提示没弹出来或关了震动时，这是唯一能确认「确实翻过了」的出口。
                // 注意 appendRuntimeLine 会把非 ASCII 转义，故日志行一律英文。
                [DCLLogger appendRuntimeLine:
                 [NSString stringWithFormat:@"[DCL] hotswitch: shake -> %@ -> %@ (hooks %@)",
                  (before == DCLCaptureProfileFull ? @"full" : @"safe"),
                  (after == DCLCaptureProfileFull ? @"full" : @"safe"),
                  (after == DCLCaptureProfileFull ? @"ON" : @"OFF")]];
            }
        }
    } @catch (id e) {
        (void)e;
    } @finally {
        in_hook = 0;
    }
}

#pragma mark - 挂载

@implementation DCLHotSwitch

+ (BOOL)isInstalled {
    return dcl_hs_installed != 0 && dcl_hs_install_succeeded != 0;
}

+ (NSString *)installStateDescription {
    if (dcl_hs_installed == 0) return @"未安装（尚未到延迟安装时机）";
    if (dcl_hs_install_succeeded == 0) return @"安装失败：宿主未提供可钩的事件入口";
    return [NSString stringWithFormat:@"已安装：%@ sendEvent: 旁路监听（摇一摇翻转 safe/full）",
            dcl_hs_install_target];
}

/// 摇一摇入口的对外说明（供开关文件、日志头部复用，避免各处各写一套文案）
+ (NSString *)triggerGuide {
    return @"摇一摇切换采集档位（无需改文件、无需重启）";
}

+ (void)install {
    if (__sync_fetch_and_or(&dcl_hs_installed, 1)) return;
    @try {
        SEL selEvent = @selector(sendEvent:);

        // 第一选择：UIApplication sendEvent: —— 所有事件（含 motion）的唯一总入口。
        //
        // 注意取哪一层：不是无脑取 UIApplication 本类，而是从「当前 App 实例」向上找
        // 真正实现这个方法的那一层（宿主可能用自定义 UIApplication 子类重写了它）。
        // 详见 DCLMostDerivedMethodOwner 的说明。
        id app = nil;
        Class appRootCls = NSClassFromString(@"UIApplication");
        if (appRootCls &&
            [appRootCls respondsToSelector:@selector(sharedApplication)]) {
            app = [appRootCls sharedApplication];
        }
        Class targetCls = DCLMostDerivedMethodOwner(app, selEvent, appRootCls) ?: appRootCls;
        if (targetCls &&
            DCLReplaceInstanceMethod(targetCls, selEvent, NULL,
                                     (void *)dcl_hs_sendEvent,
                                     (void **)&dcl_hs_orig_sendEvent)) {
            dcl_hs_install_target = NSStringFromClass(targetCls);
            dcl_hs_install_succeeded = 1;
            [DCLLogger appendRuntimeLine:
             [NSString stringWithFormat:@"[DCL] hotswitch: installed sendEvent: hook on %@",
              NSStringFromClass(targetCls)]];
            return;
        }

        // 兜底：拿不到 UIApplication 实例时退回到 UIWindow（每个窗口都会经手事件，
        // 覆盖比 UIApplication 略窄 —— motion 未必投递到 window，但总比完全没有监听强）。
        Class winCls = NSClassFromString(@"UIWindow");
        if (winCls) {
            if (DCLReplaceInstanceMethod(winCls, selEvent, NULL,
                                         (void *)dcl_hs_sendEvent,
                                         (void **)&dcl_hs_orig_sendEvent)) {
                dcl_hs_install_target = @"UIWindow";
                dcl_hs_install_succeeded = 1;
                [DCLLogger appendRuntimeLine:@"[DCL] hotswitch: installed on UIWindow sendEvent:"];
                return;
            }
        }
        // 两条路都没挂上：如实记录，健康自检里会显示「安装失败」，不静默假成功
        NSString *why = @"[DCL] hotswitch: INSTALL FAILED (no usable sendEvent: owner)";
        fprintf(stderr, "%s\n", [why UTF8String]);
        [DCLLogger appendRuntimeLine:why];
    } @catch (id e) {
        (void)e;
    }
}

@end
