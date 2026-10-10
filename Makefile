# DouyinCrashLogger — 抖音崩溃记录 Tweak
# 产物：DYYY-style 干净 dylib，可用 TrollFools / insert_dylib / Sideloadly 注入抖音，
# 不依赖 mobilesubstrate（纯 Objective-C runtime 方法交换 + POSIX 信号捕获）。

TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

TWEAK_NAME := DouyinCrashLogger

# 源文件：不使用 Logos %hook（避免引入 substrate 依赖），全部用原生 runtime 交换 + C 信号捕获
DouyinCrashLogger_FILES := DCLMain.m DCLConstants.m DCLCrashReporter.m DCLCrashLogViewer.m

DouyinCrashLogger_CFLAGS := -fobjc-arc -Wno-deprecated-declarations
DouyinCrashLogger_LDFLAGS :=

include $(THEOS)/makefiles/common.mk

# 仅依赖系统框架，不链接 substrate
DouyinCrashLogger_FRAMEWORKS := UIKit Foundation
# 关键：不定义 LIBRARIES，避免 -lsubstrate；tweak.mk 的 -undefined dynamic_lookup 即可，
# 由于我们从不引用任何 substrate 符号，dyld 在纯自签环境下也能正常加载。

include $(THEOS_MAKE_PATH)/tweak.mk
