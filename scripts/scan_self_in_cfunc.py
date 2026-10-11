#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
扫描所有 .m：找出「C 函数体内使用了 self / _cmd」的编译阻断错误。

背景：ObjC 的 self / _cmd 只在方法（实例/类方法）中隐式存在。
static C 函数里写 [self xxx] 会直接报
    error: use of undeclared identifier 'self'
这类代码在只做静态评审、未编译时最容易漏网 —— 而这个项目的 1.3 版本
恰恰是「先实现、未构建」的状态，风险集中在这里。

判定：以 ^static 开头的行进入 C 函数体，括号深度归零即退出；
      在函数体内出现 [self ...] 视为错误；
      参数列表里把 self 当形参名（如 static void dcl_pause(id self, SEL _cmd)）是合法的，排除。
"""
import re
import sys
from pathlib import Path

# 相对本脚本定位工程根目录，换机器/换路径都可直接运行
ROOT = Path(__file__).resolve().parent.parent
hits = []

for m in sorted(ROOT.glob("*.m")):
    lines = m.read_text(encoding="utf-8").splitlines()
    depth = 0
    in_func = False
    func_start = 0
    for i, line in enumerate(lines, 1):
        stripped = line.strip()

        if not in_func and re.match(r"^static\b", line):
            # 排除纯变量定义：static int x = 1; 之类（以 ; 结尾且无 {）
            if "{" in line or (i + 1 < len(lines) and lines[i].strip().startswith("{")):
                in_func = True
                func_start = i
                depth = 0

        if in_func:
            depth += line.count("{") - line.count("}")
            # 参数行里的 (id self, SEL _cmd) 合法，跳过；只查函数体
            body_started = depth > 0 or func_start != i
            if body_started and re.search(r"\[self\s", line):
                hits.append((m.name, i, lines[func_start - 1].strip()[:60], stripped))
            if depth <= 0 and func_start != i:
                in_func = False
                depth = 0

print("=" * 78)
print("扫描：static C 函数体内是否误用 self（会导致编译失败）")
print("=" * 78)
if not hits:
    print("未发现问题：所有 [self ...] 均位于合法的 ObjC 方法内。")
else:
    for name, ln, sig, code in hits:
        print(f"[错误] {name}:{ln}")
        print(f"       所属函数: {sig}")
        print(f"       问题代码: {code}")
    print("-" * 78)
    print(f"共 {len(hits)} 处 —— 必须改为 [类名 方法名] 才能编译通过。")
sys.exit(1 if hits else 0)
