# DouyinCrashLogger — 纯 clang 交叉编译（无需 Theos / 无需 macOS）
#
# 思路（对齐 PerfDebugPlugin 的本地真机级构建）：
#   - clang 18 直接交叉编译到 arm64-apple-ios
#   - ld64.lld 负责 Mach-O 链接（-undefined dynamic_lookup 兜底，不依赖任何注入框架）
#   - 本地秒级编译、CI 也省掉装 Theos 的步骤，整体更快更轻
#
# 关于架构：当前链接器 ld64.lld（LLVM 的 Mach-O 后端）对 arm64e / 指针认证(PAC)
# 支持不全，arm64e 目标会被静默降级成 arm64，故只产出 **arm64 单切片**。
# 注入到 arm64e 宿主 App 完全没问题（dyld 支持混合加载），功能不受影响。
# 等将来有支持 PAC 的链接器时，把下面 ARCHS 改回 "arm64 arm64e" 即可恢复双切片。
#
# 首次： make fetch-sdk   （一次性稀疏拉取 iPhoneOS SDK，约 220MB，放 ~/.pdp-sdks）
# 日常： make dylib        （产出 build/DouyinCrashLogger.dylib，arm64）
#        make deb          （打包 .deb，供越狱；巨魔/自签注入只用 dylib）
#        make precheck     （静态自检，无需 SDK）
#        make verify       （对已有 dylib 跑交付前静态自检）
#        make clean

# ---- 工具链（clang 18 + llvm-lld 的 Mach-O 链接器 ld64.lld）--------------
CLANG      ?= clang
LLVM_BIN   := $(dir $(realpath $(shell which clang)))
LD64_LLD   := $(LLVM_BIN)ld64.lld
DPKG_DEB   ?= dpkg-deb

# ---- SDK ----------------------------------------------------------------
# SDK 只在真正编译/打包时需要；precheck / fetch-sdk / clean 不需要，
# 不要把 SDK 缺失的报错挡在所有目标前面。
SDKROOT ?= $(HOME)/.pdp-sdks/iPhoneOS14.5.sdk
NEED_SDK :=
ifneq ($(filter dylib deb,$(MAKECMDGOALS)),)
NEED_SDK := 1
endif
ifeq ($(MAKECMDGOALS),)
NEED_SDK := 1
endif
ifeq ($(NEED_SDK),1)
ifeq ($(wildcard $(SDKROOT)),)
$(error SDK 不存在：$(SDKROOT)；请先执行 `make fetch-sdk` 拉取 iPhoneOS SDK)
endif
endif

# ---- 目标参数 ------------------------------------------------------------
MIN_IOS   := 14.0
ARCHS     := arm64
TWEAK     := DouyinCrashLogger
VERSION   := $(shell grep -E '^Version:' control | head -1 | cut -d' ' -f2)
PKG_VER   := $(subst .,_,$(VERSION))

# ---- 源文件 --------------------------------------------------------------
FILES := DCLMain.m DCLConstants.m DCLCrashReporter.m DCLWatchdog.m DCLPlaybackTracer.m \
         DCLHealthCheck.m DCLConfig.m DCLHotSwitch.m DCLLogger.m DCLSupport.m

CFLAGS := -fobjc-arc -O0 -Wno-deprecated-declarations -fno-objc-msgsend-selector-stubs
SYSROOT_FLAGS := -isysroot $(SDKROOT)
FRAMEWORK_DIRS := $(SDKROOT)/System/Library/Frameworks $(SDKROOT)/System/Library/PrivateFrameworks
FW_FLAGS := $(foreach d,$(FRAMEWORK_DIRS),-F$(d))

# ---- 产物路径 ------------------------------------------------------------
BUILD := build
OBJ   := $(BUILD)/obj
OBJS  := $(addprefix $(OBJ)/arm64/,$(FILES:.m=.o))
FAT   := $(BUILD)/$(TWEAK).dylib

.PHONY: all dylib deb precheck fetch-sdk clean verify

all: dylib

# 编译（每个源文件一个 .o）
$(OBJ)/arm64/%.o: %.m
	@mkdir -p $(dir $@)
	$(CLANG) -target arm64-apple-ios$(MIN_IOS) $(SYSROOT_FLAGS) $(FW_FLAGS) $(CFLAGS) -c $< -o $@

# 链接动态库：
#   -nostdlib            不默认链 libSystem（配合 -undefined dynamic_lookup，全部符号运行时解析）
#   -undefined dynamic_lookup  任何未定义符号都留给 dyld 在加载时解析，不依赖 substrate/UIKit 等宿主框架
#   -Wl,-platform_version / -Wl,-arch  显式补齐 ld64.lld 在自定义 -fuse-ld 下不自动下发的 Darwin 参数
$(FAT): $(OBJS)
	$(CLANG) -target arm64-apple-ios$(MIN_IOS) -isysroot $(SDKROOT) \
	  -fuse-ld=$(LD64_LLD) -dynamiclib -nostdlib -undefined dynamic_lookup \
	  -Wl,-platform_version,ios,$(MIN_IOS),$(MIN_IOS) -Wl,-arch,arm64 \
	  -install_name @rpath/$(TWEAK).dylib \
	  -o $@ $^
	@echo "==> $@ ($(shell file $@ | cut -d: -f2-))"

dylib: $(FAT)
	@$(MAKE) -s verify

# 交付前静态自检（符号 / 架构 / 依赖白名单）；对已有 dylib 跑，不依赖 SDK
verify:
	@DYLIB=$(FAT); [ -f "$$DYLIB" ] || { echo "未找到 $FAT，请先 make dylib"; exit 1; }; \
	 bash scripts/verify-dylib.sh $$DYLIB

# 打包 .deb（越狱用；巨魔/自签注入只用上面的 dylib）
deb: dylib
	@rm -rf $(BUILD)/pkg
	@mkdir -p $(BUILD)/pkg/DEBIAN
	@mkdir -p $(BUILD)/pkg/Library/MobileSubstrate/DynamicLibraries
	@cp $(FAT) $(BUILD)/pkg/Library/MobileSubstrate/DynamicLibraries/$(TWEAK).dylib
	@cp $(TWEAK).plist $(BUILD)/pkg/Library/MobileSubstrate/DynamicLibraries/$(TWEAK).plist
	@cp control $(BUILD)/pkg/DEBIAN/control
	@$(DPKG_DEB) --build -Zgzip $(BUILD)/pkg $(BUILD)/$(TWEAK)_$(PKG_VER).deb >/dev/null
	@echo "==> $(BUILD)/$(TWEAK)_$(PKG_VER).deb"

# 构建前静态自检（无需 SDK）
precheck:
	@python3 scripts/scan_self_in_cfunc.py
	@python3 scripts/test_capture_mode_parse.py
	@bash -n scripts/verify-dylib.sh && echo "[3/3] verify-dylib.sh 语法 OK"

fetch-sdk:
	@bash scripts/fetch-sdk.sh

clean:
	rm -rf $(BUILD)
