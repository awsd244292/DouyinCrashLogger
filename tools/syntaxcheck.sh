#!/usr/bin/env bash
#
# syntaxcheck.sh — 快速语法冒烟（-fsyntax-only，只做语法/语义分析，不产出 .o）
#
# 设计取舍：本工程大量使用系统头（dispatch / CFRunLoop / mach / execinfo / AVFoundation），
# 用「自带桩头文件」的方式需要把大半个 SDK 重写一遍，性价比极低。
# 因此这里直接用真 SDK 做 -fsyntax-only：
#   - 有 SDK：几秒跑完，能提前抓出笔误、类型错误、声明缺失；
#   - 没有 SDK：明确提示并跳过（不假装通过），引导先 make fetch-sdk。
#
# 用法：
#   tools/syntaxcheck.sh
#   SDK_SYSROOT=/path/to/sdk tools/syntaxcheck.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MIN_IOS="${MIN_IOS:-14.0}"
SDK_VERSION="${SDK_VERSION:-iPhoneOS14.5.sdk}"
SDK_SYSROOT="${SDK_SYSROOT:-$HOME/.pdp-sdks/$SDK_VERSION}"

CC="${CC:-}"
if [[ -z "$CC" ]]; then
    for c in clang-18 clang-17 clang-16 clang; do
        command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }
    done
fi
[[ -n "$CC" ]] || { echo "❌ 找不到 clang（>=14）"; exit 1; }

if [[ ! -d "$SDK_SYSROOT" ]]; then
    echo "⚠️  未找到 SDK：$SDK_SYSROOT"
    echo "    语法预检需要真 SDK，请先执行： make fetch-sdk"
    echo "    （跳过语法预检，直接 make dylib 亦会走同一套真 SDK 编译）"
    exit 0
fi

FILES=(DCLMain.m DCLConstants.m DCLCrashReporter.m DCLWatchdog.m DCLPlaybackTracer.m
       DCLHealthCheck.m DCLConfig.m DCLHotSwitch.m DCLLogger.m DCLSupport.m
       DCLTimeline.m DCLSystemSignal.m DCLTimelinePersist.m DCLResourceProbe.m
       DCLProbeCost.m DCLSettings.m)

echo "==> 语法预检（真 SDK, $CC, min iOS $MIN_IOS）"
fail=0
for f in "${FILES[@]}"; do
    if "$CC" -fsyntax-only \
        -target "arm64-apple-ios${MIN_IOS}" \
        -mios-version-min="$MIN_IOS" \
        -isysroot "$SDK_SYSROOT" \
        -I"$SDK_SYSROOT/usr/include" -I"$ROOT" \
        -F"$SDK_SYSROOT/System/Library/Frameworks" \
        -F"$SDK_SYSROOT/System/Library/PrivateFrameworks" \
        -fobjc-arc -fobjc-abi-version=2 -fblocks \
        -Wall -Wno-deprecated-declarations -Wno-unused-parameter \
        -Wno-unused-command-line-argument \
        "$f" 2>/tmp/dcl_syntax_$$.log; then
        echo "  ✓ $f"
    else
        echo "  ❌ $f"
        sed 's/^/      /' /tmp/dcl_syntax_$$.log | head -20
        fail=1
    fi
done
rm -f /tmp/dcl_syntax_$$.log

if [[ $fail -eq 0 ]]; then
    echo "✅ 语法预检通过（完整链接仍需 make dylib）"
else
    echo "❌ 存在语法错误"
fi
exit $fail
