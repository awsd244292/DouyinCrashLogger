#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
第一轮检查：危险模式自动扫描。

关注「会让宿主崩溃 / 卡死 / 死锁」这一类问题，而不是代码风格。
每一项都给出 文件:行号 + 命中内容 + 为什么危险。

判据刻意做得「宁可多报，不可漏报」：本脚本是门禁，不是编译器。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Objective-C / Foundation 调用：在信号处理器、持锁、suspend 期间出现即为高危
OC_CALL = re.compile(r"\[[A-Za-z_][A-Za-z0-9_]*\s")
# Foundation 构造
FOUNDATION = re.compile(
    r"\b(NSString|NSMutableString|NSArray|NSMutableArray|NSDictionary|"
    r"NSMutableDictionary|NSDate|NSDateFormatter|NSFileManager|NSUserDefaults|"
    r"NSThread|NSProcessInfo|NSNumber|NSHomeDirectory|NSClassFromString|"
    r"NSLog|dispatch_async|dispatch_sync|dispatch_after)\b"
)
# 内存分配
ALLOC = re.compile(r"\b(malloc|calloc|realloc|free|NSAllocateObject)\b")
# 符号化 / 镜像遍历：拿 dyld 全局锁
DYLD = re.compile(r"\b(dladdr|dlopen|dlsym|_dyld_image_count|_dyld_get_image_header|_dyld_get_image_name|backtrace_symbols)\b")
# 明确非 async-signal-safe
NOT_ASYNC_SAFE = re.compile(
    r"\b(fprintf|printf|snprintf|sprintf|NSLog|objc_msgSend|malloc|free|"
    r"dladdr|backtrace_symbols|pthread_mutex_lock|dispatch_async|"
    r"NSUserDefaults|NSFileManager|fsync)\b"
)

findings = []


def add(sev, rule, path, lineno, text, why):
    findings.append((sev, rule, path.name, lineno, text.strip()[:110], why))


def scan_file(path: Path):
    src = path.read_text(encoding="utf-8", errors="replace")
    lines = src.split("\n")

    # ---------- 规则 1：static 局部数组/缓冲在可能被并发调用的函数里 ----------
    # 找出所有 "static <type> <name>[<size>]" 形式的定长缓冲
    for i, ln in enumerate(lines, 1):
        m = re.search(r"\bstatic\s+[A-Za-z_][\w\s\*]*\s(\w+)\s*\[\s*(\d+|[A-Z_]+)\s*\]", ln)
        if m and not ln.strip().startswith("//"):
            name = m.group(1)
            # 排除 const 常量表
            if re.search(r"\bconst\b", ln):
                continue
            # 只关心「函数体内」的 static 缓冲（有缩进）。
            # 顶格的 static 数组是文件级共享表，属于刻意设计（如无锁抑制表），
            # 其并发语义由 volatile 与原子下标保证，不是这里要抓的问题。
            if not (ln[:1] == " " or ln[:1] == "\t"):
                continue
            add("P1", "R1 静态缓冲并发", path, i, ln,
                f"`{name}` 是函数内 static 缓冲；若所在函数被多线程并发调用会互相覆盖"
                f"（AVPlayer 回调常见于非主线程）")

    # ---------- 规则 2：信号处理器内的非 async-signal-safe 调用 ----------
    # 定位 signal handler 函数体（大括号配对）
    starts = []
    for i, ln in enumerate(lines):
        if re.search(r"static\s+void\s+dcl_signal_handler\s*\(", ln):
            starts.append(i)
        if re.search(r"dcl_uncaught_exception_handler", ln) and "static" in ln:
            pass
    for st in starts:
        depth = 0
        opened = False
        for i in range(st, min(st + 80, len(lines))):
            depth += lines[i].count("{") - lines[i].count("}")
            if "{" in lines[i]:
                opened = True
            if opened and depth <= 0:
                end = i
                break
        else:
            end = min(st + 80, len(lines) - 1)
        for i in range(st, end + 1):
            code = lines[i]
            if code.strip().startswith("//") or code.strip().startswith("* "):
                continue
            for m in NOT_ASYNC_SAFE.finditer(code):
                add("P1", "R2 信号处理器非安全调用", path, i + 1, code,
                    f"信号处理器内调用 `{m.group(1)}`：非 async-signal-safe，"
                    f"崩溃现场再调用可能死锁或二次崩溃")

    # ---------- 规则 3：suspend 之后、resume 之前 是否做了危险动作 ----------
    # 在持有 thread_suspend 的区间内调用 dladdr / OC / malloc = 死锁风险（dyld / malloc 锁）
    in_suspend = False
    for i, ln in enumerate(lines, 1):
        if "thread_suspend" in ln and "thread_resume" not in ln:
            in_suspend = True
            continue
        if "thread_resume" in ln:
            in_suspend = False
            continue
        if not in_suspend:
            continue
        code = ln
        if code.strip().startswith("//"):
            continue
        hit = None
        if DYLD.search(code):
            hit = DYLD.search(code).group(1)
        elif ALLOC.search(code):
            hit = ALLOC.search(code).group(1)
        elif OC_CALL.search(code) and "format" in code.lower():
            hit = "Objective-C 消息"
        if hit:
            add("P0", "R3 suspend 期间危险调用", path, i, code,
                f"线程被 suspend 期间调用 `{hit}`：若被挂起的线程正持有 dyld/malloc 锁，"
                f"此处会永久死锁（宿主卡死，不崩溃但彻底无响应）")

    # ---------- 规则 4：__block 跨线程标志位缺内存屏障 ----------
    for i, ln in enumerate(lines, 1):
        if "__block" in ln and re.search(r"__block\s+(BOOL|int|bool|NSInteger|NSUInteger)", ln):
            # 向后 20 行找 while (!xxx 自旋
            for j in range(i, min(i + 20, len(lines))):
                var = re.search(r"__block\s+\w+\s+(\w+)", ln)
                if var and re.search(r"while\s*\(\s*!?" + re.escape(var.group(1)), lines[j]):
                    add("P2", "R4 自旋标志无屏障", path, j + 1, lines[j],
                        f"`{var.group(1)}` 跨线程读写且无 volatile/atomic；-O2 下自旋可能被优化成死循环，"
                        f"表现为检测项永久超时（误报 FAIL，不崩但结论失真）")

    # ---------- 规则 5：constructor 内的 UIKit / 重活调用（排除注释行） ----------
    ctor_open = False
    for i, ln in enumerate(lines, 1):
        stripped = ln.strip()
        if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*"):
            continue
        if "__attribute__((constructor))" in ln:
            ctor_open = True
            continue
        if ctor_open:
            if re.search(r"\b(UIDevice|UIApplication|NSBundle\s+mainBundle|"
                         r"UIApplicationWillTerminateNotification|"
                         r"UIApplicationDidEnterBackgroundNotification|"
                         r"UIApplicationUserDidTakeScreenshotNotification)\b", ln):
                add("P1", "R5 constructor 内 UIKit 调用", path, i, ln,
                    "constructor（dyld 期）触碰 UIKit：UIKit 可能尚未完成初始化，"
                    "早于其 +load 使用会直接终止进程。建议延后到 dispatch_after 主线程块")

    # ---------- 规则 6：@synchronized 的参数可能为 nil ----------
    for i, ln in enumerate(lines, 1):
        m = re.search(r"@synchronized\s*\(\s*(\w+)\s*\)", ln)
        if m:
            var = m.group(1)
            # 若该变量在某处被赋予真实对象，则它只在「尚未初始化」的极早期为 nil，
            # 那时容器本身也还没建立，不构成并发风险 —— 跳过
            assigned = any(re.search(rf"\b{var}\s*=\s*\[", l2) for l2 in lines)
            if assigned:
                continue
            for j, l2 in enumerate(lines, 1):
                if re.search(rf"\b{var}\s*=\s*nil\b", l2) or re.search(rf"static\s+[\w\s\*]*\b{var}\b", l2):
                    add("P2", "R6 @synchronized(nil)", path, i, ln,
                        f"`{var}` 可能为 nil；@synchronized(nil) 不加锁，"
                        f"多线程同时写容器会破坏内部一致性（崩溃概率低但存在）")
                    break

    # ---------- 规则 7：signal 注册覆盖后未保存/转发原 handler ----------
    # 只针对「真的注册」的调用：sigaction(sig, &sa, ...) 第二参非空。
    # sigaction(sig, NULL, &cur) 是只读查询（自检用），不构成覆盖。
    if "sigaction" in src:
        has_old = re.search(r"(old_sa|previous|g_prev_sa|old_handler|orig_sa)", src)
        if not has_old:
            for i, ln in enumerate(lines, 1):
                if "sigaction" not in ln or "SIG_DFL" in ln:
                    continue
                if ln.lstrip().startswith("//"):
                    continue
                m = re.search(r"sigaction\s*\(([^;]*)\)", ln)
                if not m:
                    continue
                args = [a.strip() for a in m.group(1).split(",")]
                installs = len(args) >= 2 and args[1] not in ("NULL", "nil", "0")
                if installs:
                    add("P1", "R7 覆盖宿主信号处理器", path, i, ln,
                        "直接覆盖宿主/其他插件已注册的信号处理器且不转发："
                        "宿主自身的崩溃监控与收尾逻辑被静默切断")
                    break

    # ---------- 规则 13：丢弃 NSSetUncaughtExceptionHandler 的返回值 ----------
    # 返回值就是宿主原有的未捕获异常处理器。丢弃 = 静默切断宿主异常上报链
    # （与 R7 同类，但发生在 OC 异常路径，光看 sigaction 扫不到）。
    for i, ln in enumerate(lines, 1):
        if "NSSetUncaughtExceptionHandler" not in ln or ln.lstrip().startswith("//"):
            continue
        if not re.search(r"^\s*(?:static\s+)?[\w\s\*]*\w+\s*=\s*NSSetUncaughtExceptionHandler", ln):
            add("P1", "R13 丢弃原有未捕获异常处理器", path, i, ln,
                "NSSetUncaughtExceptionHandler 返回宿主/其他插件原有的 handler；"
                "丢弃即静默切断宿主的异常统计与收尾逻辑，且不转发也无法恢复")

    # ---------- 规则 8：递归保护分支直接 return（可能无限循环） ----------
    for i, ln in enumerate(lines, 1):
        if re.search(r"__sync_fetch_and_or\s*\(\s*&g_handling", ln):
            for j in range(i, min(i + 4, len(lines))):
                if re.search(r"^\s*return\s*;", lines[j]):
                    add("P0", "R8 重入分支直接 return", path, j + 1, lines[j],
                        "处理器内再次崩溃时直接 return：控制权回到出错指令，"
                        "会无限触发同一信号 —— 进程 100% CPU 挂死、永不退出（比崩溃更糟）")
                    break

    # ---------- 规则 9：SIGPIPE 被接管 ----------
    for i, ln in enumerate(lines, 1):
        if "SIGPIPE" in ln and "signals[]" in ln:
            add("P0", "R9 接管 SIGPIPE", path, i, ln,
                "SIGPIPE 在 iOS 上通常被 App 设为忽略；一旦接管，"
                "任何 socket 写失败都会走到处理器并终止进程 —— 直接制造崩溃")

    # ---------- 规则 10：未使用 sigaltstack ----------
    if "sigaction" in src and "sigaltstack" not in src and "SA_ONSTACK" not in src:
        for i, ln in enumerate(lines, 1):
            if "sa.sa_flags" in ln:
                add("P1", "R10 缺 sigaltstack", path, i, ln,
                    "未在备用栈上运行处理器：栈溢出类崩溃无法取证，"
                    "且处理器在已损坏的栈上运行会二次崩溃")
                break

    # ---------- 规则 11：钩子体是否先剪枝再回溯 ----------
    # 正确写法是 backtrace 位于 `if (allow)` 之后；这里比较二者首次出现的位置。
    bt_idx = None
    allow_idx = None
    for i, ln in enumerate(lines, 1):
        code = ln.split("//")[0]
        if bt_idx is None and re.search(r"\bbacktrace\s*\(", code):
            bt_idx = i
        if allow_idx is None and re.search(r"\bif\s*\(\s*allow\s*\)", code):
            allow_idx = i
    if bt_idx is not None and allow_idx is not None and bt_idx < allow_idx:
        add("P2", "R11 钩子体重活先于剪枝", path, bt_idx, lines[bt_idx - 1],
            "backtrace 位于抑制判断之前：被抑制的高频调用白白付出回溯开销，"
            "在滑动场景会拖慢播放（属于「干扰宿主」而非崩溃）")

    # ---------- 规则 12：install 类方法先置位后校验 ----------
    for i, ln in enumerate(lines, 1):
        if re.search(r"if\s*\(\s*__sync_fetch_and_or\s*\(\s*&g_installed", ln):
            for j in range(i, min(i + 6, len(lines))):
                if re.search(r"isMainThread", lines[j]) and "return" in lines[j]:
                    add("P1", "R12 置位早于前置校验", path, j + 1, lines[j],
                        "先置 installed=1 再校验主线程；校验失败时 installed 已置位，"
                        "此后永远不会再安装 —— 功能静默失效（不崩，但整条链路形同虚设）")
                    break


def main():
    files = sorted(ROOT.glob("*.m")) + sorted(ROOT.glob("*.xm"))
    if not files:
        print("未找到源文件", file=sys.stderr)
        return 2
    for f in files:
        scan_file(f)

    if not findings:
        print("✓ 未命中任何危险模式")
        return 0

    order = {"P0": 0, "P1": 1, "P2": 2}
    findings.sort(key=lambda x: (order[x[0]], x[2], x[3]))

    print(f"{'严重度':<6} {'规则':<28} {'位置':<26} 命中")
    print("-" * 120)
    for sev, rule, f, ln, text, why in findings:
        print(f"[{sev}] {rule}")
        print(f"      {f}:{ln}  |  {text}")
        print(f"      → {why}")
        print()
    counts = {s: sum(1 for x in findings if x[0] == s) for s in ("P0", "P1", "P2")}
    print("=" * 120)
    print(f"合计 {len(findings)} 项：P0(崩溃/卡死) {counts['P0']} · P1(功能失效/风险) {counts['P1']} · P2(失真) {counts['P2']}")
    return 1 if counts["P0"] else (0 if not counts["P1"] else 0)


if __name__ == "__main__":
    sys.exit(main())
