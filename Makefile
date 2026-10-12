# DouyinCrashLogger — 抖音崩溃记录 Tweak
# 产物：DYYY-style 干净 dylib，可用 TrollFools / insert_dylib / Sideloadly 注入抖音，
# 不依赖 mobilesubstrate（纯 Objective-C runtime 方法交换 + POSIX 信号捕获）。

TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

TWEAK_NAME := DouyinCrashLogger

# 保留符号表：便于崩溃日志里回溯到插件自身的函数名（自用调试更友好）。
# Theos 默认会 strip，置 STRIP 为 echo 使其变成空操作。
STRIP = echo

# 源文件：不使用 Logos %hook（避免引入 substrate 依赖），全部用原生 runtime 交换 + C 信号捕获
# 极简版：已移除 UI 层（DCLCrashLogViewer），只保留崩溃捕获 + 日志落盘。
# 新增三大旁路观测模块：
#   DCLWatchdog.m        —— 主线程卡死看门狗 + Mach 栈取证
#   DCLPlaybackTracer.m  —— 视频暂停归因探针（hook AVPlayer / UIApplication.sendEvent:）
#   DCLHealthCheck.m     —— 触发式健康自检（证明插件自身在工作）
#   DCLConfig.m          —— 两档采集方案开关（A 零 hook / B hook 全开），决定后两者装不装
#   DCLHotSwitch.m       —— 摇一摇热切换（始终安装，独立于档位，免文件免重启）
#   DCLLogger.m          —— 日志管家：按会话轮转、大小闸门、噪音折叠、ASCII 净化、stderr 接管
#   DCLSupport.m         —— 公共底层工具（微秒时钟 / 类自有方法判定 / 安全方法替换 / ASCII 净化）
DouyinCrashLogger_FILES := DCLMain.m DCLConstants.m DCLCrashReporter.m DCLWatchdog.m DCLPlaybackTracer.m DCLHealthCheck.m DCLConfig.m DCLHotSwitch.m DCLLogger.m DCLSupport.m

DouyinCrashLogger_CFLAGS := -fobjc-arc -O0 -Wno-deprecated-declarations
DouyinCrashLogger_LDFLAGS :=

include $(THEOS)/makefiles/common.mk

# 仅依赖系统框架，不链接 substrate
# AVFoundation：DCLPlaybackTracer 通过运行时 hook AVPlayer，需其头文件；
# 实际符号全部经 ObjC runtime / NSClassFromString 解析，不引入链接依赖（-undefined dynamic_lookup 兜底）。
# AudioToolbox：热切换的震动反馈用到 AudioServicesPlaySystemSound。
# 注意：FRAMEWORKS 同名变量重复赋值后者覆盖前者，故全部依赖框架统一在此一处声明。
DouyinCrashLogger_FRAMEWORKS := UIKit Foundation AVFoundation AudioToolbox
# 关键：不定义 LIBRARIES，避免 -lsubstrate；tweak.mk 的 -undefined dynamic_lookup 即可，
# 由于我们从不引用任何 substrate 符号，dyld 在纯自签环境下也能正常加载。

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------------------------------------------------------------------------
# 构建前静态自检（纯 Python / Shell，不依赖 Theos 与 iOS SDK，任何机器都能跑）
#
# 为什么需要：本项目是「先实现、后构建」的流程，编译错误要等到真机构建才暴露，
# 白白多花一轮。以下两项针对的是静态评审最容易漏、而编译器必报的问题：
#
#   1) scan_self_in_cfunc.py
#      static C 函数体内误用 [self ...]。ObjC 的 self 只在方法里隐式存在，
#      C 函数里写它会直接编译失败（本项目已在 dcl_watchdog_main 上踩过一次）。
#   2) test_capture_mode_parse.py
#      采集方案开关解析回归。默认开关文件的注释里写满了 "full = B 方案" 字样，
#      一旦注释过滤失效，默认档就会被误读成 hook 全开 —— 零 hook 的默认保证失效。
#
# 用法：make precheck
# ---------------------------------------------------------------------------
precheck:
	@python3 scripts/scan_self_in_cfunc.py
	@python3 scripts/test_capture_mode_parse.py
	@bash -n scripts/verify-dylib.sh && echo "[3/3] verify-dylib.sh 语法 OK"
