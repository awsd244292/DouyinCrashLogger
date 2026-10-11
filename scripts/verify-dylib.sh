#!/usr/bin/env bash
#
# verify-dylib.sh — 构建产物交付前的一键静态自检
#
# 定位：只做静态校验，不替代真机功能测试（真机测试必须由设备持有者完成）。
# 目标：构建产物下载后一条命令跑完即出结论，避免在交付前反复推演/二次论证。
#
# 用法：./scripts/verify-dylib.sh <dylib 路径>
# 退出码：0=全部通过可交付；1=存在失败项禁止交付；2=参数错误
#
# 注意：本脚本刻意不使用 `set -o pipefail`。
#   原因：`grep -q` 命中首个匹配后立即退出并关闭管道，上游 `strings` 会因 SIGPIPE
#   返回 141；在 pipefail 下整个管道判为非 0，导致“符号存在却被误报缺失”。
#
set -u

DYLIB="${1:-}"
if [[ -z "$DYLIB" || ! -f "$DYLIB" ]]; then
    echo "用法: $0 <dylib 路径>"
    exit 2
fi

fail=0
pass() { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; fail=1; }

echo "=== 静态自检: $(basename "$DYLIB") ==="
size=$(stat -c%s "$DYLIB" 2>/dev/null || stat -f%z "$DYLIB" 2>/dev/null || echo 0)
echo "路径: $DYLIB"
echo "大小: $((size / 1024)) KB"

# 一次性读取全部字符串，后续均在内存中匹配（避免反复读文件）
all=$(strings -a "$DYLIB")

# 1) 架构：必须是 fat arm64 + arm64e
echo "[1/5] 架构"
desc=$(file "$DYLIB")
if echo "$desc" | grep -q 'universal binary'; then
    if echo "$desc" | grep -q 'arm64' && echo "$desc" | grep -q 'arm64e'; then
        pass "fat arm64 + arm64e"
    else
        bad "是 fat 但缺少 arm64 或 arm64e"
    fi
else
    bad "非 universal binary（单架构，无法覆盖 arm64/arm64e）"
fi

# 2) 必需符号：新功能必须已编入
echo "[2/5] 必需符号（新功能已编入）"
required=(
    recordExitMarkAndRegisterTerminateObserver
    redirectStderrToRuntimeLog
    lastExitWasAbnormal
    previousExitKind
    previousExitDescription
    dcl_appWillTerminate
    dcl_appDidEnterBackgroundState
    dcl_appDidBecomeActiveState
    dcl_appendPreviousExitVerdictToRuntimeLog
    dcl_prepare_images
    dcl_signal_handler
    dcl_uncaught_exception_handler
    registerSnapshotTriggers
    writeLatestLogWithReason
    # —— 1.3 新增：三大旁路观测模块必须已编入 ——
    dcl_appendPlaybackDiagnosis
    dcl_appendHealthCheck
    dcl_appendAllThreadsSnapshot
    DCLWatchdog
    dcl_loop_activity
    dcl_sample_main_thread
    captureAllThreadsSnapshot
    DCLPlaybackTracer
    dcl_capture
    dcl_sendEvent
    DCLHealthCheck
    checkMainThreadResponsive
    # —— 1.3 新增：两档采集方案开关（A 零 hook / B hook 全开）——
    DCLConfig
    captureProfile
    hooksEnabled
    deepEvidenceEnabled
    dcl_appendCaptureProfile
    checkCaptureProfile
    enabledCapabilities
    disabledCapabilities
)

# 2b) 退出判定修正必须以 NSUserDefaults key 的形式落到二进制里，
#     这三个 key 缺任何一个，都说明「用户主动划掉 vs 真闪退」的区分没进包。
echo "[2b] 退出性质判定所需的持久化 key"
for s in DCL_last_launch_time DCL_last_exit_was_backgrounded DCL_last_enter_background_time; do
    case "$all" in
        *"$s"*) pass "$s" ;;
        *)      bad "缺失 key $s（退出性质判定无法成立）" ;;
    esac
done
# 旧版单一判定文案不应再出现
case "$all" in
    *"可能 SIGKILL/OOM/早期崩溃"*) bad "残留旧版二值判定文案" ;;
    *)                             pass "旧版二值判定文案已替换" ;;
esac

# 2c) 两档采集方案的开关必须落到二进制：缺了开关，A/B 方案就无法区分，
#     「hook 全开」与「零 hook」会退化成同一个版本，方案分档失去意义。
echo "[2c] 采集方案开关（A safe / B full）"
for s in capture_mode.txt DCL_capture_mode; do
    case "$all" in
        *"$s"*) pass "$s" ;;
        *)      bad "缺失 $s（两档采集方案无法切换）" ;;
    esac
done
for s in "${required[@]}"; do
    # 用 case 做子串匹配，不走管道，规避 SIGPIPE 误判
    case "$all" in
        *"$s"*) pass "$s" ;;
        *)      bad "缺失符号 $s" ;;
    esac
done

# 3) 禁止符号：已移除的功能必须清零
echo "[3/5] 禁止符号（已移除功能不得残留）"
# 注意：dcl_sendEvent 自 1.3 起已合法复用于 DCLPlaybackTracer（纯旁路触摸时间戳钩子），
#       不再列入禁止清单；仅 DCLCrashLogViewer（极简版移除的 UI 层）仍需清零。
for s in DCLCrashLogViewer; do
    case "$all" in
        *"$s"*) bad "仍存在 $s（极简版不应包含该符号）" ;;
        *)      pass "无 $s（已移除）" ;;
    esac
done

# 4) 依赖库白名单：不得依赖任何注入框架
echo "[4/5] 依赖库（自签注入不得依赖注入框架）"
libs=$(printf '%s\n' "$all" \
    | grep -oE '/(usr/lib|System/Library)/[A-Za-z0-9_./+-]*\.framework/[A-Za-z0-9_.+-]+|/(usr/lib|System/Library)/[A-Za-z0-9_./+-]*\.dylib' \
    | sort -u)
if [[ -n "$libs" ]]; then
    echo "$libs" | sed 's/^/    /'
else
    echo "    (未解析到链接库路径)"
fi
case "$libs" in
    *[Ss]ubstrate*|*[Ee]lle[Kk]it*|*[Cc]ydia*|*libhooker*)
        bad "存在注入框架依赖（Substrate/ElleKit/libhooker）" ;;
    *) pass "无 Substrate/ElleKit/libhooker 依赖" ;;
esac

# 5) 越狱路径：仅允许自身 LC_ID_DYLIB，其余视为异常
echo "[5/5] 越狱路径残留（仅允许自身 LC_ID_DYLIB）"
name=$(basename "$DYLIB" | sed -E 's/_[0-9.]+-[0-9]+\.dylib$/.dylib/')
jail=$(printf '%s\n' "$all" | grep -E '/Library/(MobileSubstrate|TweakInject)/' | sort -u)
if [[ -z "$jail" ]]; then
    pass "无越狱路径字符串"
else
    while IFS= read -r line; do
        if [[ "$line" == "/Library/MobileSubstrate/DynamicLibraries/$name" ]]; then
            pass "LC_ID_DYLIB（自身安装路径，非依赖）: $line"
        else
            bad "异常越狱路径: $line"
        fi
    done <<< "$jail"
fi

echo "=== 结论 ==="
if [[ $fail -eq 0 ]]; then
    echo "✅ 全部通过，可交付（真机功能测试仍需设备持有者执行）"
else
    echo "❌ 存在失败项，禁止交付"
fi
exit $fail
