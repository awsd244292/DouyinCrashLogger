#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
版本号一致性门禁。

插件版本号散在两处，改一处忘另一处是迟早的事：
  · control 的 Version 字段 —— 决定 deb 包名、CI 产出的 dylib 文件名
  · DCLConstants.m 的 DCLPluginVersion —— 写进每份崩溃报告的 "Reporter:" 行

两者一旦漂移，真机上就会出现「日志里写着 1.0，实际装的是 1.3」这种
能把排查方向带偏的事故。本脚本在构建前拦截这种漂移。

用法： python3 scripts/check_version_sync.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read_control_version() -> str | None:
    for line in (ROOT / "control").read_text(encoding="utf-8").splitlines():
        if line.startswith("Version:"):
            return line.split(":", 1)[1].strip()
    return None


def read_code_version() -> str | None:
    m = re.search(
        r'DCLPluginVersion\s*=\s*@"([^"]+)"',
        (ROOT / "DCLConstants.m").read_text(encoding="utf-8"),
    )
    return m.group(1) if m else None


def main() -> int:
    ctl = read_control_version()
    code = read_code_version()

    if ctl is None:
        print("✗ control 里读不到 Version 字段")
        return 1
    if code is None:
        print("✗ DCLConstants.m 里读不到 DCLPluginVersion")
        return 1

    print(f"  control        Version: {ctl}")
    print(f"  DCLConstants.m DCLPluginVersion: {code}")

    if ctl != code:
        print(f"\n✗ 版本号不同步：control={ctl} 代码={code}")
        print("  升版时必须两处一起改，否则崩溃日志里的版本会把排查方向带偏。")
        return 1

    if not re.fullmatch(r"\d+\.\d+-\d+", ctl):
        print(f"\n△ 版本号格式非 Debian 规范（期望 x.y-z）：{ctl}")

    # 提醒：debs 目录里已有同名版本的文件，说明忘了升版
    deb = ROOT.parent / "DouyinCrashLogger-debs" / f"DouyinCrashLogger_{ctl}.dylib"
    if deb.exists():
        print(f"\n△ {deb.name} 已存在，本次构建会覆盖它 —— 确认是有意重打包？")

    print("\n✓ 版本号一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
