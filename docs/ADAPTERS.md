# VPN 适配器配置

TunCanary 不内置任何 VPN 客户端的识别规则。你用一份 JSON 描述自己的 VPN 客户端：它的进程在哪里、状态文件里哪些字段表示连接状态。应用据此判断 VPN 是否连接，并决定哪些 DNS 规则适用。

不写适配器也能使用：fake-ip 绕过检测不依赖 VPN。这时 VPN 卡显示“未发现 VPN”；如果出现带路由的未识别隧道，VPN 状态判为“未确认”，依赖 VPN 状态的 DNS 规则暂停评估。

Tailscale 这类常驻隧道不需要、也不应该写适配器。地址在 `100.64.0.0/10` 内的隧道不算未识别的隧道，也不会被适配器认领，只列在诊断信息中。两类隧道的区别见 README 的“VPN 与常驻隧道”一节。

## 放在哪里

每个适配器一个 `.json` 文件，放在：

```text
~/Library/Application Support/TunCanary/adapters/
```

应用在每轮本机检查前比对目录中文件的名称、大小和修改时间，有变化就重新加载，所以修改会在一个本机检查间隔（默认 20 秒）内生效。也可以在“设置 → VPN 适配器”中点“立即重新加载”。命令行每次运行都会重新读取。

文件按文件名排序加载，最多 10 个，每个不超过 64 KB。无效的文件会被跳过，原因显示在 VPN 卡的证据和“设置 → VPN 适配器”中。

## 示例

```json
{
  "id": "example",
  "name": "Example VPN",
  "process": {
    "executablePaths": [
      "/Applications/Example VPN.app/Contents/Resources/example-tunnel"
    ]
  },
  "statusFile": {
    "path": "~/Library/Application Support/Example VPN/state.json",
    "connected": "/session/active",
    "connecting": "/session/pending",
    "tunnelIP": "/session/address",
    "dns": "/session/resolvers"
  },
  "tunnel": {
    "cidr": "10.9.0.0/16",
    "minRoutes": 10
  }
}
```

## 字段

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `id` | 是 | 1–40 个字母、数字、`-` 或 `_`，各适配器之间不能重复 |
| `name` | 是 | 界面显示名，1–40 个字符 |
| `process.executablePaths` | 是 | VPN 隧道进程的可执行文件完整路径，至少一个；可以用 `~/` 开头 |
| `statusFile.path` | 否 | 客户端写入的 JSON 状态文件，可以用 `~/` 开头，不超过 1 MB |
| `statusFile.connected` | 否 | 表示“已连接”的字段，接受布尔值、`1`、`0`，以及 `"true"`、`"connected"` 等字符串 |
| `statusFile.connecting` | 否 | 表示“正在连接”的字段 |
| `statusFile.tunnelIP` | 否 | 隧道接口的 IPv4 地址，用来识别隧道 |
| `statusFile.dns` | 否 | VPN 下发的 DNS，逗号分隔的字符串或字符串数组 |
| `tunnel.cidr` | 否 | 隧道 IPv4 所在网段 |
| `tunnel.minRoutes` | 否 | 按路由数量识别隧道时的最少条数，1–1000，默认 10 |

`statusFile` 中的字段用 [JSON Pointer](https://www.rfc-editor.org/rfc/rfc6901) 指定，例如 `/session/active` 表示根对象下 `session` 对象的 `active` 字段。没有指定的字段不会读取；状态文件中的其他内容（账号、令牌、服务器地址等）不会进入应用的任何数据。

## 怎样找到可执行文件路径

VPN 连接后，在终端运行：

```sh
ps -axo pid,user,comm | grep -i 'vpn'
```

`comm` 列是可执行文件的完整路径。选择建立隧道的那个进程，通常以 root 运行，而不是客户端的界面进程。应用按路径精确匹配，不看命令行，所以其他进程的命令行里出现同样的路径也不会被误认。

## 判定规则

每个适配器收集以下证据，每项可能为“是”“否”或“未知”：

| 证据 | 作用 |
| --- | --- |
| 进程：`executablePaths` 中的某个进程在运行 | 必要条件 |
| 隧道：识别出的隧道接口为 UP | 佐证 |
| 路由：有路由指向该隧道 | 佐证 |
| 状态文件：`connected` 字段 | 参考 |

- 已连接：进程在运行，并且隧道为 UP 或有路由指向它。
- 已断开：进程、隧道和路由都不存在。
- 其余情况判为未确认。状态文件的结论与上面相反时，同样判为未确认。

隧道按以下顺序识别：先找 IPv4 等于状态文件 `tunnelIP` 的接口；再找 IPv4 位于 `tunnel.cidr` 的接口；状态文件没有提供 `tunnelIP` 时，取路由条数最多且不少于 `minRoutes` 的接口。代理的 TUN 接口、fake-ip 网段、`198.18.0.0/15`、`100.64.0.0/10`（叠加网络常用）内的地址，以及前面的适配器已经认领的接口，都不参与识别。

有多个适配器时：任一适配器未确认，VPN 状态就是未确认；否则只要有一个已连接，VPN 状态就是已连接。

## 与 DNS 规则的关系

设置中“VPN 连接时”选择“VPN 下发的 DNS”后，应用检查网络服务保存的 DNS 是否属于已连接适配器 `statusFile.dns` 报告的地址。适配器没有配置 `dns` 字段时，这条规则跳过。

选择“由代理接管”时，连接期不看 `statusFile.dns`，按断开时的规则检查保存的 DNS。这时保存值属于 `statusFile.dns`，会在证据中标为“VPN 下发的 DNS”。

“VPN 站点”只在 VPN 状态为已连接时探测。
