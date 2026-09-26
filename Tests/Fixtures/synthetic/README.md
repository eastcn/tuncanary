# 合成快照

测试用的虚构网络状态，由脚本生成，数值与任何真实网络无关。

| 目录 | 状态 | 期望判定（预期 DNS 为 119.29.29.29） |
| --- | --- | --- |
| `disconnected` | Example VPN 断开，TUN 运行，DNS 为预期值 | 绿 |
| `connected` | Example VPN 已连接，DNS 为 VPN 下发的第一个地址 | 绿（连接期） |
| `dns-cleared` | Example VPN 刚断开，DNS 被清空，生效 DNS 回落到路由器 | 红 |

每个目录包含 `scutil --dns`、`netstat -rn -f inet`、`ifconfig` 的输出，SCDynamicStore 中主服务与各服务的 DNS，
以及进程列表（`ps.txt`，只列相关进程）。`vpn-status.json` 是 Example VPN 的状态文件，
`example-vpn.json` 是对应的声明式适配器配置。`utun3` 是一个叠加网络（CGNAT 地址），不参与 VPN 判定。

重新生成：`scripts/generate-synthetic-fixtures.py`。
