# DouyinCrashLogger — 不用 macOS 编译 iOS dylib（纯 clang + ld64.lld）
#
# 原理详见文档《28-非macOS编译iOS-dylib方案》：
#   编译器 clang（上游 LLVM）不挑宿主，只认 -target 三元组；
#   链接器换 LLVM 的 ld64.lld，输出标准 Mach-O；
#   SDK 是纯文件，稀疏拉取一次到 ~/.pdp-sdks 即可离线复用。
#
# 入口：
#   make dylib       交叉编译 -> build/DouyinCrashLogger.dylib（arm64）
#   make syntax      纯语法预检（自带桩头文件，不需要 SDK，秒级冒烟）
#   make verify      对已有 dylib 跑纯 Python Mach-O 结构自检
#   make deb         打包 .deb（越狱用；巨魔/自签注入只用 dylib）
#   make fetch-sdk   仅拉取 SDK
#   make clean
#
# 可调环境变量：
#   MIN_IOS=15.0 make dylib               最低 iOS 版本（默认 14.0）
#   SDK_VERSION=iPhoneOS14.5.sdk make dylib
#   SDK_SYSROOT=/path/to/sdk make dylib   用手头已有 SDK
#   OUT=dist/xx.dylib make dylib          自定义输出
#   CC=clang-17 LD=/usr/lib/llvm-17/bin/ld64.lld make dylib
#
# 注意：本方案不支持 arm64e（LLVM ld64.lld 无 Apple 私有 ptrauth ABI，
# 硬编出来的 cpusubtype 是 0x0，与 arm64 逐字节相同，属假货）。
# 注入场景用 arm64 即可；需要 arm64e 请走 macOS + Theos。

TWEAK      := DouyinCrashLogger
VERSION    := $(shell grep -E '^Version:' control | head -1 | cut -d' ' -f2)
PKG_VER    := $(subst .,_,$(VERSION))
BUILD      := build
FAT        := $(BUILD)/$(TWEAK).dylib
DPKG_DEB   ?= dpkg-deb

.PHONY: all dylib syntax verify deb precheck fetch-sdk clean

all: dylib

# ---- 主线：不用 macOS 的交叉编译 ----
dylib:
	@bash tools/build_dylib.sh

# ---- 语法预检（无 SDK 也能跑）----
syntax:
	@bash tools/syntaxcheck.sh

# ---- 结构自检（纯 Python，不需要 Apple 工具）----
verify:
	@test -f "$(FAT)" || { echo "未找到 $(FAT)，请先 make dylib"; exit 1; }
	@python3 tools/verify_dylib.py "$(FAT)" --install-name "@rpath/$(TWEAK).dylib"

# ---- 打包 .deb（越狱用）----
deb: dylib
	@rm -rf $(BUILD)/pkg
	@mkdir -p $(BUILD)/pkg/DEBIAN
	@mkdir -p $(BUILD)/pkg/Library/MobileSubstrate/DynamicLibraries
	@cp $(FAT) $(BUILD)/pkg/Library/MobileSubstrate/DynamicLibraries/$(TWEAK).dylib
	@cp $(TWEAK).plist $(BUILD)/pkg/Library/MobileSubstrate/DynamicLibraries/$(TWEAK).plist
	@cp control $(BUILD)/pkg/DEBIAN/control
	@$(DPKG_DEB) --build -Zgzip $(BUILD)/pkg $(BUILD)/$(TWEAK)_$(PKG_VER).deb >/dev/null
	@echo "==> $(BUILD)/$(TWEAK)_$(PKG_VER).deb"

# ---- 构建前静态自检（项目自有门禁，无需 SDK）----
precheck:
	@python3 scripts/scan_self_in_cfunc.py
	@python3 scripts/test_capture_mode_parse.py
	@bash -n scripts/verify-dylib.sh && echo "[3/3] verify-dylib.sh 语法 OK"

fetch-sdk:
	@bash scripts/fetch-sdk.sh "$(SDK_VERSION)"

clean:
	rm -rf $(BUILD)
