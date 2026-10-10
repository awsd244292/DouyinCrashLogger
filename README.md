# DouyinCrashLogger（抖音崩溃记录）

一个用于**记录抖音 App 崩溃日志**的 iOS Tweak（dylib），适配**自签证书注入 / 巨魔 TrollStore** 场景。
纯 Objective-C runtime 方法交换 + POSIX 信号捕获实现，**不依赖 CydiaSubstrate / ElleKit**，
因此在**无越狱、无注入框架**的自签环境下也能正常工作。

---

## 功能

- 📝 **崩溃捕获**
  - POSIX 信号：`SIGABRT` / `SIGSEGV` / `SIGBUS` / `SIGTRAP` / `SIGILL` / `SIGFPE` / `SIGPIPE`
    （你遇到的 `Fatal signal 5` = `SIGTRAP` 会被捕获）
  - Objective-C 未捕获异常（`NSUncaughtException`）
  - 记录：设备型号、系统版本、抖音包名/版本、**崩溃类型与原因**、故障地址、崩溃线程回溯
- 📂 **日志落盘**：写入抖音沙盒 `Documents/DouyinCrashLogs/`，按时间命名，自动保留最近 20 条
- 📲 **查看与导出**：进入抖音「设置」页 → 点右上角 **📋 崩溃日志** 按钮（或在抖音内**摇一摇**也可）→ 弹出日志列表 → 点开看详情 → 可一键分享 / 保存 / 清除
- 🪶 **双保险**：自定义日志之外，仍会重新触发默认信号，由系统生成标准 crash report

---

## 原理（为什么能在自签环境跑）

| 能力 | 实现 | 是否依赖 substrate |
|---|---|---|
| 崩溃捕获 | `signal()` / `sigaction()`（POSIX）+ `NSSetUncaughtExceptionHandler` | ❌ 否 |
| 设置页入口 | 交换 `UIViewController -viewWillAppear:`（系统类，非抖音私有），用 `title` 命中“设置”页后追加 `UIBarButtonItem` | ❌ 否 |
| 摇一摇入口（备选） | 原生交换 `UIApplication -sendEvent:` | ❌ 否 |
| 日志写入 | 信号处理路径使用 `open/write/fsync/close`（async-signal-safe） | ❌ 否 |

> 全程不使用 Logos `%hook`（那会引入 `_MSHookMessageEx` 等需要 substrate 的符号）。
> 因此即使设备没有 mobilesubstrate，dyld 也能正常加载该 dylib。

---

## 注入到抖音（自签 / 巨魔）

产物是 **`DouyinCrashLogger.dylib`**（fat `arm64` + `arm64e`，无越狱路径残留）。
`control` 已移除 `mobilesubstrate` 依赖。

**方式 A — TrollStore（巨魔，推荐）**
1. 安装 TrollStore + [TrollFools](https://github.com/Lessica/TrollFools)
2. TrollFools → 选**抖音** → 注入 `DouyinCrashLogger.dylib` → 自动重装
3. 打开抖音，进入「设置」页，点右上角 **📋 崩溃日志** 即可看到日志（也可摇一摇触发）

**方式 B — 普通自签（AltStore / Sideloadly / Esign）**
1. 准备抖音砸壳 IPA
2. 注入 dylib（命令行示例）：
   ```bash
   insert_dylib @executable_path/Frameworks/DouyinCrashLogger.dylib \
     Aweme Payload/Aweme.app/Aweme
   ```
   或用 Azule / Sideloadly 的 Tweak 注入功能
3. 用你的自签工具重签并安装（免费证书 7 天需重签）

---

## 日志内容与符号化

崩溃日志包含：
- 设备型号、系统版本、抖音包名/版本（仅用于定位环境，**不含账号等隐私**）
- 崩溃类型与原因（信号名 / OC 异常名 + reason）
- **已加载镜像基址表**（`Image <index> <base> <path>`，启动时一次性采集）
- 崩溃线程回溯：**原始地址**（`#序号 0x...`）

> 为什么信号路径只有地址、没有符号？因为信号 handler 内只调用 `async-signal-safe` 的函数，
> **不调用 `dladdr`**（非安全，易死锁丢栈）。符号化请在 macOS 上用 `atos` 配合日志里的“基址表”：
> ```bash
> # 回溯中某帧 0x1024abcd 属于日志 “Image 12 0x100000000 /var/containers/.../Aweme”
> atos -o /path/to/Aweme.app/Aweme -l 0x100000000 0x1024abcd
> ```
> OC 异常路径（`NSException`）则直接记录 `callStackSymbols`，可读性更好。

## 隐私说明（重要）

- 日志**仅保存在本机沙盒**，**绝不自动上传**；UI 内“分享/导出”需你**手动触发**。
- 只收集堆栈、信号、版本等基础调试信息，**不读取、不记录任何 token / cookie / 私信 / 浏览记录**。
- 自动循环保留最近 20 条，超出即删，不会持续占用存储。

## 日志导出

- **直接取文件**：日志在抖音沙盒 `Documents/DouyinCrashLogs/`，可用 Filza 或自签工具导出 App 容器取出
- **设置页入口 / 摇一摇**：列表 → 点开详情 → 右上角分享按钮 / 「全部导出」用系统分享（微信、备忘录、文件 App 等）

---

## 构建

仓库自带 `.github/workflows/build.yml`，在 GitHub 云端 macOS runner 上用 `theos-action`
自动装 Theos + iOS SDK 编译，默认只产出**单一 `DouyinCrashLogger.dylib`**
（rootful 包提取，零越狱路径残留；如需 `.deb` 可在 Run workflow 时把 scheme 选成 `all`）。

本地 macOS 构建（需 Theos）：
```bash
make package FINALPACKAGE=1
# 产物在 packages/ 下
```

---

## 免责声明

仅供个人学习、调试、研究使用。请勿用于任何商业或分发用途。
记录的是你**自己设备**上抖音的崩溃信息，不收集任何隐私数据，全部仅保存在本机沙盒。
