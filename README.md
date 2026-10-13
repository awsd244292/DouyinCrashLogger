# DouyinCrashLogger（抖音崩溃记录）

一个用于**记录抖音 App 崩溃日志**的 iOS Tweak（dylib），适配**自签证书注入 / 巨魔 TrollStore** 场景。
纯 Objective-C runtime 方法交换 + POSIX 信号捕获实现，**不依赖 CydiaSubstrate / ElleKit**，
因此在**无越狱、无注入框架**的自签环境下也能正常工作。

---

## 功能

- 📝 **崩溃捕获**
  - POSIX 信号：`SIGABRT` / `SIGSEGV` / `SIGBUS` / `SIGTRAP` / `SIGILL` / `SIGFPE`
    （你遇到的 `Fatal signal 5` = `SIGTRAP` 会被捕获；`SIGPIPE` 故意**不**接管——iOS App 普遍把它设为 `SIG_IGN`，一旦接管，任何一次 socket 写失败都会被误升为崩溃，看起来像"抖音又闪退了"）
  - Objective-C 未捕获异常（`NSUncaughtException`）
  - 记录：设备型号、系统版本、抖音包名/版本、**崩溃类型与原因**、故障地址、崩溃线程回溯
- 📂 **日志落盘**：写入抖音沙盒 `Documents/DouyinCrashLogs/`，按时间命名，自动保留最近 20 条
- 📂 **查看方式：直接读容器**（极简版**没有任何 App 内 UI、不 hook 任何方法**）
  - 崩溃日志：`Documents/DouyinCrashLogs/crash_<时间戳>_P<pid>.log`
  - 运行时日志：`Documents/DouyinCrashLogs/plugin_runtime.log`（含每次启动的「上次退出状态」标记）
  - 用 Filza / 自签工具导出抖音 App 容器即可读取
- 🪶 **双保险**：自定义日志之外，仍会重新触发默认信号，由系统生成标准 crash report

---

## 原理（为什么能在自签环境跑）

| 能力 | 实现 | 是否依赖 substrate |
|---|---|---|
| 崩溃捕获 | `signal()` / `sigaction()`（POSIX）+ `NSSetUncaughtExceptionHandler` | ❌ 否 |
| **零 Hook** | 极简版**不交换任何方法、不注入任何 UI**，只做信号/异常捕获 + 文件写入，把对宿主的干扰降到最低 | ❌ 否 |
| 退出状态标记 | `NSUserDefaults` 记录上次是否走 `WillTerminate` 正常退出 + 注册终止观察者，并**追加写入 `plugin_runtime.log`** | ❌ 否 |
| 运行时日志 | 延迟块内 `freopen` 把 `stderr/stdout` 重定向到沙盒 `plugin_runtime.log` | ❌ 否 |
| 日志写入 | 信号处理路径使用 `open/write/fsync/close`（async-signal-safe） | ❌ 否 |

> 全程不使用 Logos `%hook`（那会引入 `_MSHookMessageEx` 等需要 substrate 的符号）。
> 因此即使设备没有 mobilesubstrate，dyld 也能正常加载该 dylib。

> **捕获层与抖音彻底解耦（代码核实，见 `DCLCrashReporter.m` 全文 + 工程 grep）**：
> 不仅不依赖 substrate，也**不 hook 任何一个抖音 / `Aweme` 私有类**——
> 崩溃捕获只装 POSIX 信号 + `NSSetUncaughtExceptionHandler`，与被注入 App 的 UI / 私有实现零耦合。
> 因此**抖音版本迭代不会让"崩溃捕获"本身失效**。工程里仅有的两处抖音耦合都属于可降级项：
> ① 可选的"播放暂停诊断"探针（hook 的是公开类 `AVPlayer`，属增强而非核心捕获）；
> ② 设置入口：**双通道**（详见 `DCLSettings.m` 的 `registerEntry`）——
>    · **主通道**：DYStorage 已安装 → 走 `DYStorageManager` 收纳入口（运行时注册、统一渲染跳转）；
>    · **兜底通道**：`DYStorageManager` 类**完全缺席** → 降级为 hook 抖音设置页注入「DCL 崩溃取证」入口行
>      （守卫版：`AWESettingsViewModel` / `AWESettingItemModel` / `AWESettingSectionModel` 任一缺失即静默跳过）。
>   两条通道**互斥**——只要 `DYStorageManager` 类存在就走主通道、绝不装兜底，永不对同一方法重复 swizzle。
> 这是本项目的架构红线——**核心捕获链路禁止绑到抖音私有类**（设置入口兜底属 UI 入口层、可降级，不进捕获链路）。

---

## 注入到抖音（自签 / 巨魔）

产物是 **`DouyinCrashLogger.dylib`**（`arm64`，无越狱路径残留）。
LLVM `ld64.lld` 编不出真正的 `arm64e`（ptrauth ABI 缺失），故本工程只交付 `arm64`——
注入到 `arm64e` 宿主 App 无影响（dyld 支持混合加载）。`control` 已移除 `mobilesubstrate` 依赖。

**方式 A — TrollStore（巨魔，推荐）**
1. 安装 TrollStore + [TrollFools](https://github.com/Lessica/TrollFools)
2. TrollFools → 选**抖音** → 注入 `DouyinCrashLogger.dylib` → 自动重装
3. 正常使用抖音即可，崩溃会自动记录；需要看日志时导出 App 容器，读 `Documents/DouyinCrashLogs/`

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

## 为什么有时「闪退但 0 条记录」

抖音真正“闪退”时，本插件可能**抓不到**任何崩溃日志，这是平台限制而非 bug：

- **`SIGKILL`（信号 9）/ 内存溢出（Jetsam/OOM）**：无法被任何信号处理器捕获，也不产生 ips 日志；
- **Mach-O 加载极早期崩溃**：dylib 还没来得及安装 handler 就挂了；
- **系统 Analytics 的 ips 与 App 沙盒隔离**：系统级崩溃报告插件读不到。

为此本插件提供两条**兜底线索**，都写成文件（在 `Documents/DouyinCrashLogs/` 下直接读取）：

1. **上次退出状态标记**
   - 启动时读 `NSUserDefaults` 里上一轮「是否正常退出」的标记；同时注册 `UIApplicationWillTerminateNotification` 观察者。
   - 判定结果会**追加写入 `plugin_runtime.log`**（形如 `[DCL] 上次退出状态：疑似闪退（无 ips 日志…）`），无需 App 内页面即可查看。
   - 若进程被 `SIGKILL` / OOM / 早期崩溃杀掉，**不会**触发 WillTerminate，下一轮启动即判定为「**疑似闪退（无 ips 日志）**」；
   - 正常退出时观察者写回「正常」+ 时间戳。
   - 注意：这只能量化“疑似”，拿不到内核级原因，深度定位需用 `sysdiagnose`。
2. **运行时日志（`plugin_runtime.log`）**
   - 在延迟块（主 runloop 起来后）用 `freopen` 把 `stderr/stdout` 重定向到沙盒文件。
   - 即使随后被 `SIGKILL`，被杀前已经落盘的部分仍可看出崩溃前的最后输出（末尾可能丢失）。

> `freopen` **必须**放在延迟块，**绝不能**放在 `constructor` / `+load` 阶段，否则会拖慢甚至影响注入早期稳定性。

## 触发生成「最新日志」（latest.log）

极简版没有 App 内按钮，想拿到**当前这一刻**的状态快照，用下列任一方式触发，
都会（重新）生成并覆盖 `Documents/DouyinCrashLogs/latest.log`：

| 触发方式 | 时机 | 说明 |
|---|---|---|
| 📸 **截屏** | 你在抖音里截一张图 | 最可控——想生成就截一下；系统公开通知，不与抖音任何手势冲突 |
| 🔙 **切后台 / 锁屏** | App 进入后台自动 | 切走后即可导出容器取最新日志 |
| 🚀 **启动完成** | 启动后约 2 秒自动 | 保证即便从不主动触发，也一定有一份 |

> 全部走系统公开通知（`UIApplicationUserDidTakeScreenshotNotification` /
> `UIApplicationDidEnterBackgroundNotification`），**不交换任何方法、不拦截任何事件**。

快照内容包含：触发方式与时间、pid、**上次退出状态**（正常 / 疑似闪退）、设备与版本信息、
触发时调用栈原始地址、已落盘的崩溃日志清单（含大小与修改时间）、运行时日志是否存在及大小、
**已加载镜像基址表**（供 `atos` 符号化）。

## 隐私说明（重要）

- 日志**仅保存在本机沙盒**，**绝不自动上传**；极简版无任何分享/导出 UI，全部由你手动从容器取文件。
- 只收集堆栈、信号、版本等基础调试信息，**不读取、不记录任何 token / cookie / 私信 / 浏览记录**。
- 自动循环保留最近 20 条，超出即删，不会持续占用存储。

## 日志导出

极简版**只有一种取日志方式**，也是最可靠的一种：

- **直接从容器取文件**：日志在抖音沙盒 `Documents/DouyinCrashLogs/`，用 Filza 或自签工具导出 App 容器即可取出
  - `crash_*.log` — 每条崩溃一份完整报告
  - `plugin_runtime.log` — stderr/stdout 重定向 + 每次启动的退出状态标记

---

## 构建

**不用 macOS**：clang（上游 LLVM）+ `ld64.lld`（LLVM 的 Mach-O 链接器）+ iPhoneOS SDK，
三件齐活，Linux 就是你的 Xcode。详见 `tools/` 与文档《28-非macOS编译iOS-dylib方案》。

**首次**（自动稀疏拉取 iPhoneOS SDK，约 220MB，落到 `~/.pdp-sdks`，之后离线复用）：
```bash
make dylib        # 探工具链 → 拉 SDK → 编译 → 链接 → 纯 Python 结构自检（一步到位）
```

**日常**：
```bash
make dylib        # 交叉编译 -> build/DouyinCrashLogger.dylib（arm64）
make syntax       # 快速语法冒烟（-fsyntax-only，需 SDK）
make verify       # 对已有 dylib 跑纯 Python Mach-O 结构自检
make deb          # 打包 build/DouyinCrashLogger_<版本>.deb（越狱用；巨魔/自签注入只用 dylib）
make precheck     # 项目自有门禁（无需 SDK）
```

**可调环境变量**：`MIN_IOS`、`SDK_VERSION`、`SDK_SYSROOT`、`OUT`、`CC`、`LD`。

> **架构说明**：只用 arm64。LLVM 的 `ld64.lld` 不支持 Apple 私有 ptrauth ABI，
> `-arch arm64e` 编出来的 `cpusubtype` 是 `0x0`、与 arm64 逐字节相同，属假货——
> 本工程宁可明确拒绝，也不交付"名字叫 arm64e 实际是 arm64"的产物。
> 注入到 arm64e 宿主 App 无影响（dyld 支持混合加载）；真要 arm64e 请走 macOS + Theos。

仓库自带 `.github/workflows/build.yml`：push 到 `main` 或手动触发即自动产出
**`DouyinCrashLogger.dylib` + `.deb`** 并上传为 Action Artifact，零越狱路径残留。

---

## 取证能力边界（先看这个再看日志）

日志里"没有记录"有两种完全不同的含义：**确实没发生**，或者**我们够不着**。
混为一谈就会把"蹲错楼层"当成"探针写漏了"，然后往一条根本不会被调用的路径上反复加钩子。

- 完整说明与「漏抓」决策树见 [`docs/取证能力边界.md`](docs/取证能力边界.md)。
- 一句话版：能建立到**系统层 + 宿主外显层**的因果，到不了**抖音内部为什么**这一层。
- 判断钩子是否命中过：看 `latest.log` 时间线里有没有「AVPlayer实例」这一行
  —— 没有就说明主播放不走系统播放器，别再往 AVPlayer 上加钩子了。

---

## 免责声明

仅供个人学习、调试、研究使用。请勿用于任何商业或分发用途。
记录的是你**自己设备**上抖音的崩溃信息，不收集任何隐私数据，全部仅保存在本机沙盒。
