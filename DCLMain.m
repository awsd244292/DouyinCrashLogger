//
//  DCLMain.m
//  DouyinCrashLogger
//
//  入口：在 dylib 加载时（constructor，早于 main）安装崩溃捕获，并对
//  UIApplication 的 -sendEvent: 做原生方法交换，通过摇一摇触发日志面板。
//
//  注意：全程使用 Objective-C runtime 原生 API（method_setImplementation），
//  不依赖 CydiaSubstrate / ElleKit，因此在纯自签（无越狱、无注入框架）环境
//  下也能正常工作。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "DCLCrashReporter.h"
#import "DCLCrashLogViewer.h"
#import "DCLConstants.h"

static void (*orig_sendEvent)(UIApplication *, SEL, UIEvent *) = NULL;

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

__attribute__((constructor)) static void dcl_entry(void) {
    // 1) 安装崩溃捕获
    [DCLCrashReporter install];
    [DCLCrashReporter cleanupOldLogs];

    // 2) 方法交换：UIApplication -sendEvent: 检测摇一摇
    //    原生 method_setImplementation，不依赖 substrate
    Class appCls = objc_getClass("UIApplication");
    if (appCls) {
        SEL sel = @selector(sendEvent:);
        Method m = class_getInstanceMethod(appCls, sel);
        if (m) {
            IMP newImp = (IMP)dcl_sendEvent;
            IMP oldImp = method_setImplementation(m, newImp);
            orig_sendEvent = (void *)oldImp;
        }
    }
}
