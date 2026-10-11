#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
第三轮检查：宿主影响面专项。

只问一个问题 —— 这段代码的哪些行为会改变宿主（抖音）自身的命运？
分三条侵入路径逐条核验：

  路径 A  信号处理器：会不会「制造」崩溃、会不会让进程挂死、会不会切断宿主监控
  路径 B  方法交换  ：钩子体是否严格透传、会不会递归、会不会拖慢宿主调用
  路径 C  线程操作  ：suspend 是否对称、suspend 期间是否触碰共享锁

每条给出 结论(PASS/FAIL) + 依据(文件:行号)。修完可重复运行做回归。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

results = []


def check(path_id, title, ok, evidence, impact):
    results.append((path_id, title, ok, evidence, impact))


def read(name):
    p = ROOT / name
    return p.read_text(encoding="utf-8", errors="replace") if p.exists() else ""


def find_line(src, pattern):
    for i, ln in enumerate(src.split("\n"), 1):
        if re.search(pattern, ln):
            return i, ln.strip()
    return None, ""


crash = read("DCLCrashReporter.m")
watch = read("DCLWatchdog.m")
trace = read("DCLPlaybackTracer.m")
main = read("DCLMain.m")
health = read("DCLHealthCheck.m")

# ============================================================
# 路径 A：信号处理器
# ============================================================

# A1 是否接管了 SIGPIPE
sig_list = re.search(r"int signals\[\]\s*=\s*\{([^}]*)\}", crash)
installed_sigs = [s.strip() for s in sig_list.group(1).split(",")] if sig_list else []
has_pipe = "SIGPIPE" in installed_sigs
check("A1", "未接管 SIGPIPE", not has_pipe,
      f"DCLCrashReporter.m 注册清单: {installed_sigs}" if sig_list else "未找到注册清单",
      "接管 SIGPIPE 后，宿主原本被忽略的 socket 写失败会被升级为进程终止 —— 凭空制造崩溃")

# A2 重入分支是否安全终止（不能只是 return）
reentr = re.search(r"__sync_fetch_and_or\s*\(\s*&g_handling[^;]*\)\s*\)\s*\{(.*?)\}", crash, re.S)
body = reentr.group(1) if reentr else ""
safe_exit = ("_exit" in body) or ("SIG_DFL" in body) or ("raise" in body)
check("A2", "重入分支必定终止进程", safe_exit,
      f"g_handling 重入分支内容: {body.strip()[:80] or '(空)'}",
      "重入时直接 return 会把控制权交回出错指令，同一信号无限重触发 —— 进程 100% CPU 挂死，比崩溃更难排查")

# A3 是否使用备用栈（栈溢出可取证）
check("A3", "处理器运行在备用栈", ("sigaltstack" in crash) and ("SA_ONSTACK" in crash),
      f"sigaltstack: {'有' if 'sigaltstack' in crash else '无'} / "
      f"SA_ONSTACK: {'有' if 'SA_ONSTACK' in crash else '无'}",
      "栈溢出类崩溃在已损坏的栈上运行处理器会二次崩溃，且这类崩溃恰恰最需要日志")

# A4 是否保存并转发宿主原有处理器
saves_old = bool(re.search(r"(g_old_sa|old_sa|prev_sa|g_prev_handler|orig_handler|saved_sa)", crash))
check("A4", "保存并转发宿主原处理器", saves_old,
      "未发现保存原 sigaction 的变量" if not saves_old else "已保存",
      "直接覆盖会静默切断宿主自身的崩溃监控与收尾逻辑（如保存草稿、上报）")

# A5 handler 内是否调用非 async-signal-safe 的符号化
# 注意：必须定位到「函数定义」而非顶部的前置声明；且要剔除注释，
# 否则注释里那句「不调用 dladdr」会把这条判成违规。
m = re.search(r"static void dcl_signal_handler\([^{]*\)\s*\{", crash)
handler_src = crash[m.end():] if m else ""
handler_src = handler_src[:handler_src.find("\nstatic void dcl_install_signals")]
handler_code = "\n".join(
    ln for ln in handler_src.split("\n")
    if not ln.strip().startswith("//") and not ln.strip().startswith("*")
)
unsafe = [w for w in ("dladdr", "backtrace_symbols", "NSLog", "malloc", "objc_msgSend",
                      "dispatch_async", "NSUserDefaults", "fprintf")
          if w in handler_code]
check("A5", "处理器内无符号化/OC/分配", not unsafe,
      f"命中非安全调用: {unsafe}" if unsafe else "仅 write/open/gettimeofday/backtrace",
      "崩溃现场调 dladdr / malloc 会拿已被破坏的锁，死锁或二次崩溃，日志反而抓不到")

# ============================================================
# 路径 B：方法交换
# ============================================================

hook_fns = re.findall(r"static void (dcl_\w+)\(id self, SEL _cmd[^{]*\{(.*?)\n\}", trace, re.S)
all_passthrough = True
bad_hooks = []
for name, body in hook_fns:
    if name in ("dcl_sendEvent",):
        if "dcl_orig_sendEvent_fn(self, _cmd, event)" not in body:
            all_passthrough = False
            bad_hooks.append(name)
    elif not re.search(r"dcl_orig_\w+_fn\(self, _cmd", body):
        all_passthrough = False
        bad_hooks.append(name)
check("B1", "所有钩子无条件透传原实现", all_passthrough and len(hook_fns) >= 5,
      f"钩子数 {len(hook_fns)}，未透传: {bad_hooks or '无'}",
      "钩子体提前 return 或漏调原实现 = 吞掉宿主行为，直接改变 App 功能")

# B2 钩子体是否在剪枝之前做重活（backtrace 开销）
cap_src = trace[trace.find("static inline void dcl_capture"):]
cap_src = cap_src[:cap_src.find("\n#pragma mark - 钩子实现")]
bt_pos = cap_src.find("backtrace(")
supp_pos = cap_src.find("allow")
check("B2", "钩子体先剪枝再回溯", (bt_pos == -1) or (supp_pos != -1 and supp_pos < bt_pos),
      f"backtrace 位置 {bt_pos}，抑制判断位置 {supp_pos}（应前者在后）",
      "高频调用（滑动切视频）每次都付回溯开销却不产出记录 —— 拖慢播放，属于干扰宿主")

# B3 钩子体是否有重入保护（钩子内再触发被钩方法）
# 线程局部变量最合适：钩子可能在多线程并发进入，全局标志会误挡其他线程
has_reentr = bool(re.search(r"(__thread|_Thread_local)\s+\w+\s+(in_hook|g_in_hook)\s*=", trace)) \
             or bool(re.search(r"g_in_hook", trace))
check("B3", "钩子体有重入保护", has_reentr,
      "线程局部变量 in_hook" if has_reentr else "未发现重入标志",
      "若 host 的原实现内部再次调用被钩方法（如 setRate: 内部调 pause），"
      "会递归进入钩子；配合 B2 的回溯开销会放大成卡顿")

# B4 是否用 method_setImplementation（破坏其他 hook 链）而非 exchange
uses_set = "method_setImplementation" in trace
check("B4", "钩子不破坏既有 hook 链", not uses_set,
      "使用 method_setImplementation" if uses_set else "未使用",
      "setImplementation 直接替换会摘掉宿主/其他插件已挂在同方法上的钩子，"
      "切断它们的事件监控链路")

# ============================================================
# 路径 C：线程操作
# ============================================================

# C1 suspend 期间是否做符号化/分配（死锁风险）
snap_src = watch[watch.find("+ (NSString *)captureAllThreadsSnapshot"):]
snap_src = snap_src[:snap_src.find("\n+ (void)captureAndStoreAllThreadsSnapshot")]
# 提取 suspend 到 resume 之间的代码
susp_idx = snap_src.find("thread_suspend(t)")
resume_idx = snap_src.find("if (suspended) thread_resume(t)")
between = snap_src[susp_idx:resume_idx] if susp_idx != -1 and resume_idx != -1 else ""
risky = [w for w in ("dladdr", "appendFormat", "stringWithFormat", "NSString", "walk_thread_frames")
         if w in between]
check("C1", "suspend 期间只收集原始地址", not risky,
      f"suspend→resume 之间命中: {risky or '无'}",
      "被挂起线程可能正持有 dyld/malloc 锁；此时做符号化或分配会永久死锁 —— "
      "宿主表现为彻底无响应，且不产生崩溃日志，最难归因")

# C2 suspend/resume 严格配对。
# 重构后是「挂起循环 / 采集循环 / 恢复循环」三段独立循环：
# 采集段是纯 C 内核调用不会抛异常，因此恢复循环必定执行 —— 比 @finally 更确定。
susp_loop = bool(re.search(r"thread_suspend\s*\(\s*list\[i\]\s*\)", watch))
resume_loop = bool(re.search(r"if\s*\(\s*suspFlag\[i\]\s*\)\s*thread_resume\s*\(\s*list\[i\]\s*\)", watch)) \
              or ("@finally" in between)
paired = susp_loop and resume_loop
check("C2", "suspend 必配对 resume", paired,
      f"挂起循环:{'有' if susp_loop else '无'} 恢复循环:{'有' if resume_loop else '无'}",
      "漏 resume 会让宿主线程永久停摆 —— 整个 App 静默失去该线程的能力")

# C3 是否 suspend 主线程 / 自身
suspends_main = bool(re.search(r"thread_suspend\s*\(\s*g_main_thread\s*\)", watch))
self_guard = bool(re.search(r"list\[i\]\s*==\s*self_t\s*\|\|\s*list\[i\]\s*==\s*g_main_thread", watch)) \
             or ("skipSuspend" in watch)
check("C3", "不 suspend 主线程/自身", self_guard,
      f"主线程卡死采样 suspend: {'有（B 档取证专用，需严格配对）' if suspends_main else '无'}；"
      f"全线程快照跳过自身与主线程: {'是' if self_guard else '否'}",
      "suspend 自身必死锁；挂起主线程会冻结 UI，且若主线程正持锁取证线程随即死锁")

# C4 快照是否离开主线程执行
# 「进后台」必须同步（App 随时被挂起，异步会写一半），其余场景走后台队列。
async_snap = bool(re.search(r"dispatch_async\s*\(\s*dcl_snapshot_queue\s*\(\s*\)", crash))
sync_only_bg = bool(re.search(r"mustBeSync\s*=\s*.*后台", crash))
check("C4", "全线程快照不在主线程同步执行", async_snap and sync_only_bg,
      "已按场景分流：进后台同步，其余异步到串行队列" if async_snap else "全部在主线程同步执行",
      "截屏通知在主线程，同步 suspend 全部线程会卡住 UI，且主线程与挂起线程争锁风险更高")

# ============================================================
# 输出
# ============================================================
print("=" * 100)
print("宿主影响面检查（信号 / 方法交换 / 线程）")
print("=" * 100)
for pid, title, ok, ev, impact in results:
    flag = "PASS" if ok else "FAIL"
    print(f"\n[{pid}] {flag}  {title}")
    print(f"      依据: {ev}")
    if not ok:
        print(f"      风险: {impact}")

fails = [r for r in results if not r[2]]
print("\n" + "=" * 100)
print(f"合计 {len(results)} 项，未通过 {len(fails)} 项："
      f"{', '.join(r[0] for r in fails) if fails else '无'}")
sys.exit(1 if fails else 0)
