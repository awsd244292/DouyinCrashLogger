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
- 📲 **摇一摇查看与导出**：在抖音内**摇一摇手机** → 弹出崩溃日志列表 → 点开看详情 → 可一键分享 / 保存 / 清除
- 🪶 **双保险**：自定义日志之外，仍会重新触发默认信号，由系统生成标准 crash report

---

## 原理（为什么能在自签环境跑）

| 能力 | 实现 | 是否依赖 substrate |
|---|---|---|
| 崩溃捕获 | `signal()` / `sigaction()`（POSIX）+ `NSSetUncaughtExceptionHandler` | ❌ 否 |
| 摇一摇入口 | `method_setImplementation()` 原生交换 `UIApplication -sendEvent:` | ❌ 否 |
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
3. 打开抖音，复现崩溃后，**摇一摇**即可看到日志

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

## 日志导出与符号化

- **直接取文件**：日志在抖音沙盒 `Documents/DouyinCrashLogs/`，可用 Filza 或自签工具导出 App 容器取出
- **摇一摇面板**：列表 → 点开详情 → 右上角分享按钮 / 「全部导出」用系统分享（微信、备忘录、文件 App 等）
- **符号化回溯**：日志里是运行时地址 + 镜像名 + 偏移。用 Xcode 的 `atos` 配抖音/系统 dSYM 还原符号：
  ```bash
  atos -o path/to/Aweme.dSYM/.../Aweme -l <镜像基址> <地址>
  ```
  镜像基址可从 `image list -o -f` 或日志中 `dladdr` 给出的偏移推算。

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
