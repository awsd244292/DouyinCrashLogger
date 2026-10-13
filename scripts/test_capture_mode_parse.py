#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DCLConfig.m 中 dcl_parse_mode_text 的等价实现回归测试。

为什么值得测：默认开关文件里为了说明，注释行中写满了 "full = B 方案" 这样的字样。
一旦注释过滤失效，默认状态就会被误读成 full（hook 全开），
把「零 hook 保守档」的默认保证悄悄破坏掉 —— 这是最隐蔽也最严重的失效。

三态版新增的第二个重点：off 的判定必须排在 safe / full 之前。
off 是「总开关」维度，不是三档里的一档；若沿用旧顺序，"off"/"no" 会被 safe 分支
先吃掉，用户写「停用」却得到「保守采集」，插件照旧在后台跑 —— 关了等于没关。
"""
import sys

SAFE, FULL, OFF = 0, 1, 2


def parse(text: str) -> int:
    if not text:
        return SAFE
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith(("#", ";", "//")):
            continue
        low = line.lower()
        # —— 总开关：必须最先判定 ——
        if (low in ("off", "disable", "disabled", "kill", "stop", "none", "no")
                or "停用" in low or "关闭" in low or "停止" in low or "禁用" in low):
            return OFF
        if (low in ("full", "b", "1", "on", "yes")
                or "完整" in low or "全量" in low or "full" in low):
            return FULL
        if (low in ("safe", "a", "0")
                or "保守" in low or "safe" in low):
            return SAFE
        return SAFE          # 无法识别 → 最保守
    return SAFE


DEFAULT_FILE = """# DouyinCrashLogger 采集方案开关
#
# safe = A 方案（默认）：零 hook。只抓崩溃、上次退出性质、卡死时长、插件自检。
# full = B 方案：hook 全开。在 A 之上额外抓播放暂停调用栈、触摸时间线、
#                卡死时主线程栈与全线程冻结快照（日志更全）。
# off  = 总开关关闭：卸掉崩溃捕获与全部钩子，插件拒绝一切活动。
#
# 两档下所有钩子均为「原样透传、零吞事件」的旁路观测；
# 若只需证明「有没有崩 / 上次是怎么退的」，保持 safe 即可。
#
# 修改后完全退出并重启抖音生效。
safe
"""

CASES = [
    ("默认生成的文件（注释里含 full 字样）", DEFAULT_FILE, SAFE),
    ("显式切换为 full", DEFAULT_FILE.replace("\nsafe\n", "\nfull\n"), FULL),
    ("大写 FULL", "FULL\n", FULL),
    ("带前后空格与换行", "  full  \n\n", FULL),
    ("空文件", "", SAFE),
    ("只有注释", "# 啥也没写\n", SAFE),
    ("无法识别的内容", "maybe\n", SAFE),
    ("safe 在前 full 在后（取第一个有效行）", "safe\nfull\n", SAFE),
    ("full 在前 safe 在后", "full\nsafe\n", FULL),
    ("中文: 完整", "完整\n", FULL),
    ("中文: 保守", "保守\n", SAFE),
    ("行内注释不被支持（整行视为取值）", "full # 切全量\n", FULL),
    ("BOM 前缀", "﻿full\n", FULL),
    # —— 总开关 off ——
    ("off 档：off", "off\n", OFF),
    ("off 档：大写 OFF", "OFF\n", OFF),
    ("off 档：disable", "disable\n", OFF),
    ("off 档：disabled", "disabled\n", OFF),
    ("off 档：kill", "kill\n", OFF),
    ("off 档：stop", "stop\n", OFF),
    ("off 档：none", "none\n", OFF),
    ("off 档：no", "no\n", OFF),
    ("off 档：中文 停用", "停用\n", OFF),
    ("off 档：中文 关闭", "关闭\n", OFF),
    ("off 档：中文 禁用", "禁用\n", OFF),
    ("off 档：默认文件改写成 off", DEFAULT_FILE.replace("\nsafe\n", "\noff\n"), OFF),
    # 顺序陷阱：off 字样必须先于 safe / full 判定
    ("陷阱：off 与 safe 同行（off 优先）", "off\n", OFF),
    ("陷阱：no 不再被当成 safe", "no\n", OFF),
    ("陷阱：0 仍是 safe（与 1=full 成对）", "0\n", SAFE),
]

fails = 0
print("=" * 72)
print("采集方案开关解析回归测试（等价复现 DCLConfig.m dcl_parse_mode_text）")
print("=" * 72)
NAME = {SAFE: "safe", FULL: "full", OFF: "off"}

for name, text, expect in CASES:
    got = parse(text)
    ok = (got == expect)
    if not ok:
        fails += 1
    print(f"[{'PASS' if ok else 'FAIL'}] {name:<34} 期望={NAME[expect]:<4} "
          f"实际={NAME[got]}")

print("-" * 72)
if fails:
    print(f"结论：{fails} 项失败 —— 开关解析存在缺陷，必须修复后再出包")
else:
    print("结论：全部通过。默认档恒为 safe；显式写 full 才开 hook；写 off 才总关。")
sys.exit(1 if fails else 0)
