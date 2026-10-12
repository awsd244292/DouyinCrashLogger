#!/usr/bin/env bash
#
# fetch-sdk.sh — 一次性拉取 iPhoneOS SDK（本地纯 clang 交叉编译只需这一份）
#
# 设计目标（对齐 PerfDebugPlugin 的本地真机级构建思路）：
#   1. 不依赖 Theos / macOS，Linux 也能跑；
#   2. 只取一个 SDK（~220MB），不把整个 sdks 仓库拖下来；
#   3. 多通道 + 超时回退：git 稀疏克隆优先，失败回退 codeload tarball 只解包目标 SDK。
#
# 用法： make fetch-sdk   （或直接 bash scripts/fetch-sdk.sh）
#
set -u

SDK_NAME="${1:-iPhoneOS14.5.sdk}"
DEST_PARENT="${PDP_SDKS_DIR:-$HOME/.pdp-sdks}"
DEST="$DEST_PARENT/$SDK_NAME"
GIT_TIMEOUT=240   # git 协议在本机偶尔抖，超过这个时间直接换通道
CURL_TIMEOUT=600  # tarball 通道总时长上限

if [[ -d "$DEST" ]]; then
    echo "[fetch-sdk] $DEST 已存在，跳过。"
    exit 0
fi

mkdir -p "$DEST_PARENT"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 通道 1：git 稀疏克隆（blobless，只取目标 SDK 的目录树 + blob）
# ---------------------------------------------------------------------------
echo "[fetch-sdk] 通道1: git 稀疏克隆 theos/sdks (仅 $SDK_NAME) ..."
if timeout "$GIT_TIMEOUT" git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/theos/sdks.git "$TMP/sdks" >/dev/null 2>&1; then
    pushd "$TMP/sdks" >/dev/null || exit 1
    if git sparse-checkout set "$SDK_NAME" >/dev/null 2>&1 && [[ -d "$SDK_NAME" ]]; then
        mv "$SDK_NAME" "$DEST"
        popd >/dev/null || exit 1
        echo "[fetch-sdk] ✅ git 通道成功 -> $DEST"
        exit 0
    fi
    popd >/dev/null || exit 1
fi
echo "[fetch-sdk] 通道1 失败/超时，回退 tarball 通道。"

# ---------------------------------------------------------------------------
# 通道 2：codeload tarball，流式只解包目标 SDK（其余字节丢弃，省时省盘）
# ---------------------------------------------------------------------------
echo "[fetch-sdk] 通道2: codeload tarball 流式解包 $SDK_NAME ..."
TARBALL="$TMP/sdks.tar.gz"
if curl -fsSL -m "$CURL_TIMEOUT" \
        https://codeload.github.com/theos/sdks/tar.gz/refs/heads/master \
        -o "$TARBALL"; then
    # 顶目录为 sdks-master，用通配只抽取目标 SDK
    if tar -xzf "$TARBALL" -C "$TMP" --wildcards "*/$SDK_NAME" 2>/dev/null; then
        SRC="$(find "$TMP" -maxdepth 2 -type d -name "$SDK_NAME" | head -1)"
        if [[ -n "$SRC" && -d "$SRC" ]]; then
            mv "$SRC" "$DEST"
            echo "[fetch-sdk] ✅ tarball 通道成功 -> $DEST"
            exit 0
        fi
    fi
fi

echo "[fetch-sdk] ❌ 两个通道都失败（网络不可达或超时）。" >&2
echo "[fetch-sdk]   手动方案：把任意 iPhoneOS SDK 放到 $DEST 后重试 make dylib。" >&2
exit 1
