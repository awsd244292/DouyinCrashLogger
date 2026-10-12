//
//  DCLSupport.m
//  DouyinCrashLogger
//
//  见 DCLSupport.h 的设计说明。实现刻意保持「短、纯、无隐式依赖」。
//

#import "DCLSupport.h"

#import <sys/time.h>
#import <stdlib.h>
#import <string.h>

static const char dcl_hex_digits[] = "0123456789ABCDEF";

uint64_t DCLNowUs(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
}

BOOL DCLClassOwnsInstanceMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    if (!list) return NO;
    BOOL owned = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) { owned = YES; break; }
    }
    free(list);
    return owned;
}

Class _Nullable DCLMostDerivedMethodOwner(id obj, SEL sel, Class _Nullable stopAtInclusive) {
    if (!obj || !sel) return Nil;
    Class cls = object_getClass(obj);   // 实例真实所属类（含可能的 KVO 动态子类）
    while (cls) {
        if (DCLClassOwnsInstanceMethod(cls, sel)) return cls;
        if (stopAtInclusive && cls == stopAtInclusive) break;
        cls = class_getSuperclass(cls);
    }
    return Nil;
}

BOOL DCLReplaceInstanceMethod(Class cls,
                              SEL sel,
                              const char * _Nullable typeEncoding,
                              void *newImp,
                              void * _Nonnull * _Nonnull outOrig) {
    if (!cls || !sel || !newImp || !outOrig) return NO;
    if (!DCLClassOwnsInstanceMethod(cls, sel)) return NO;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *enc = typeEncoding ?: method_getTypeEncoding(m);
    if (!enc) return NO;

    IMP orig = class_replaceMethod(cls, sel, (IMP)newImp, enc);
    if (!orig) return NO;             // 本类原本无实现 → 无处透传，宁可不挂
    if (orig == (IMP)newImp) return NO; // 再挂一次会形成自环

    *outOrig = (void *)orig;
    return YES;
}

#pragma mark - async-signal-safe 文本拼接

// 说明见 DCLSupport.h。要点只有一个：这些函数是给信号处理器用的，
// 因此绝不分配、绝不触碰 locale、绝不经 ObjC 派发。

size_t DCLStrLenSafe(const char *s) {
    size_t n = 0;
    if (!s) return 0;
    while (s[n]) n++;
    return n;
}

size_t DCLAppendStr(char *buf, size_t off, size_t cap, const char *src) {
    if (!buf || cap == 0) return 0;
    if (off >= cap - 1) return off;      // 已无可用空间（留 1 字节给结尾）
    size_t i = off;
    size_t last = cap - 1;
    if (!src) return off;
    while (*src && i < last) {
        buf[i++] = *src++;
    }
    buf[i] = '\0';
    return i;
}

size_t DCLU64ToDec(uint64_t v, char *out, size_t cap) {
    if (!out || cap == 0) return 0;
    char tmp[24];
    size_t k = 0;
    if (v == 0) {
        tmp[k++] = '0';
    } else {
        while (v > 0 && k < sizeof(tmp)) {
            tmp[k++] = (char)('0' + (int)(v % 10ULL));
            v /= 10ULL;
        }
    }
    size_t n = k < cap ? k : cap;
    // 逆序写回：tmp 里是低位在前
    for (size_t i = 0; i < n; i++) {
        out[i] = tmp[n - 1 - i];
    }
    if (n < cap) out[n] = '\0';
    return n;
}

size_t DCLI64ToDec(int64_t v, char *out, size_t cap) {
    if (!out || cap == 0) return 0;
    if (v < 0) {
        if (cap < 2) { out[0] = '\0'; return 0; }
        out[0] = '-';
        // 先 +1 再取负：-INT64_MIN 直接取负会溢出到它自己
        uint64_t u = (uint64_t)(-(v + 1)) + 1ULL;
        size_t n = DCLU64ToDec(u, out + 1, cap - 1);
        return n + 1;
    }
    return DCLU64ToDec((uint64_t)v, out, cap);
}

NSString *DCLASCIISanitized(NSString * _Nullable s) {
    if (!s || s.length == 0) return @"";

    const char *utf8 = [s UTF8String];
    if (!utf8 || !*utf8) return @"";

    size_t len = strlen(utf8);
    // 上界：每个字节最多展开成 4 个字符（\xNN），再加 1 结尾位。
    size_t cap = len * 4 + 1;
    if (cap > 64 * 1024) cap = 64 * 1024;   // 单行上限，防止恶意超长行把内存吃干
    char *out = (char *)malloc(cap);
    if (!out) return @"(oom)";

    size_t o = 0;
    for (size_t i = 0; i < len && o + 5 < cap; i++) {
        unsigned char c = (unsigned char)utf8[i];
        if (c == '\n' || c == '\t' || (c >= 0x20 && c < 0x7F)) {
            out[o++] = (char)c;
        } else if (c == '\r') {
            // 统一换行，避免 CRLF 在日志里留下肉眼不可见的 ^M
            out[o++] = '\n';
        } else {
            out[o++] = '\\';
            out[o++] = 'x';
            out[o++] = dcl_hex_digits[(c >> 4) & 0xF];
            out[o++] = dcl_hex_digits[c & 0xF];
        }
    }
    out[o] = '\0';

    NSString *res = [NSString stringWithUTF8String:out];
    free(out);
    return res ?: @"";
}
