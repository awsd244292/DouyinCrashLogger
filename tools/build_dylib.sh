#!/usr/bin/env bash
#
# build_dylib.sh — 不用 macOS，在 Linux/任意 POSIX 上编译 iOS dylib
#
# 原理（详见文档 28-非macOS编译iOS-dylib方案）：
#   1. 编译器 clang（上游 LLVM）—— 目标平台由 -target 三元组决定，与宿主无关
#   2. 链接器 ld64.lld（LLVM 的 Mach-O 后端）—— 输出标准 Mach-O，iOS 直接认
#   3. SDK —— 纯文件，从 theos/sdks 稀疏拉取一次到 ~/.pdp-sdks，之后离线复用
#
# 关键取舍（对齐 PerfDebugPlugin 的姿态）：
#   - arm64e 直接拒绝：ld64.lld 不支持 Apple 私有 ptrauth ABI，硬编出来的
#     cpusubtype 是 0x0，与 arm64 逐字节相同，属于假货，宁可报错不误导。
#   - 不开 -undefined dynamic_lookup：缺失符号在链接期就报错，早失败优于晚崩。
#
# 用法：
#   tools/build_dylib.sh                # 全量：探工具链 → 拉 SDK → 编译 → 链接 → 自检
#   ARCH=arm64 tools/build_dylib.sh      # 架构（仅支持 arm64）
#   MIN_IOS=15.0 tools/build_dylib.sh    # 最低 iOS 版本
#   SDK_SYSROOT=/path/to/sdk tools/build_dylib.sh   # 用手头已有的 SDK
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------------------
# 可调参数
# ---------------------------------------------------------------------------
ARCH="${ARCH:-arm64}"
MIN_IOS="${MIN_IOS:-14.0}"
SDK_VERSION="${SDK_VERSION:-iPhoneOS14.5.sdk}"
SDK_REPO="${SDK_REPO:-https://github.com/theos/sdks.git}"
SDK_SYSROOT="${SDK_SYSROOT:-$HOME/.pdp-sdks/$SDK_VERSION}"
OUT="${OUT:-$ROOT/build/DouyinCrashLogger.dylib}"
BUILD="$ROOT/build/obj"
TWEAK="DouyinCrashLogger"

# SDK 三版本：min（部署目标）与 sdk（SDK 自身版本），后者从目录名解析
SDK_VER_NUM="$(printf '%s' "$SDK_VERSION" | sed -E 's/.*iPhoneOS([0-9]+\.[0-9]+)\.sdk/\1/')"

fail() { echo "❌ $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 架构闸门：arm64e 明确拒绝（见文件头说明）
# ---------------------------------------------------------------------------
if [[ "$ARCH" != "arm64" ]]; then
    echo "❌ 本脚本只支持 ARCH=arm64。" >&2
    echo "   arm64e 需要 Apple 私有 ptrauth ABI（Xcode ld64）；LLVM ld64.lld 编出来的" >&2
    echo "   cpusubtype 是 0x0，实际就是 arm64，属于误导。" >&2
    echo "   注入场景用 arm64 即可（dyld 支持混合加载）。" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. 工具链探测
# ---------------------------------------------------------------------------
echo "==> [1/5] 探测工具链"
CC="${CC:-}"
if [[ -z "$CC" ]]; then
    for c in clang-18 clang-17 clang-16 clang; do
        command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }
    done
fi
[[ -n "$CC" ]] || fail "找不到 clang（>=14）。请先 sudo apt install clang"

LD="${LD:-}"
if [[ -z "$LD" ]]; then
    for p in /usr/lib/llvm-*/bin/ld64.lld /opt/homebrew/opt/llvm/bin/ld64.lld; do
        [[ -x "$p" ]] && { LD="$p"; break; }
    done
    [[ -n "$LD" ]] || LD="$(command -v ld64.lld 2>/dev/null || true)"
fi
[[ -n "$LD" && -x "$LD" ]] || fail "找不到 ld64.lld。请先 sudo apt install lld，或用 LD=/path/to/ld64.lld 指定"
echo "    CC = $CC ($($CC --version | head -1))"
echo "    LD = $LD"

# ---------------------------------------------------------------------------
# 2. SDK：缺失则稀疏拉取
# ---------------------------------------------------------------------------
echo "==> [2/5] 检查 SDK"
if [[ ! -d "$SDK_SYSROOT" ]]; then
    echo "    未找到 $SDK_SYSROOT，尝试稀疏拉取 $SDK_VERSION（约 220MB，一次性）..."
    SDK_SYSROOT="$SDK_SYSROOT" SDK_VERSION="$SDK_VERSION" SDK_REPO="$SDK_REPO" \
        bash "$ROOT/scripts/fetch-sdk.sh" "$SDK_VERSION" || \
        fail "SDK 拉取失败。可手动放置后： SDK_SYSROOT=/path/to/sdk make dylib"
fi
[[ -d "$SDK_SYSROOT" ]] || fail "SDK 目录不存在：$SDK_SYSROOT"
echo "    SDK = $SDK_SYSROOT (sdk $SDK_VER_NUM)"

# ---------------------------------------------------------------------------
# 3. 编译
# ---------------------------------------------------------------------------
echo "==> [3/5] 编译（$ARCH, min iOS $MIN_IOS）"
FILES="DCLMain.m DCLConstants.m DCLCrashReporter.m DCLWatchdog.m DCLPlaybackTracer.m \
DCLHealthCheck.m DCLConfig.m DCLHotSwitch.m DCLLogger.m DCLSupport.m \
DCLTimeline.m DCLSystemSignal.m DCLTimelinePersist.m DCLResourceProbe.m DCLProbeCost.m"

rm -rf "$BUILD"; mkdir -p "$BUILD" "$(dirname "$OUT")"
OBJS=()
for f in $FILES; do
    name="$(basename "$f" .m)"
    "$CC" \
        -target "${ARCH}-apple-ios${MIN_IOS}" \
        -mios-version-min="$MIN_IOS" \
        -isysroot "$SDK_SYSROOT" \
        -I"$SDK_SYSROOT/usr/include" \
        -I"$ROOT" \
        -F"$SDK_SYSROOT/System/Library/Frameworks" \
        -F"$SDK_SYSROOT/System/Library/PrivateFrameworks" \
        -fobjc-arc \
        -fobjc-abi-version=2 \
        -Wall -Wno-deprecated-declarations -Wno-unused-parameter \
        -Wno-unused-command-line-argument \
        -O2 -gline-tables-only \
        -c "$f" -o "$BUILD/$name.o"
    OBJS+=("$BUILD/$name.o")
    echo "    ✓ $f"
done

# ---------------------------------------------------------------------------
# 4. 链接
# ---------------------------------------------------------------------------
echo "==> [4/5] 链接 -> $OUT"
"$LD" \
    -arch "$ARCH" \
    -platform_version ios "$MIN_IOS" "$SDK_VER_NUM" \
    -dylib \
    -install_name "@rpath/$TWEAK.dylib" \
    -syslibroot "$SDK_SYSROOT" \
    -ObjC \
    -o "$OUT" "${OBJS[@]}" \
    -framework Foundation \
    -framework UIKit \
    -framework CoreGraphics \
    -framework QuartzCore \
    -framework AVFoundation \
    -framework AudioToolbox \
    -lobjc -lSystem -lc++

# ---------------------------------------------------------------------------
# 5. 自检
# ---------------------------------------------------------------------------
echo "==> [5/5] 结构自检"
python3 "$ROOT/tools/verify_dylib.py" "$OUT" --install-name "@rpath/$TWEAK.dylib"

echo
echo "✅ 产物：$OUT"
file "$OUT"

# ---------------------------------------------------------------------------
# 6. 带版本号的交付副本
# ---------------------------------------------------------------------------
# 为什么需要这一份：真正拿去自签注入的就是这个 dylib，也是换得最勤的那个。
# 光秃秃一个 DouyinCrashLogger.dylib 分不清是哪一版 —— 装到手机上过两天就忘了，
# 出问题时连「装的到底是哪个版本」都要回头翻记录。deb 一直带版本号，
# 反而是最常用的这个文件没有，属于本末倒置。
#
# 只复制文件名，不改 install_name：
#   注入走的是文件路径（DYLD_INSERT_LIBRARIES / 自签注入），
#   install_name 是库自己声称的身份，影响的是「别的二进制链接它时去哪找」，
#   对注入本身没有作用；而 verify 校验的 install_name 与原产物一致，不能动。
# 因此这一份与 $OUT 内容逐字节相同，无需重复自检。
PKG_VER="$(grep -E '^Version:' "$ROOT/control" | head -1 | cut -d' ' -f2)"
if [ -n "$PKG_VER" ]; then
    VERSIONED_OUT="$(dirname "$OUT")/${TWEAK}_${PKG_VER//./_}.dylib"
    cp "$OUT" "$VERSIONED_OUT"
    echo "✅ 交付副本（带版本号，自签注入用这份）：$VERSIONED_OUT"
fi
