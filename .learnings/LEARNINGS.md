# 学习记录

开发过程中捕获的纠正、洞察与知识缺口。

**类别**: correction | insight | knowledge_gap | best_practice

---

## [LRN-20261013-001] insight

**记录时间**: 2026-10-13T13:42:00+08:00
**优先级**: medium
**状态**: pending
**领域**: config

### 摘要
DYStorage 提供 `registerControllerWithIdentifier:title:version:controller:` 接口，可注册 VC 类名由它统一渲染跳转，比 `registerAction` + 自 present 更贴合其「统一渲染」设计，且契约零门槛。

### 详情
- 契约（`DYStorageManager.m:135`）：只存类名字符串（参数名是 `controller:`，不是 `controllerClassName:`），不实例化。点击时 `NSClassFromString` + `[[cls alloc] init]`，必须是 `UIViewController` 子类，**不要求特定基类**。
- 跳转（`Tweak.xm:377-411` `DYStoragePresentController` / `DYStorageOpenRegistration`）：优先 `pushViewController:` 进现有 `navigationController`；否则新建 `UINavigationController` 包着 VC 以 fullScreen modal `presentViewController:`。→ 我们的 VC **一定在导航栈里**。
- 标题：VC 无 `title` 时用 `registration.title` 自动补。
- 坑：`present`（无 nav）分支**未加关闭/返回按钮**，用户可能卡在无返回的全屏页；主场景从抖音设置页（在 nav 栈内）进入走 push，有返回。
- 弱依赖调用：DYStorage 不参与链接，必须用 `respondsToSelector:` 探测 `registerController` 再 `performSelector:`，否则旧版无此方法会 `unrecognized selector` crash；不支持时回退 `registerAction`。

### 建议行动
升级 DCL 设置入口到 `registerController` 时采用「双轨兜底」：探测到 `registerController` 用新接口，否则回退 `registerAction` 自 present。VC 自带一个 leftBarButtonItem 关闭（dismiss/pop 双保险），杜绝 present 场景卡死。

### 元数据
- 来源: conversation
- 相关文件: /workspace/_dystore_ref/DYStorageManager.m, /workspace/_dystore_ref/Tweak.xm:377-411
- 标签: DYStorage, 设置入口, 统一渲染, 弱依赖

---

## [LRN-20261013-002] correction

**记录时间**: 2026-10-13T19:45:00+08:00
**优先级**: high
**状态**: pending
**领域**: config

### 摘要
核实真实 `xlzs001/DYstorage` 仓库入口通道规则：第三方插件用的是 `DYStorageManager` 主通道；仓库里多出的 `DYPluginsViewController`/`DYPluginsMgr` 是**独立内部功能**，不在第三方入口通道内。同时修正 `dismissSelf` 在「modal 包新 nav 的栈底」场景关不掉的 bug。

### 详情
- **两条 registerController API 不是一回事**：
  - 主通道（第三方用）：`DYStorageManager.registerControllerWithIdentifier:title:version:controller:`，由 `Tweak.xm` 的 `DYStorageOpenRegistration`(:393) → `DYStoragePresentController`(:377) 实例化/跳转。`Tweak.xm` 全程零引用 `DYPluginsMgr`。
  - 内部中枢：`DYPluginsMgr.registerControllerWithTitle:version:controller:`（**无 identifier、是另一个单例**），只被 `DYPluginsViewController`（"插件管理中枢"列表页）消费，用于 DYStorage 自身罗列插件。**DCLSettings 不应碰它**。
- **dismissSelf 稳健修法**（已落地 `DCLSettings.m`）：`DYStoragePresentController` 在「顶层 VC 无 nav」时把我们的 VC 包成新 `UINavigationController` 的 root 再全屏 modal present。此时 VC 的 `presentingViewController` 为 nil、且自己是栈底不能 pop → 旧逻辑 `popViewControllerAnimated:` 是空操作，面板关不掉。修复：优先判断 `nav.viewControllers.firstObject != self` 则 pop，否则沿 `nav.presentingViewController` 把最外层 dismiss 掉。该修法同时覆盖 `presentSettings`（registerAction 兜底自 present）同构场景。

### 建议行动
后续若再为其它 VC 接入 DYStorage，直接复用此 `dismissSelf` 模板；不要误用 `DYPluginsMgr` 那条 API。

### 元数据
- 来源: conversation（real repo 核实，非猜测）
- 相关文件: /workspace/DYStorage_real/Tweak.xm:377-411,393 / DYPluginsMgr.m / DYPluginsViewController.m; /workspace/DouyinCrashLogger/DCLSettings.m:357
- 标签: DYStorage, 入口通道, dismissSelf, DYPluginsMgr, 模态关闭

---

## [LRN-20261013-003] knowledge_gap

**记录时间**: 2026-10-13T19:56:00+08:00
**优先级**: high
**状态**: pending
**领域**: config

### 摘要
联网核实 DYStorage 生态与抖音 tweak 可行性的关键结论：DYStorage 仍活跃维护（2026-09 仍提交），但强依赖抖音私有类/selector，抖音版本一升就可能失效，需真机复验；抖音 tweak 生态 2026 年仍活（DYYY 247★、真实 IPA 分发含 DYStorage.dylib）。

### 详情
- **DYStorage 仓库现状（gh api + 开源榜交叉验证）**：last push 2026-09-04，17★，0 open issues，最近提交 2026-09-03（聚合搜索性能/过渡动画、搜索返回、悬浮窗插件定位修复）。最新 Release「抖音插件收纳」2026-08-28（无 git tag）。→ 维护中、未停更。
- **架构与契约（kaiyuanbang/reporank 文档）**：Theos tweak，运行时 Hook 抖音私有 `AWESettingsViewModel`/`AWESettingItemModel`/`AWESettingSectionModel`，向设置首页注入"插件收纳" section；保留原始 `cellTappedBlock`；通过 `DYStorageManager.h` 暴露运行时注册 API（`registerAction…` / `registerController…`）。开发者扫描器默认隐藏，需 `DYStorageDeveloperMode=YES`。构建覆盖 Rootful/Rootless/RootHide 三种 deb。
- **致命约束（多源一致）**：「依赖抖音私有实现类与 selector，版本升级后可能失效，需要真机验证」；「只能收纳已知或可安全识别的插件入口」。→ 我们的 DCLSettings 入口存在"随抖音/DYStorage 升级而消失"的风险，但运行时注册已做 nil 跳过，降级优雅。
- **生态活度**：feng.com 2026-09-03 真实分发帖「抖音 Vex-dyy 版」内置 DYStorage.dylib（"插件统一收纳"）；DYYY 247★/40 fork，目标 iOS 15.0+、arm64/arm64e，Theos+Logos；iOS 越狱 dylib 注入 2026 指南仍以 Cydia Substrate / Substitute + Theos 为标准。→ 注入链路本身 2026 仍成立。
- **抖音反制**：分发帖提及自签用户需"绕登录"、且"抖音版本迭代飞快，适配跟随版本持续更新"——核心 hook 捕获方案（signal/NSException handler）比 UI 私有类 hook 更 app 无关、更抗版本漂移。

### 建议行动
- 把 DCL 的核心崩溃捕获与"设置入口"解耦：捕获层走 signal/NSException/未被抖音改写的系统入口，尽量不依赖抖音私有类；DYStorage 入口仅作"锦上添花"的展示通道，缺席不影响取证。
- 每次抖音大版本更新后，真机复验 DYStorage 收纳是否正常（section 注入 + 注册回调）。
- 建立"目标抖音版本基线"概念，CI/文档标注当前适配的抖音版本号。

### 元数据
- 来源: web + gh api（kaiyuanbang.cn, reporank.net, feng.com, deepwiki, tsight.io）
- 相关文件: /workspace/DYStorage_real, /workspace/DouyinCrashLogger/DCLSettings.m
- 标签: DYStorage, 可行性, 抖音私有类, 版本漂移, 反制, tweak生态
- 参见: LRN-20261013-001, LRN-20261013-002

---

## [LRN-20261013-004] insight

**记录时间**: 2026-10-13T20:10:00+08:00
**优先级**: medium
**状态**: pending
**领域**: config

### 摘要
核实 DouyinCrashLogger 核心崩溃捕获层：**零抖音私有类依赖**，纯 POSIX 信号 + Foundation 异常处理器，天生抗抖音版本漂移。"加固核心捕获 app 无关化"实为已完成项，无需改代码。

### 详情
- `DCLCrashReporter.m` 安装 `sigaction` 接管 `SIGABRT/SIGSEGV/SIGBUS/SIGTRAP/SIGILL/SIGFPE`（不含 SIGPIPE，避免把 socket 写失败升级成崩溃），并 `NSSetUncaughtExceptionHandler` 接管未捕获异常。两者均纯系统/Foundation 层，**无任何 Douyin/Aweme 类 hook**。
- handler 内全部 async-signal-safe：手写 `dcl_u64_to_hex/dec` 替代 `snprintf`；备用栈 `sigaltstack` 防栈溢出二次崩；镜像基址表启动时预收集，handler 只只读不调 `dladdr`；崩溃报告对齐苹果 Binary Images 格式可直接喂 `atos` 符号化。
- **自愈机制**：`dcl_reassert_signals` / `dcl_reassert_uncaught_exception_handler` 每 15s 巡检，夺回被其它注入模块顶替的处理器并保留链式转发（不切断宿主原有的崩溃上报）。
- 工程全量 grep 确认：捕获层（`DCLCrashReporter`/`DCLSystemSignal`/`DCLWatchdog` 等）对抖音私有类的引用为 0；唯一抖音耦合是 `DCLSettings.m` 运行时注册 `DYStorageManager`（nil 跳过降级）与可选的 `DCLPlaybackTracer`（hook 公开类 `AVPlayer` 做播放诊断，属增强项、非核心捕获）。

### 建议行动
- "①加固核心捕获 app 无关化" 标记为准已完成：无需改代码，建议改为「认证 + 文档化」（在 README/AGENTS 写清捕获层与抖音解耦的事实，作为后续别误加抖音耦合的约束）。
- 后续任何新探针/功能若想加抖音私有类 hook，应先评估是否可走公开类/系统层替代，守住「核心捕获与抖音解耦」这条线。

### 元数据
- 来源: code review（DCLCrashReporter.m 全文 + 工程 grep）
- 相关文件: /workspace/DouyinCrashLogger/DCLCrashReporter.m, DCLSystemSignal.m, DCLPlaybackTracer.m, DCLSettings.m
- 标签: 崩溃捕获, app无关, signal, 版本漂移, 自愈, 解耦
- 参见: LRN-20261013-003

---

## LRN-20261013-004 · 无收纳插件时设置入口兜底（双通道）+ 滚动内按钮不灵敏

- **结论**: DCLSettings 入口是「双通道」——DYStorage 安装时走其收纳入口；**完全缺席时**回退 hook 抖音设置页注入入口行，修复「不装收纳插件所有入口都不显示」。
- **DYStorage 注入机制（已查证真实源码 xlzs001/DYstorage）**: 它 hook 的是 `AWESettingsViewModel` 的 `sectionDataArray` getter，往返回的 `sectionDataArray` 里 append 一个 `AWESettingSectionModel`；每个入口是 `AWESettingItemModel`，要点属性（全 KVC 写私有属性）：`identifier`/`title`/`detail`/`cellType=26`/`colorStyle=2`/`isEnable`/`cellTappedBlock`（点击回调）。仅「主设置页」（含 账号/账户/account 区）注入。
- **双通道铁律**: 只要 `DYStorageManager` 类存在就走主通道、`return` 不装兜底——**绝不能**与本插件和收纳插件对 `AWESettingsViewModel.sectionDataArray` 的同方法 swizzle 打架。三者（`AWESettingsViewModel`/`AWESettingItemModel`/`AWESettingSectionModel`）任一缺失即静默跳过（抖音版本变更时只令入口失效、不崩）。
- **UIScrollView 内按钮不灵敏**: 根因是 `UIScrollView.delaysContentTouches` 默认 YES，会先犹豫 ~150ms 判断是否滚动，导致内部 `UIButton` 点着发钝。修复：`scroll.delaysContentTouches = NO` + `canCancelContentTouches = NO`，按钮最小高度 46 增大热区。
- **元数据**: 来源: 用户 bug 反馈 + 真实源码查证; 相关文件: DCLSettings.m(registerEntry/installSettingsPageFallback); 标签: DYStorage, 入口兜底, 设置页注入, 双通道, 滚动按钮, delaysContentTouches
