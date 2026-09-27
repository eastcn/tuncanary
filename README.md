# TunCanary

[English](README.en.md)

TunCanary 是一个 macOS 菜单栏应用，检查系统 DNS 有没有绕过 Clash 类代理的 TUN。

## 它解决的问题

Clash 类代理开启 TUN 并使用 fake-ip 模式时，系统解析任何域名都应该拿到 fake-ip，也就是配置中 `fake-ip-range` 网段内的地址（常见的是 `198.18.0.1/16`）。如果拿到的是真实 IP，说明这次 DNS 查询没有经过代理。

这种情况常出现在同时使用 VPN 的时候：VPN 客户端连接时改写了网络服务的 DNS，断开后没有恢复成原来的值，DNS 查询于是直接发给了局域网里的路由器。网站照样能打开，只看连通性发现不了，但 DNS 已经泄露到代理之外。

TunCanary 每隔一段时间用系统解析器查询一个“探针”域名，返回真实 IP 就判为故障，并发出系统通知。

## 检查的内容

| 状态卡 | 检查 |
| --- | --- |
| 代理 TUN | 代理配置里 TUN 是否开启、fake-ip 网段内是否有 UP 的 utun 接口、核心进程是否在运行 |
| VPN | 按你编写的适配器配置识别 VPN 进程、隧道和路由；另外报告未识别的隧道。证据互相矛盾时判为“未确认” |
| 主网络 DNS | 系统解析探针域名是否返回 fake-ip；可选：检查网络服务保存的 DNS 是否符合你设定的规则 |
| 代理 DNS | 代理在本机监听的 DNS 端口是否响应 |

此外还会分组检测一组站点的可达性（默认是百度、哔哩哔哩、Google、GitHub 和 Cloudflare），连续两轮失败时告警。

颜色含义：绿色正常，黄色需关注，红色故障，灰色表示证据不足或未确认。状态未确认时不给修复建议，也不发通知。

## 系统要求

- macOS 13 或更新版本。
- Xcode Command Line Tools，包含 Swift 5.10 或更新版本。不需要完整的 Xcode。

没有第三方依赖。

## 构建与安装

在仓库根目录运行：

```sh
scripts/test.sh
scripts/build-app.sh
scripts/install.sh
```

- `test.sh` 运行离线测试，不访问网络。
- `build-app.sh` 生成 `build/TunCanary.app`，并做 ad-hoc 签名。
- `install.sh` 把应用安装到 `~/Applications/TunCanary.app`，写入命令行入口 `~/.local/bin/tuncanary`，然后启动应用。它不会开启登录时启动。

本机构建的应用不带隔离属性，Gatekeeper 不会拦截。目前不提供预构建的安装包。

卸载：

```sh
scripts/uninstall.sh                  # 保留设置
scripts/uninstall.sh --clear-settings # 一并删除设置
```

## 配置

点击菜单栏图标，再点弹窗底部的“设置”。

- **代理客户端**：选择 Clash Verge Rev 时，应用读取它的配置文件，只取 TUN 开关、DNS 端口、IPv6 开关、fake-ip 网段（含 IPv6 网段）和 fake-ip 过滤名单，不读 secret 和节点。其他客户端选“手动填写”，填 fake-ip 网段；代理 DNS 端口和核心进程名可选。
- **探针域名**：默认 `www.google.com`。它不能在代理的 fake-ip 过滤名单中，否则系统解析本来就返回真实 IP。应用会读取 Clash Verge Rev 的过滤名单并提示。
- **DNS 规则**：可选。可以规定 VPN 断开、TUN 运行时网络服务保存的 DNS 应该是什么（不检查、指定地址或为空），以及 VPN 连接时的规则（不检查、VPN 下发的 DNS，或由代理接管）。选“由代理接管”时，VPN 连接期间也按断开时的规则检查，并要求系统解析经过代理；内网域名须由代理解析。系统解析确认经过代理时，设置页会出现“用当前值作为预期”按钮。
- **VPN 适配器**：见 [docs/ADAPTERS.md](docs/ADAPTERS.md)。不配置也能用：核心检测不依赖 VPN。
- **站点**：最多 20 个，可以分组，可以选择哪些参与后台检测和告警。“添加常用站点”里有更多预置站点。
- **内网站点**：一个只在 VPN 已连接时探测的 URL。诊断摘要里只显示“已配置”或“未配置”。
- **检测页与出口**：最多 3 个在浏览器中打开的外部检测页，默认没有。“检测出口”默认访问 Cloudflare 的 trace 地址，可以选择同时访问 claude.ai。

## 命令行

```sh
tuncanary --check          # 一次本机检查和一轮轻测
tuncanary --check --full   # 完整检测全部站点
tuncanary --check --json   # 输出 JSON
tuncanary --version        # 打印版本号
```

退出码：`0` 正常，`1` 需关注，`2` 故障，`3` 未确认，`64` 参数错误。黄色或红色的本机结论会在 10 秒后复查一次，两次一致才报告。整体超时 30 秒。

JSON 的键名和取值会在后续版本中保持兼容。

## 隐私

- 应用只读取状态，不修改 DNS、TUN、代理或 VPN 的设置。
- 读取范围：代理配置中的上述字段、相关进程的可执行文件路径、网络接口与路由、SCDynamicStore 中的 DNS 设置、VPN 状态文件中适配器指定的字段，以及 `/Library/Application Support/TunCanary/` 下 DNS 守护进程的配置、状态和事件（守护进程是可选组件，未安装时这些文件不存在）。
- 网络请求：站点检测、代理 DNS 查询、系统解析探针；“检测出口”只在你点击时请求。
- 不收集、不上传任何数据。诊断摘要、命令行输出和通知都会脱敏：内网 IP 只保留首段，不包含内网站点 URL 和主目录路径。
- 本机写入：故障出现、变化和消失的记录保存在 `~/Library/Application Support/TunCanary/events.jsonl`，最多 200 条，内容同样脱敏，显示在弹窗的“最近事件”和诊断摘要中。`scripts/uninstall.sh --clear-settings` 会一并删除。

## 局限

- 探针按 IPv4（A 记录）判定，只代表通过系统解析器的查询。浏览器自带的 DoH、应用自己的解析器不在检查范围内。
- 探针也会查询 AAAA 记录，结果只显示在主网络 DNS 卡的证据中，不据此告警。
- 只支持 fake-ip 模式。redir-host 等模式下无法用探针判断绕过。
- ad-hoc 签名的应用重装后，登录时启动可能需要在系统设置中重新批准。
- 界面和文档目前只有中文。

## 许可证

[MIT](LICENSE)。

TunCanary 与 Clash Verge Rev、mihomo、Cloudflare、Anthropic 以及文中提到的其他产品和网站没有关联。
