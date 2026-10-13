# PerfDebugPlugin 省电开关清单（针对本机实测数据）

> 数据来源：`PerfPluginSnapshot_1791914633.json`（PerfDebugPlugin **V3.2.21** / spec **V1.3**，
> 导出时间 2026-10-14 02:03:53）+ 同轮 `runtime_switch.log` + DCL 侧 `plugin_runtime.log`（约 12 分钟）。
> 开关的 ON/OFF 状态取自快照 `config.switches`，不是猜的。

## 0. 先说口径，避免误读

- **没有真实 CPU% 归因**：快照里 `cpuReadoutOk:-1`、`cpuTotalPctOfAll:-1`、`cpuBusyThreads:-1`、
  `cpuUsedCores:-1` —— CPU 读数全程没取到。下面每条建议都是**采样计数器 + 耗时证据的推断**，
  不是功耗实测。要真量化得用电流表 / Xcode Energy Gauge，别拿这份清单当功耗定论。
- 证据等级标注：**【实测】**＝快照或日志里有明确数字；**【推断】**＝按工效(el)消耗机制推断。
- **一个反直觉发现**：插件自己的 `baselineDetectReport` 判定多数开关"收益不大"（`sampleCount 0 / 阈值 20`），
  但同时间段 DCL 抓到的原始宿主日志里 decoder 建了 ~80 次、TLS 握手失败 32 次 ——
  **它的探测器这一轮基本没采样到东西**。所以别盲目信它的"无收益"结论，也别完全信我的推断：
  **改一个开关，对比前后计数器，才是可复现的做法。**

---

## 1. 建议关 / 降频（按收益排序）

| # | 开关 | 现状 | 代价证据 | 建议 | 关掉会失去什么 |
|---|------|------|----------|------|----------------|
| 1 | `attr_sanitize` | ON | **【实测】**启动后 12 秒：扫 **3000 个类 / 1059 条属性，耗时 3289 ms**，发现 135 条非法编码位；日志原文写明**"插件不会修改它们（V3.0.3 起只读）"** | **关掉** | 只丢那 135 条的审计清单（本来也不修）。要审计就手动开一次、抄完再关 |
| 2 | `lag_stack` | ON | **【实测】**主线程栈采样 **100 ms** 一次，`lagSamplerSamples=1257`、`lagSamplerBuffer=20/20`（缓冲已满）、`lagSamplerFailures=0`、`okRate 100%` | **关掉**（或降到 250–500 ms） | 卡死时的主线程调用栈归因。但缓冲只有 20 行且已写满，100 ms 的边际取证收益接近 0，代价却一直在付 |
| 3 | `cpu_probe` | ON | **【实测】**`cpuEnabled=true` 但 `cpuReadoutOk=-1`、所有 CPU 字段全是 `-1` —— **持续在测、一个有效值都没拿到** | **关掉** | 目前什么也不丢（本来就取不到数），等它能读数了再开 |
| 4 | `freeze_watchdog` | ON | **【实测】**ping 250 ms，`workerTicks=681`、`heartbeatAgeMs=292`、`freezeCount=0`、`annealSkippedDumps=0` | **放宽 ping 到 500 ms 以上**；不追冻屏时直接关 | 检测粒度变粗：阈值本来就是 1.0 s，ping 放到 500 ms 仍够用它自己的判定阈值 |
| 5 | `tl_collect` / `burst_capture` | ON | **【推断】**时间线持续收集 = 常驻内存缓冲 + 偶发落盘；快照里这两个都没有"攒了多少"的对外计数器 | 不排查时关 | 事后复盘的时间线/突发窗口证据；**注意：关掉后正在 troubleshoot 的问题就抓不到了** |
| 6 | `runtime_log_echo` | ON | **【推断】**把宿主日志回显进自家日志 = 持续文件 IO（这与 DCL 侧的 IO 是同一类开销，12 分钟 316 KB） | 不看它家日志时关 | 排查线索。保留 `host_log_tap`（只进面板、不落盘）能省掉 IO 那部分 |

---

## 2. 建议保持开着（关了等于自废武功）

| 开关 | 现状 | 为什么别动 |
|------|------|-----------|
| `crash_lag` | ON | 崩溃/退出性质判定，**【实测】**这一轮就是它报的"上次运行正常离场（进过后台 546 秒）" |
| `inject_audit` | ON | **【实测】**一次性扫描 1553 个镜像（系统 1524 / 宿主自有 29 / 非系统非宿主 **0**），成本一次性、结果很有价值（第三方注入审计） |
| `play_pause_probe` | ON | **【实测】**7 处通知监听，零 hook；且它自己坦白"不 Hook 拿不到 pause" —— 已经是它最便宜的形态了 |
| `network_conn_pool` / `db_retry_intercept` | ON | 已开，且它自己的 baseline 判定无收益；关掉没有账面收益，不如留着 |
| `vc_transition_protect` | ON | **【实测】**`detectAccumulated.vc_transition_protect=26`、`counters.vcTransitionFiltered=26` —— 真的在过滤，属于有产出的那类 |

---

## 3. 两个"别指望它"的坑

**① `decoder_pool` 目前是 OFF，而日志显示它恰恰该开**
DCL 侧原始日志（同 12 分钟）数出来的：decoder **创建 ~80 次 / flush 71 次 / destroy 70 次**，
即约 6.7 次/分钟的建销。可 `baselineDetectReport` 里 `decoder_pool` 那项是
`sampleCount 0 / 阈值 20 → 判定"频次正常"` —— **它的探测器和原始日志对不上**。
建议：手动试开 `decoder_pool`，盯着播放是否正常；一旦出现异常（黑帧、起播慢）立刻关回去。
这一条是"开"不是"关"，别被清单标题带偏。

**② `lowPowerModeEnable:true` ≠ 真省电**
快照里 `lowPowerModeEnable=true`、`lowPowerBackupConfig={}`，而 `lag_stack` 依旧 100 ms 采样、
`freeze_watchdog` 依旧 250 ms ping —— **它的低功耗模式没有覆盖这两个常驻采样器**。
别以为勾了省电开关就不用管上面第 1、2、4 条。

---

## 4. 最小改动方案（怕踩雷就先做这三步）

1. 关 `attr_sanitize` —— **收益最确定**（一次性省掉主线程 3.3 秒卡顿），且不修改任何东西，风险最低。
2. 关 `cpu_probe` —— 取不到数还在跑，纯粹的浪费。
3. 把 `lag_stack` 降频（或关）+ `freeze_watchdog` 的 ping 放宽 —— 这两个是**唯一长期常驻的周期性负载**。

做完一轮，重新导出快照对比这几个计数：`lagSamplerSamples` 应归零/变慢、
`workerTicks` 增长速率应下降、`cpuEnabled` 相关字段彻底消失、`capturedLogs` 里不再有 `attr_sanitize` 那条 warn。

---

## 5. 回到"发热源"这件事

上一轮排查的结论在这里没有被推翻：**你这 12 分钟里的大头不是插件，是宿主自己** ——
decoder 建/销 ~150 次、渲染 filter node 构造 ~65 次、`tls ssl init` 重连 51 次（还夹 32 次 handshake failed）。
插件侧能减的是它自己的常驻采样（本清单第 1、2、4、5、6 条），
宿主那部分要省只能靠 `decoder_pool` 这种"替宿主改行为"的开关，风险等级完全不同 —— 建议单独试、单独盯。
