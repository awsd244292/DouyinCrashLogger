//
//  DCLHotSwitch.m
//  DouyinCrashLogger
//
//  热切换：三指轻点 → 翻转采集方案（safe ↔ full）→ 震 3 下反馈。
//
//  设计要点（呼应三轮审查的铁律）：
//  1) 本监听独立于采集两档，始终安装 —— 否则 safe 档下用户点不出入口，
//     就永远切不到 full 了。它属于「配置交互层」，不计入取证探针的 hook 集合。
//  2) 绝不吞事件：钩子体第一步就是调用 orig 透传 touchesEnded，三指检测与
//     翻转都发生在透传之后；即便检测逻辑异常也不会影响宿主触摸分发。
//  3) 重入保护用线程局部变量（__thread），不挡其他线程的触摸回调。
//  4) 只 hook UIView 本类自有的 touchesEnded:withEvent:，不碰父类；并正确取出
//     且透传 orig，不破坏 UIView 自身的触摸分发链（UIApplication sendEvent: 的
//     钩子由 DCLPlaybackTracer 在 full 档单独挂，互不干扰）。
//  5) 翻转后由 DCLConfig 双写 NSUserDefaults + capture_mode.txt，重启后依然生效。
//  6) 震动用公开 API（AudioServicesPlaySystemSound），一次只震一下；
//     要「3 下」只能间隔重复调用（iOS 无公开的「震 N 下」接口）。
//

#import "DCLHotSwitch.h"
#import "DCLConfig.h"

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <sys/time.h>

static uint64_t dcl_hs_now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
}

/// 本类是否「自己拥有」该方法的实现（不含从父类继承来的）。
/// class_getInstanceMethod 会一路向上找到父类实现，拿它去替换会改到父类，
/// 必须先用本函数排除这种情况。
static BOOL dcl_hs_class_owns_method(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    BOOL owned = NO;
    if (list) {
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(list[i]) == sel) { owned = YES; break; }
        }
        free(list);
    }
    return owned;
}

/// 取原方法 encoding 后替换，避免手写 type encoding 出错。
static BOOL dcl_hs_try_hook(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (!dcl_hs_class_owns_method(cls, sel)) return NO;  // 只换本类自有实现，不碰父类
    const char *enc = method_getTypeEncoding(m);
    if (!enc) return NO;
    IMP orig = class_replaceMethod(cls, sel, newImp, enc);
    if (!orig) return NO;            // 本类无实现，无处透传，宁可不挂
    if (orig == newImp) return NO;   // 再挂会形成自环
    *outOrig = orig;
    return YES;
}

#pragma mark - 状态

static void (*dcl_hs_orig_touchesEnded)(id, SEL, id, id) = NULL;
static volatile int32_t dcl_hs_installed = 0;
static _Atomic(uint64_t) dcl_hs_last_trigger = 0;   // 去抖时间戳（us）
static const uint64_t DCL_HS_DEBOUNCE_US = 600000ULL;  // 600ms 内只触发一次

#pragma mark - 震动

static void dcl_hs_vibrate_times(int n) {
    // 公开 API 只能震一下；要 N 下只能间隔重复调用。
    for (int i = 0; i < n; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 180) * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        });
    }
}

#pragma mark - 钩子体（原样透传，零吞事件）

static void dcl_hs_touchesEnded(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    static __thread int in_hook = 0;
    // 重入保护：必须先透传再 return，绝不能只 return 把控制交回出错处
    if (in_hook) {
        if (dcl_hs_orig_touchesEnded) dcl_hs_orig_touchesEnded(self, _cmd, touches, event);
        return;
    }
    in_hook = 1;

    // 铁律：先透传，绝不吞事件
    if (dcl_hs_orig_touchesEnded) dcl_hs_orig_touchesEnded(self, _cmd, touches, event);

    @try {
        // 三指同时抬起即判定为切换手势（抖音主要用单指上下滑切视频，
        // 三指手势在日常交互中几乎不会误触；即便偶发误触也只翻转档位 + 震一下，无破坏性）。
        NSSet<UITouch *> *all = [event allTouches];
        if (all.count == 3) {
            BOOL allEnded = YES;
            for (UITouch *t in all) {
                if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) {
                    allEnded = NO;
                    break;
                }
            }
            if (allEnded) {
                uint64_t now = dcl_hs_now_us();
                uint64_t last = atomic_load(&dcl_hs_last_trigger);
                if (now - last > DCL_HS_DEBOUNCE_US) {
                    atomic_store(&dcl_hs_last_trigger, now);
                    [DCLConfig toggleProfile];
                    dcl_hs_vibrate_times(3);
                }
            }
        }
    } @catch (id e) {
        (void)e;
    }

    in_hook = 0;
}

@implementation DCLHotSwitch

+ (BOOL)isInstalled {
    return dcl_hs_installed != 0;
}

+ (void)install {
    if (__sync_fetch_and_or(&dcl_hs_installed, 1)) return;
    @try {
        Class viewCls = NSClassFromString(@"UIView");
        if (viewCls) {
            dcl_hs_try_hook(viewCls, @selector(touchesEnded:withEvent:),
                            (IMP)dcl_hs_touchesEnded, &dcl_hs_orig_touchesEnded);
        }
    } @catch (id e) {
        (void)e;
    }
}

@end
