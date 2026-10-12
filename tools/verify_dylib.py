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
LC_SYMTAB = 0x2

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64_ALL = 0
CPU_SUBTYPE_ARM64E = 2

PLATFORM_IOS = 2
PLATFORM_NAMES = {2: "iOS"}

# 本工程必须存在的模块证据：
#   ObjC 类（DCLMain/DCLSupport 是纯 C 模块，没有 ObjC 类，单独用符号校验）
REQUIRED_CLASSES = [
    "DCLCrashReporter", "DCLWatchdog", "DCLPlaybackTracer",
    "DCLHealthCheck", "DCLConfig", "DCLHotSwitch", "DCLLogger",
]
# 纯 C 模块的关键符号（证明模块已参与构建）
# 注意：static 函数（如 dcl_watchdog_main）不会有全局符号，不可用于校验，
#       这里只列导出可见的 C 符号。
REQUIRED_SYMBOLS = [
    "DCLNowUs",                  # DCLSupport：微秒时钟
    "DCLMostDerivedMethodOwner", # DCLSupport：方法替换定位
    "DCLASCIISanitized",         # DCLSupport：ASCII 净化
    "dcl_signal_handler",        # DCLCrashReporter：信号处理器
    "dcl_uncaught_exception_handler",  # DCLCrashReporter：OC 异常处理器
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
        off += cmdsize
    return info


def fmt_version(v):
    """Mach-O 版本编码：(major << 16) | (minor << 8) | patch"""
    return f"{v >> 16}.{(v >> 8) & 0xFF}.{v & 0xFF}"


def _read_lc_str(data, cmd_off, str_off):
    start = cmd_off + str_off
    end = data.find(b"\x00", start)
    if end < 0:
        end = len(data)
    return data[start:end].decode("utf-8", "ignore")


def count_mod_init(data, info):
    """统计 __DATA*/__mod_init_func 段的条目数（模块构造函数的证据）。

    segment_command_64（含 cmd+cmdsize 共 72 字节头）：
      0 cmd | 4 cmdsize | 8 segname[16] | 24 vmaddr | 32 vmsize | 40 fileoff
      | 48 filesize | 56 maxprot | 60 initprot | 64 nsects | 68 flags
      → section 数组从 cmd 起始处 +72 开始
    section_64（80 字节）：
      0 sectname[16] | 16 segname[16] | 32 addr | 40 size | 48 offset ...
      → size 在 section 起点 +40

    注意：现代链接器把 __mod_init_func 放进 __DATA_CONST（旧版/其它工具链可能在
    __DATA），两处都认，才能稳定判定"存在模块构造函数"。
    """
    count = 0
    off = 32
    for _ in range(info["ncmds"]):
        if off + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            body = off + 8
            segname = data[body:body + 16].split(b"\x00")[0].decode("ascii", "ignore")
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            sect_off = off + 72  # section 数组起点（含 cmd/cmdsize）
            for _s in range(nsects):
                if sect_off + 80 > len(data):
                    break
                sectname = data[sect_off:sect_off + 16].split(b"\x00")[0].decode("ascii", "ignore")
                size = struct.unpack_from("<Q", data, sect_off + 40)[0]
                if segname in ("__DATA", "__DATA_CONST") and sectname == "__mod_init_func":
                    count += size // 8  # 每项一个函数指针
                sect_off += 80
        off += cmdsize
    return count


def scan_symbol_names(data, info):
    """解析 LC_SYMTAB 的字符串表，返回全部符号名集合。

    LC_SYMTAB 结构：cmd(4) cmdsize(4) symoff(4) nsyms(4) stroff(4) strsize(4)
    直接从 stroff 起取 strsize 字节，按 \\0 切分即可拿到所有符号名。
    """
    names = set()
    off = 32
    for _ in range(info["ncmds"]):
        if off + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        body = off + 8
        if cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, body)
            if 0 < stroff < len(data):
                blob = data[stroff:stroff + strsize]
                for tok in blob.split(b"\x00"):
                    if tok:
                        names.add(tok.decode("utf-8", "ignore"))
        off += cmdsize
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
        minos = fmt_version(bv["minos"])
        sdk = fmt_version(bv["sdk"])
        check(bv["platform"] == PLATFORM_IOS, "平台 = iOS",
              f"{pname} min={minos} sdk={sdk}")

    if args.install_name:
        check(info["install_name"] == args.install_name, "install_name 正确",
              f"{info['install_name']}")
    else:
        check(bool(info["install_name"]), "存在 install_name", info["install_name"] or "")

    mods = count_mod_init(data, info)
    check(mods >= 1, "存在模块构造函数 (__DATA,__mod_init_func)", f"{mods} 个")

    syms = scan_symbol_names(data, info)
    # ObjC 类在符号表里是 _OBJC_CLASS_$_<Name> 形式，用子串匹配更鲁棒；
    # 同时把整个字符串表拼成一个大字串，避免逐符号精确匹配漏掉前缀形式。
    blob = "\n".join(syms)
    missing = [c for c in REQUIRED_CLASSES if c not in blob]
    check(not missing, f"必需模块类齐全（{len(REQUIRED_CLASSES)} 个）",
          "全部命中" if not missing else f"缺失: {', '.join(missing)}")

    missing_sym = [s for s in REQUIRED_SYMBOLS if s not in blob]
    check(not missing_sym, f"必需 C 模块符号齐全（{len(REQUIRED_SYMBOLS)} 个）",
          "全部命中" if not missing_sym else f"缺失: {', '.join(missing_sym)}")

    print("=== 结论 ===")
    if all(ok for ok, _, _ in results):
        print("✅ 全部通过，结构符合 iOS dylib 预期")
        return 0
    print("❌ 存在失败项")
    return 1


if __name__ == "__main__":
    sys.exit(main())
