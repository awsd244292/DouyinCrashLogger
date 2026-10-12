//
//  DCLHotSwitch.m
//  DouyinCrashLogger
//
//  热切换：三指轻点 → 翻转采集方案（safe ↔ full）→ 震 3 下反馈。
//
//  【本次为什么重写】真机上一按三指毫无反应、也没震动。根因不在反馈，而在监听点：
//  旧实现把钩子挂在 UIView「本类自有」的 touchesEnded:withEvent: 上，并要求本类
//  必须自己实现该方法才算挂成功。可 UIKit 里 UIControl / UIWindow / 各类容器视图
//  几乎都重写了 touchesEnded:withEvent:，宿主触摸最终落到的视图绝大多数是子类实例，
//  走的是子类实现 —— 我们等于在一个没人经过的路口蹲了三个月。
//
//  正解：挂在事件唯一总入口 UIApplication sendEvent:（UIWindow 同名方法兜底），
//  所有触摸、无论最终落到哪个视图，都必然先从这里过一遍。
//
//  设计要点（沿用三轮审查定下的铁律）：
//  1) 独立于两档采集始终安装 —— 否则 safe 档下用户点不出入口，就永远切不到 full。
//  2) 绝不吞事件：钩子体第一步就透传，检测与翻转都在透传之后。
//  3) 与 DCLPlaybackTracer 的 sendEvent: 钩子共存：双方都取原实现做链式透传，
//     先装的后装各自只包一层，不会互相覆盖也不会形成自环（见 DCLReplaceInstanceMethod 守卫）。
//  4) 手势判定用事件流水做状态机，不要求三指「同一帧」同时抬起 —— 真手指做不到那么齐。
//  5) 每次翻转都往 runtime 日志留痕：即便设备关了震动，「有没有生效」也一眼可查。
//

#import "DCLHotSwitch.h"
#import "DCLConfig.h"
#import "DCLSupport.h"
#import "DCLLogger.h"

#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>

/// 判定所需手指数
static const NSUInteger DCL_HS_FINGERS = 3;
/// 去抖：一次触发后这段时间内不再响应
static const uint64_t DCL_HS_DEBOUNCE_US = 800000ULL;      // 800ms
/// 手势最长时间：三指按住超过这么久再抬起，按拖拽处理，不判为轻点
static const uint64_t DCL_HS_MAX_GESTURE_US = 1200000ULL;  // 1.2s
/// 三下之间的间隔
static const int64_t DCL_HS_BUZZ_GAP_MS = 180;

#pragma mark - 状态

static void (*dcl_hs_orig_sendEvent)(id, SEL, id) = NULL;
static volatile int32_t dcl_hs_installed = 0;
static volatile int32_t dcl_hs_install_succeeded = 0;
static NSString *dcl_hs_install_target = @"(not installed)";

/// 手势起始时间：三指同时按下的那一刻（0 = 当前无手势）
static _Atomic(uint64_t) dcl_hs_gesture_start = 0;
static _Atomic(uint64_t) dcl_hs_last_trigger = 0;

#pragma mark - 反馈

/// 三连震 / 三连触感。
/// 优先用 UIImpactFeedbackGenerator：抖音这类 App 里它比 AudioServices 的那声
/// 「老式蜂鸣」更可靠、辨识度也高；老设备取不到该类时退到 AudioServices。
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

#pragma mark - 手势判定

/// 返回 YES 表示这次事件构成了「三指轻点抬起」的完整手势
static BOOL dcl_hs_check_gesture(UIEvent *event, uint64_t *outNow) {
    if ([event type] != UIEventTypeTouches) return NO;

    NSSet<UITouch *> *all = [event allTouches];
    if (all.count == 0) return NO;

    NSUInteger active = 0, ended = 0;
    for (UITouch *t in all) {
        UITouchPhase ph = [t phase];
        if (ph == UITouchPhaseEnded || ph == UITouchPhaseCancelled) ended++;
        else if (ph == UITouchPhaseBegan || ph == UITouchPhaseMoved ||
                 ph == UITouchPhaseStationary) active++;
    }

    uint64_t now = DCLNowUs();
    *outNow = now;

    // 阶段一：三指都在屏上（active>0 且总指头数达到 3）→ 记录手势起点。
    // 刻意只在起点为空时写：按住迟迟不抬视为拖拽，届时超时自动作废。
    if (active > 0 && all.count >= DCL_HS_FINGERS) {
        uint64_t expected = 0;
        atomic_compare_exchange_strong(&dcl_hs_gesture_start, &expected, now);
        return NO;
    }

    // 阶段二：所有指头都已抬起 → 若此前确实有过三指，且时长在轻点范围内，判定成立
    if (ended > 0 && active == 0) {
        uint64_t start = atomic_exchange(&dcl_hs_gesture_start, 0);
        return (start != 0) && (now - start) <= DCL_HS_MAX_GESTURE_US;
    }

    // 其余情形（既未按也未抬起）：保险起见清掉起点，避免陈旧状态污染下一轮判定
    if (active == 0 && ended == 0) atomic_store(&dcl_hs_gesture_start, 0);
    return NO;
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
        uint64_t now = 0;
        if (dcl_hs_check_gesture(event, &now)) {
            uint64_t last = atomic_load(&dcl_hs_last_trigger);
            if (now - last > DCL_HS_DEBOUNCE_US) {
                atomic_store(&dcl_hs_last_trigger, now);
                DCLCaptureProfile before = [DCLConfig captureProfile];
                [DCLConfig toggleProfile];
                DCLCaptureProfile after = [DCLConfig captureProfile];
                dcl_hs_feedback();

                // 留痕：无弹窗、无 UI，这是唯一能确认「确实翻过了」的出口
                [DCLLogger appendRuntimeLine:
                 [NSString stringWithFormat:@"[DCL] hotswitch: three-finger tap -> %@ -> %@ (hooks %@)",
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
    return [NSString stringWithFormat:@"已安装：%@ sendEvent: 旁路监听（三指轻点翻转 safe/full）",
            dcl_hs_install_target];
}

+ (void)install {
    if (__sync_fetch_and_or(&dcl_hs_installed, 1)) return;
    @try {
        // 第一选择：UIApplication sendEvent: —— 所有触摸事件的唯一总入口。
        // 只有它才能让检测「挂得满」：钩子落在 UIView 上会被无数子类重写挡掉，这是上一版失效的真因。
        Class appCls = NSClassFromString(@"UIApplication");
        if (appCls) {
            if (DCLReplaceInstanceMethod(appCls, @selector(sendEvent:), "v@@",
                                         (void *)dcl_hs_sendEvent,
                                         (void **)&dcl_hs_orig_sendEvent)) {
                dcl_hs_install_target = @"UIApplication";
                dcl_hs_install_succeeded = 1;
                [DCLLogger appendRuntimeLine:@"[DCL] hotswitch: installed on UIApplication sendEvent:"];
                return;
            }
        }
        // 兜底：宿主若给 UIApplication 换了自定义实现收不到（极罕见），退到 UIWindow
        Class winCls = NSClassFromString(@"UIWindow");
        if (winCls) {
            if (DCLReplaceInstanceMethod(winCls, @selector(sendEvent:), "v@@",
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
