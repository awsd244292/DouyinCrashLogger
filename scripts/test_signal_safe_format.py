#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
信号处理器内手写数字格式化函数的正确性与边界测试。

背景：崩溃处理器不能用 snprintf（不在 POSIX async-signal-safe 白名单，
      可能触碰 locale / 内部分配），因此 DCLCrashReporter.m 里手写了
      dcl_u64_to_hex / dcl_u64_to_dec / dcl_u64_to_dec_pad /
      dcl_i64_to_dec / dcl_append_str 五个函数。
      手写转换最容易出的就是缓冲区边界与位数错误，而这种错误平时
      完全测不到 —— 只有真崩溃那一刻才会暴露。
      本脚本直接从 DCLCrashReporter.m 抽取这五个函数的真实实现，
      与 snprintf 做逐字节对照，并在 ASan/UBSan 下跑截断边界。

用法： python3 scripts/test_signal_safe_format.py
依赖： gcc（clang 亦可，自动探测）
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "DCLCrashReporter.m"
FUNCS = [
    "dcl_u64_to_hex",
    "dcl_u64_to_dec",
    "dcl_u64_to_dec_pad",
    "dcl_i64_to_dec",
    "dcl_append_str",
]


def extract(name: str) -> str:
    """从源码中按大括号配平抽取一个 static 函数的完整定义。"""
    marker = "static size_t " + name + "("
    i = SRC.read_text(encoding="utf-8").find(marker)
    if i < 0:
        raise SystemExit(f"未能在 {SRC.name} 中找到 {name}；函数名是否改过？")
    s = SRC.read_text(encoding="utf-8")
    j = s.index("{", i)
    depth, k = 0, j
    while True:
        if s[k] == "{":
            depth += 1
        elif s[k] == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    return s[i : k + 1]


TEST_C = r"""
#include <stdio.h>
#include <inttypes.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
__FUNCS__

static int fails = 0;
static void ck(const char *got, const char *want, const char *what) {
    if (strcmp(got, want) != 0) {
        printf("FAIL %s: got=\"%s\" want=\"%s\"\n", what, got, want);
        fails++;
    }
}

int main(void) {
    char b[64], ref[64];

    /* 1. 与 snprintf 逐字节对照（含边界值） */
    uint64_t vals[] = {0, 1, 9, 10, 15, 16, 255, 4095, 4096, 0xdeadbeefULL,
                       0xffffffffULL, 0x7fffffffffffffffULL, UINT64_MAX,
                       1000000007ULL, 999999ULL, 1000000ULL};
    for (unsigned i = 0; i < sizeof(vals)/sizeof(vals[0]); i++) {
        memset(b, 0xAA, sizeof(b));
        dcl_u64_to_hex(vals[i], b, sizeof(b));
        snprintf(ref, sizeof(ref), "%" PRIx64, vals[i]);
        ck(b, ref, "hex");

        memset(b, 0xAA, sizeof(b));
        dcl_u64_to_dec(vals[i], b, sizeof(b));
        snprintf(ref, sizeof(ref), "%" PRIu64, vals[i]);
        ck(b, ref, "dec");
    }

    /* 2. 有符号（signal code 可为负），含 INT64_MIN 取负溢出陷阱 */
    int64_t iv[] = {0, -1, 1, -2147483648LL, 2147483647LL,
                    INT64_MIN, INT64_MAX, -42, -999999};
    for (unsigned i = 0; i < sizeof(iv)/sizeof(iv[0]); i++) {
        memset(b, 0xAA, sizeof(b));
        dcl_i64_to_dec(iv[i], b, sizeof(b));
        snprintf(ref, sizeof(ref), "%" PRId64, iv[i]);
        ck(b, ref, "idec");
    }

    /* 3. 补零必须与 %06llu 完全等价。
          崩溃日志列表按文件名字符串排序（crashLogsDirectory 下的
          crash_<epoch>_<usec>_P<pid>.log），不补零会把同一秒内的
          多次崩溃排出错序 —— 这是引入手写函数时踩过的真回归。 */
    for (int i = 0; i < 3000; i++) {
        uint64_t us = (uint64_t)(rand() % 1000000ULL);
        memset(b, 0xAA, sizeof(b));
        dcl_u64_to_dec_pad(us, b, sizeof(b), 6);
        snprintf(ref, sizeof(ref), "%06" PRIu64, us);
        ck(b, ref, "pad6");
    }

    /* 4. 截断安全性：堆上精确分配 cap 字节，ASan 直接抓越界。
          生产代码全是 buf+off 形式，因此非零偏移也要覆盖。 */
    for (size_t cap = 0; cap <= 8; cap++) {
        size_t alloc = cap ? cap : 1;
        char *hb = (char *)malloc(alloc);
        memset(hb, 0x41, alloc);
        if (dcl_u64_to_dec(UINT64_MAX, hb, cap) > cap) { printf("FAIL dec cap=%zu\n", cap); fails++; }
        if (cap && strlen(hb) > cap - 1) { printf("FAIL dec NUL cap=%zu\n", cap); fails++; }

        memset(hb, 0x41, alloc);
        if (dcl_i64_to_dec(INT64_MIN, hb, cap) > cap) { printf("FAIL idec cap=%zu\n", cap); fails++; }
        if (cap && strlen(hb) > cap - 1) { printf("FAIL idec NUL cap=%zu\n", cap); fails++; }

        memset(hb, 0x41, alloc);
        if (dcl_u64_to_dec_pad(UINT64_MAX, hb, cap, 6) > cap) { printf("FAIL pad cap=%zu\n", cap); fails++; }
        if (cap && strlen(hb) > cap - 1) { printf("FAIL pad NUL cap=%zu\n", cap); fails++; }

        memset(hb, 0x41, alloc);
        if (dcl_u64_to_hex(UINT64_MAX, hb, cap) > cap) { printf("FAIL hex cap=%zu\n", cap); fails++; }
        if (cap && strlen(hb) > cap - 1) { printf("FAIL hex NUL cap=%zu\n", cap); fails++; }

        memset(hb, 0x41, alloc);
        if (dcl_append_str(hb, 0, cap, "0123456789abcdef") > cap) { printf("FAIL astr cap=%zu\n", cap); fails++; }
        if (cap && strlen(hb) > cap - 1) { printf("FAIL astr NUL cap=%zu\n", cap); fails++; }

        memset(hb, 0x41, alloc);
        size_t off = cap ? cap - 1 : 0;   /* 贴近末尾的偏移 */
        if (dcl_append_str(hb, off, cap, "xyz") > cap) { printf("FAIL astr off cap=%zu\n", cap); fails++; }
        if (cap && strlen(hb + off) > cap - off - 1) { printf("FAIL astr off NUL cap=%zu\n", cap); fails++; }

        free(hb);
    }

    /* 5. 完整路径拼接复现，必须与旧 snprintf 写法逐字节等价 */
    for (int trial = 0; trial < 500; trial++) {
        long long ep  = (long long)rand() % 2000000000LL;
        long long us  = (long long)(rand() % 1000000LL);
        long long pid = (long long)(rand() % 100000LL);
        char mine[2048], theirs[2048];
        size_t p = 0;
        p  = dcl_append_str(mine, p, sizeof(mine), "/var/mobile/x");
        p  = dcl_append_str(mine, p, sizeof(mine), "/crash_");
        p += dcl_u64_to_dec((uint64_t)ep, mine + p, sizeof(mine) - p);
        p  = dcl_append_str(mine, p, sizeof(mine), "_");
        p += dcl_u64_to_dec_pad((uint64_t)us, mine + p, sizeof(mine) - p, 6);
        p  = dcl_append_str(mine, p, sizeof(mine), "_P");
        p += dcl_u64_to_dec((uint64_t)pid, mine + p, sizeof(mine) - p);
        p  = dcl_append_str(mine, p, sizeof(mine), ".log");
        snprintf(theirs, sizeof(theirs),
                 "/var/mobile/x/crash_%lld_%06lld_P%lld.log", ep, us, pid);
        ck(mine, theirs, "path");
    }

    /* 注意：不要用一个三元 ?: 切换含 %d / %s 的格式串再统一传参 ——
       变参不会按格式串重新对齐，会把 int 当成 char* 读。分开写。 */
    if (fails) {
        printf("\n=== %d 处失败 ===\n", fails);
    } else {
        printf("\n=== 全部通过（%s 编译 + ASan/UBSan）===\n", "__CC__");
    }
    return fails != 0;
}
"""


def main() -> int:
    cc = None
    for cand in ("gcc", "clang"):
        if subprocess.run(["which", cand], capture_output=True).returncode == 0:
            cc = cand
            break
    if not cc:
        print("跳过：未找到 gcc/clang，无法编译验证")
        return 0

    with tempfile.TemporaryDirectory() as td:
        inc = os.path.join(td, "funcs.inc")
        with open(inc, "w", encoding="utf-8") as f:
            f.write("\n".join(extract(n) for n in FUNCS))
        c = os.path.join(td, "t.c")
        with open(c, "w", encoding="utf-8") as f:
            f.write(TEST_C.replace("__FUNCS__", '#include "funcs.inc"')
                          .replace("__CC__", cc))
        exe = os.path.join(td, "t")
        # clang 在本机常缺 sanitizer runtime，失败则退回普通编译
        san = ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"]
        r = subprocess.run([cc, "-O1", "-Wall", "-Wextra", *san,
                            "-I", td, "-o", exe, c], capture_output=True)
        if r.returncode != 0:
            r = subprocess.run([cc, "-O1", "-Wall", "-Wextra",
                                "-I", td, "-o", exe, c], capture_output=True)
            if r.returncode != 0:
                print(r.stderr.decode(errors="replace"))
                return 1
            print("（警告：sanitizer runtime 不可用，已退化为普通编译）")
        else:
            print("（以 ASan + UBSan 运行）")
        p = subprocess.run([exe])
        return p.returncode


if __name__ == "__main__":
    sys.exit(main())
