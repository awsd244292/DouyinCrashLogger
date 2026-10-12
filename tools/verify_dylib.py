#!/usr/bin/env python3
"""
verify_dylib.py — 纯 Python 的 Mach-O 结构自检（不需要任何 Apple 工具 / 不需要 Mac）

原理：Mach-O 格式是公开文档（Apple mach-o/loader.h），二进制结构固定。
读字节 → 按结构体解析 → 比对期望值，即可在 Linux 上完成交付前校验。

用法：
    python3 tools/verify_dylib.py build/DouyinCrashLogger.dylib \
        --install-name @rpath/DouyinCrashLogger.dylib

退出码：0=全部通过；1=存在失败项；2=参数/读取错误
"""
import argparse
import struct
import sys

# ---- Mach-O 常量 ----------------------------------------------------------
MH_MAGIC_64 = 0xFEEDFACF
MH_DYLIB = 0x6
LC_BUILD_VERSION = 0x32
LC_ID_DYLIB = 0xD
LC_SEGMENT_64 = 0x19

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64_ALL = 0
CPU_SUBTYPE_ARM64E = 2

PLATFORM_IOS = 2
PLATFORM_NAMES = {2: "iOS"}

# 本工程必须存在的模块类（编入符号表即证明对应模块已参与构建）
REQUIRED_CLASSES = [
    "DCLMain", "DCLCrashReporter", "DCLWatchdog", "DCLPlaybackTracer",
    "DCLHealthCheck", "DCLConfig", "DCLHotSwitch", "DCLLogger", "DCLSupport",
]

results = []


def check(ok, label, detail=""):
    results.append((ok, label, detail))
    mark = "✅" if ok else "❌"
    line = f"  {mark} {label}"
    if detail:
        line += f"  —— {detail}"
    print(line)


def parse_macho(data):
    """解析 Mach-O 头 + load commands，返回结构化信息字典。"""
    if len(data) < 32:
        raise ValueError("文件过小，不是合法 Mach-O")
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from(
        "<IiiIIIII", data, 0
    )
    if magic != MH_MAGIC_64:
        raise ValueError(f"magic=0x{magic:08X}，非 64 位 Mach-O（期望 0x{MH_MAGIC_64:08X}）")

    info = {
        "cputype": cputype,
        "cpusubtype": cpusubtype & 0x00FFFFFF,
        "filetype": filetype,
        "ncmds": ncmds,
        "build_version": None,
        "install_name": None,
        "mod_init_funcs": 0,
    }

    off = 32  # 64 位 header 大小
    for _ in range(ncmds):
        if off + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        body = off + 8
        if cmd == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack_from("<III", data, body)
            info["build_version"] = {
                "platform": platform,
                "minos": minos,
                "sdk": sdk,
            }
        elif cmd == LC_ID_DYLIB:
            name_off = struct.unpack_from("<I", data, body)[0]
            info["install_name"] = _read_lc_str(data, off, name_off)
        elif cmd == LC_SEGMENT_64:
            segname = data[body:body + 16].split(b"\x00")[0].decode("ascii", "ignore")
            nsects = struct.unpack_from("<I", data, body + 48 - 8)[0] if False else None
        off += cmdsize
    return info


def _read_lc_str(data, cmd_off, str_off):
    start = cmd_off + str_off
    end = data.find(b"\x00", start)
    if end < 0:
        end = len(data)
    return data[start:end].decode("utf-8", "ignore")


def count_mod_init(data, info):
    """统计 __DATA,__mod_init_func 段的条目数（模块构造函数的证据）。"""
    count = 0
    off = 32
    for _ in range(info["ncmds"]):
        if off + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        body = off + 8
        if cmd == LC_SEGMENT_64:
            segname = data[body:body + 16].split(b"\x00")[0].decode("ascii", "ignore")
            nsects = struct.unpack_from("<I", data, body + 48)[0]
            sect_off = body + 72
            for _s in range(nsects):
                sectname = data[sect_off:sect_off + 16].split(b"\x00")[0].decode("ascii", "ignore")
                size = struct.unpack_from("<Q", data, sect_off + 40)[0]
                if segname == "__DATA" and sectname == "__mod_init_func":
                    count += size // 8  # 每项一个函数指针
                sect_off += 80
        off += cmdsize
    return count


def scan_symbol_names(data):
    """粗扫 LC_SYMTAB 字符串表，返回可打印符号名集合（宽松匹配，够用即可）。"""
    names = set()
    # 直接在整个文件里找 '_\x00' 结尾的可打印串，做子串匹配即可覆盖类名
    i = 0
    n = len(data)
    cur = bytearray()
    while i < n:
        c = data[i]
        if 0x20 <= c < 0x7F:
            cur.append(c)
        else:
            if len(cur) >= 4:
                names.add(cur.decode("ascii", "ignore"))
            cur = bytearray()
        i += 1
    if len(cur) >= 4:
        names.add(cur.decode("ascii", "ignore"))
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dylib")
    ap.add_argument("--install-name", default=None)
    args = ap.parse_args()

    try:
        with open(args.dylib, "rb") as fh:
            data = fh.read()
    except OSError as e:
        print(f"❌ 无法读取 {args.dylib}: {e}")
        return 2

    size_kb = len(data) // 1024
    print(f"=== Mach-O 结构自检: {args.dylib} ({size_kb} KB) ===")

    try:
        info = parse_macho(data)
    except ValueError as e:
        print(f"❌ 解析失败：{e}")
        return 1

    check(info["filetype"] == MH_DYLIB, "文件类型 = MH_DYLIB",
          f"filetype={info['filetype']}")

    is_arm64 = info["cputype"] == CPU_TYPE_ARM64
    sub = info["cpusubtype"]
    sub_name = {CPU_SUBTYPE_ARM64_ALL: "arm64 (ALL)", CPU_SUBTYPE_ARM64E: "arm64e"}.get(
        sub, f"0x{sub:X}")
    check(is_arm64, "CPU 架构 = arm64", f"cputype=0x{info['cputype']:X} / cpusubtype={sub_name}")

    bv = info["build_version"]
    if bv is None:
        check(False, "平台 = iOS", "未找到 LC_BUILD_VERSION")
    else:
        pname = PLATFORM_NAMES.get(bv["platform"], f"0x{bv['platform']:X}")
        minos = f"{bv['minos'] >> 16}.{bv['minos'] & 0xFFFF}"
        sdk = f"{bv['sdk'] >> 16}.{bv['sdk'] & 0xFFFF}"
        check(bv["platform"] == PLATFORM_IOS, "平台 = iOS",
              f"{pname} min={minos} sdk={sdk}")

    if args.install_name:
        check(info["install_name"] == args.install_name, "install_name 正确",
              f"{info['install_name']}")
    else:
        check(bool(info["install_name"]), "存在 install_name", info["install_name"] or "")

    mods = count_mod_init(data, info)
    check(mods >= 1, "存在模块构造函数 (__DATA,__mod_init_func)", f"{mods} 个")

    syms = scan_symbol_names(data)
    missing = [c for c in REQUIRED_CLASSES if c not in syms]
    check(not missing, f"必需模块类齐全（{len(REQUIRED_CLASSES)} 个）",
          "全部命中" if not missing else f"缺失: {', '.join(missing)}")

    print("=== 结论 ===")
    if all(ok for ok, _, _ in results):
        print("✅ 全部通过，结构符合 iOS dylib 预期")
        return 0
    print("❌ 存在失败项")
    return 1


if __name__ == "__main__":
    sys.exit(main())
