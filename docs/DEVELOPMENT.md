# 开发说明

## 工程结构

SwiftPM 工程，`swift-tools-version:5.10`，平台 macOS 13，没有第三方依赖。

| 模块 | 内容 |
| --- | --- |
| `TunCanaryCore` | 纯逻辑：数据模型、解析器、判定引擎、VPN 适配器、连通性规则、通知去重、`--check` 判定、设置、脱敏和诊断摘要。除 `SettingsStore`、`VPNAdapterStore`、`VPNAdapterRegistry`、`FaultEventStore`、`EgressHistoryStore` 和 `DNSGuardStateStore` 外不做 I/O。守护进程的文件格式也在这里（`Guard/`），应用和守护进程共用 |
| `TunCanarySystem` | 系统采集：进程、网络接口、路由、SCDynamicStore、代理配置、VPN 状态文件、代理 DNS 查询、系统解析探针，以及网络变化与睡眠唤醒的监听 |
| `TunCanaryProbe` | 站点探测、完整检测的并发控制、`--check` 流程编排和出口检测 |
| `TunCanaryUI` | 菜单栏图标、弹窗、设置、通知和登录项 |
| `TunCanaryRuntime` | 调度器：定时、宽限期、串行化与合并触发、取消，以及把结果发布到界面 |
| `TunCanary` | 程序入口。带 `--check` 时进入命令行模式，否则启动菜单栏应用 |
| `TunCanaryDNSGuard` | 可选的 DNS 守护进程，由 LaunchDaemon 以 root 身份运行。每次运行完成一次判定和写入后退出。判定逻辑在 `TunCanaryCore`，写入和代理 DNS 探测在 `TunCanarySystem` |
| `TunCanarySelfTest` | 自带的测试运行器 |

一轮检查的数据流：`SystemSnapshotProvider` 采集 `LocalSnapshot`，`LocalEvaluator` 得出 `LocalAssessment`（四张状态卡，有 Tailscale 时加一张 Tailnet 卡，以及故障列表），站点探测结果进入 `ConnectivityTracker`，两者合并为 `OverallAssessment`，再由 `NotificationDeduper` 决定是否通知，由 `FaultEventRecorder` 生成故障事件并经 `FaultEventStore` 写入本机日志（宽限期内两者都不调用）。

出口监测使用独立数据流：`EgressIPChecker` 读取目标回显的 IP，`EgressGeoClient` 查询该 IP 的地域，`EgressMonitorState` 管理采样、缓存、冷却、变化比较和地域通知状态，`EgressHistoryStore` 原子写入本机历史。`AppModel` 防止取消后的迟到结果写回；保存使用递增版本，避免旧任务覆盖新状态。`MonitorController` 每 30 秒检查到期状态，每次最多自动采样一个目标，睡眠和网络切换宽限期内暂停。自动请求遵守每目标至少 5 分钟的间隔；手动检测立即触发并入库，不推迟自动计划，但仍遵守服务端限流与暂停状态。

出口结果不参与 `OverallAssessment`、诊断摘要或命令行 JSON。测试通过注入 `URLProtocol`、地域服务、历史文件路径和虚拟时钟验证，不访问真实目标。

## 测试

环境中只有 Command Line Tools 时，XCTest 不可用，所以项目使用自带的测试运行器：

```sh
scripts/test.sh                          # 全部离线用例
scripts/test.sh Core.DNSRules            # 按“套件名/用例名”子串过滤，多个过滤词取并集
scripts/test.sh --list Core.VPN          # 只列出用例
```

默认用例不访问网络，也不读取本机的代理配置或 VPN 状态。以下用例需要显式开启：

```sh
TUNCANARY_LIVE=1 scripts/test.sh System.Live Probe.Live       # 读取本机真实状态并访问探测站点
TUNCANARY_RENDER_DIR=/tmp/tuncanary-ui scripts/test.sh UI.RenderPreview   # 离屏渲染界面预览 PNG
```

README 中的截图由 `scripts/render-readme-images.sh` 生成，写入 `docs/images/`。它们来自离屏渲染的预览状态，全部是虚构数据；界面改动后重新运行一次即可。请不要用实机截图替换。

实机采集时设置 `TUNCANARY_LIVE_TAILNET_TARGET=地址:端口`，会按这个 Tailnet 子网目标评估 Tailnet 卡；目标经 Tailscale 路由时再做一次 TCP 探测。它不读取、也不修改应用设置。`System.Live` 还会在找到 Clash Verge Rev 控制接口时，对 GitHub 和一个必然失败的地址各做一次代理诊断并打印结果。

DNS 守护进程的安装脚本可以装到临时根目录，不需要 root，也不调用 `launchctl`：

```sh
TUNCANARY_GUARD_ROOT=/tmp/guard-root scripts/install-dns-guard.sh --target-dns 192.0.2.53
/tmp/guard-root/Library/Application\ Support/TunCanary/bin/tuncanary-dns-guard --dry-run --root /tmp/guard-root
TUNCANARY_GUARD_ROOT=/tmp/guard-root scripts/uninstall-dns-guard.sh
```

试运行读取本机真实状态，只输出判定，不写入。

`swift build` 会打印一条无法定位 XCTest 的警告，只装了 Command Line Tools 时属于正常现象。

## 测试数据

`Tests/Fixtures/synthetic/` 是虚构网络环境下的 `scutil --dns`、`netstat`、`ifconfig`、SCDynamicStore 和进程列表输出，以及一个示例 VPN 适配器配置。它们由 `scripts/generate-synthetic-fixtures.py` 生成。修改生成脚本后，依赖这些数值的用例需要同步更新。

请不要把真实环境采集的数据提交到仓库，即使已经脱敏。

## 约定

- 用户可见的文案和代码注释使用中文。
- 状态判定宁可“未确认”，也不误报：证据不足或互相矛盾时不给结论。
- 菜单栏应用和命令行只读取状态，不修改系统 DNS、代理或 VPN 设置，也不调用 `sudo`。
- 只有 DNS 守护进程会写入，而且只写主网络服务保存的 DNS 服务器列表（`Setup:` 层），不写 `State:` 层，不动代理、VPN 和路由。
- 守护进程的配置、适配器和可执行文件都在 `/Library/Application Support/TunCanary/`，归 root 所有。它不读取用户可写的设置和适配器，不按用户可写文件中的路径执行程序。代理配置目录由 root 配置指定，读取时只取 TUN 开关、DNS 端口和 fake-ip 网段。
- 守护进程的写入和探测通过协议注入，测试用桩对象，不在测试里改系统 DNS。
- 诊断摘要、命令行输出和通知正文都要经过 `Redactor`。

菜单栏弹窗直接显示和关闭，不播放 `NSPopover` 动画。同一可用高度下重复打开复用 SwiftUI 根视图；通知和登录项状态在打开设置时刷新。出口模块始终显示目标行；各目标详情独立展开、默认收起，关闭弹窗时重置。历史摘要和倒计时视图仅在对应目标展开时创建。


## 发布

版本号只在 `AppIdentity.swift` 修改。为版本增加 `docs/releases/v<版本>.md`，提交后推送对应的 `v<版本>` 标签。

`Release` 工作流会检查标签与应用版本一致，执行离线测试，构建并校验应用签名。工作流先创建草稿，上传带架构名称的 ZIP 与 `SHA256SUMS.txt`，再公开发布。失败时不会公开不完整的草稿；已有正式版本不会被重跑覆盖。
