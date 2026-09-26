#!/usr/bin/env python3
"""生成 Tests/Fixtures/synthetic/ 下的合成快照。数值全部虚构，与任何真实网络无关。

用法：scripts/generate-synthetic-fixtures.py
改动快照后请同步更新依赖这些数值的测试。
"""
import json
import os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
base = os.path.join(root, "Tests/Fixtures/synthetic")

PRIMARY = "8F3C2A10-5B7E-4D21-9C66-0A1B2C3D4E5F"
OVERLAY = "D2E4F6A8-1357-4B9D-8ACE-246813579BDF"
LAN_IP = "192.168.1.23"
ROUTER = "192.168.1.1"
EN0_INDEX = 15
OVERLAY_INDEX = 22
EXPECTED = "119.29.29.29"
VPN_DNS = ["10.9.0.53", "10.9.0.54"]
VPN_IP = "10.9.0.2"
VPN_GW = "10.9.0.1"
TUNNEL_EXE = "/Applications/Example VPN.app/Contents/Resources/example-tunnel"

SCENARIOS = {
    # VPN 断开，TUN 运行，DNS 为预期值。
    "disconnected": dict(vpn=False, saved=[EXPECTED], effective=[EXPECTED], status=None),
    # VPN 已连接，保存的 DNS 为 VPN 下发的第一个地址。
    "connected": dict(vpn=True, saved=[VPN_DNS[0]], effective=[VPN_DNS[0]], status=True),
    # VPN 刚断开，DNS 被清空，生效 DNS 回落到路由器。
    "dns-cleared": dict(vpn=False, saved=[""], effective=[ROUTER], status=False),
}

TUN_ROUTES = ["1", "2/7", "4/6", "8/5", "16/4", "32/3", "64/2", "128.0/1", "198.18/15", "198.18.0.1/32", "198.18.0.2/32"]
VPN_ROUTES = ["10.9/16", "10.10/16", "10.11/16", "10.12.0/22", "10.12.8.8/32", "172.16",
              "172.20/16", "172.21/16", "172.22.4/24", "10.20/16", "10.30/16", "10.40.2.9/32"]


def w(scenario, name, text):
    d = os.path.join(base, scenario)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name), "w") as f:
        f.write(text)


def dns_array(values, indent="  "):
    lines = [f"{indent}ServerAddresses : <array> {{"]
    for i, v in enumerate(values):
        lines.append(f"{indent}  {i} : {v}")
    lines.append(f"{indent}}}")
    return lines


def dynstore_primary(s):
    out = [f"PrimaryService={PRIMARY}", "<dictionary> {", "  PrimaryInterface : en0",
           f"  PrimaryService : {PRIMARY}", f"  Router : {ROUTER}", "}", "<dictionary> {"]
    out += dns_array(s["effective"])
    out += [f"  __CONFIGURATION_ID__ : Default: {PRIMARY} 0", "  __FLAGS__ : 2"]
    if s["saved"] == [""]:
        out.append(f"  __IF_INDEX__ : {EN0_INDEX}")
    out += ["  __ORDER__ : 0", "}", "<dictionary> {", "  ExceptionsList : <array> {", "  }",
            "  HTTPEnable : 0", "  HTTPSEnable : 0", "  ProxyAutoConfigEnable : 0", "  SOCKSEnable : 0"]
    out += dns_array(s["saved"])
    out += ["}", "<dictionary> {"]
    out += dns_array([ROUTER])
    out += ["}"]
    return "\n".join(out) + "\n"


def dynstore_service_dns():
    out = [f"== State:/Network/Service/{PRIMARY}/DNS", "<dictionary> {"]
    out += dns_array([ROUTER])
    out += ["}", f"== State:/Network/Service/{OVERLAY}/DNS", "<dictionary> {", "  InterfaceName : utun3"]
    out += dns_array(["100.100.100.100"])
    out += ["}"]
    return "\n".join(out) + "\n"


def resolver(n, domain=None, servers=(), if_index=None, flags="Request A records", reach="0x00000002 (Reachable)",
             order=None, options=None, timeout=None):
    lines = [f"resolver #{n}"]
    if domain:
        lines.append(f"  domain   : {domain}")
    for i, s in enumerate(servers):
        lines.append(f"  nameserver[{i}] : {s}")
    if if_index:
        lines.append(f"  if_index : {if_index[0]} ({if_index[1]})")
    if options:
        lines.append(f"  options  : {options}")
    if timeout:
        lines.append(f"  timeout  : {timeout}")
    lines.append(f"  flags    : {flags}")
    lines.append(f"  reach    : {reach}")
    if order is not None:
        lines.append(f"  order    : {order}")
    return "\n".join(lines)


def scutil_dns(s):
    first = s["effective"][0]
    cleared = s["saved"] == [""]
    blocks = [resolver(1, servers=[first], if_index=(EN0_INDEX, "en0") if cleared else None,
                       reach="0x00020002 (Reachable,Directly Reachable Address)" if cleared else "0x00000002 (Reachable)")]
    mdns = ["local", "254.169.in-addr.arpa", "8.e.f.ip6.arpa", "9.e.f.ip6.arpa", "a.e.f.ip6.arpa", "b.e.f.ip6.arpa"]
    for i, d in enumerate(mdns):
        blocks.append(resolver(i + 2, domain=d, options="mdns", timeout=5, reach="0x00000000 (Not Reachable)",
                               order=300000 + i * 200))
    blocks.append(resolver(8, domain="example-tailnet.ts.net", servers=["100.100.100.100"],
                           reach="0x00000003 (Reachable,Transient Connection)"))
    scoped = [
        resolver(1, servers=[first], if_index=(EN0_INDEX, "en0"), flags="Scoped, Request A records"),
        resolver(2, servers=["100.100.100.100"], if_index=(OVERLAY_INDEX, "utun3"),
                 flags="Scoped, Request A records, Request AAAA records",
                 reach="0x00000003 (Reachable,Transient Connection)"),
    ]
    return ("DNS configuration\n\n" + "\n\n".join(blocks) + "\n\nDNS configuration (for scoped queries)\n\n"
            + "\n\n".join(scoped) + "\n")


def route(dest, gw, flags, netif, expire=""):
    return f"{dest:<19}{gw:<19}{flags:<20}{netif:>6}{(' ' + expire) if expire else ''}"


def netstat(s):
    rows = [route("default", ROUTER, "UGScg", "en0"), route("default", f"link#{OVERLAY_INDEX}", "UCSIg", "utun3")]
    rows += [route(d, "198.18.0.1", "UGSc", "utun1024") for d in TUN_ROUTES]
    if s["vpn"]:
        rows += [route(d, VPN_GW, "UGSc", "utun7") for d in VPN_ROUTES]
    rows += [
        route("100.64/10", f"link#{OVERLAY_INDEX}", "UCS", "utun3"),
        route("100.100.100.100/32", f"link#{OVERLAY_INDEX}", "UCS", "utun3"),
        route("100.64.0.2", "100.64.0.2", "UH", "utun3"),
        route("127", "127.0.0.1", "UCS", "lo0"),
        route("127.0.0.1", "127.0.0.1", "UH", "lo0"),
        route("169.254", f"link#{EN0_INDEX}", "UCS", "en0", "!"),
        route("192.168.1", f"link#{EN0_INDEX}", "UCS", "en0", "!"),
        route(ROUTER, "xx:xx:xx:xx:xx:xx", "UHLWIir", "en0", "1187"),
        route("192.168.1.40", "xx:xx:xx:xx:xx:xx", "UHLWI", "en0", "1104"),
        route(f"{LAN_IP}/32", f"link#{EN0_INDEX}", "UCS", "en0", "!"),
        route("192.168.1.255", "xx:xx:xx:xx:xx:xx", "UHLWbI", "en0", "!"),
        route("224.0.0/4", f"link#{EN0_INDEX}", "UmCS", "en0", "!"),
        route("255.255.255.255/32", f"link#{EN0_INDEX}", "UCS", "en0", "!"),
    ]
    head = "Routing tables\n\nInternet:\nDestination        Gateway            Flags               Netif Expire\n"
    return head + "\n".join(rows) + "\n"


def ifconfig(s):
    parts = [
        "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n"
        "\tether xx:xx:xx:xx:xx:xx\n"
        f"\tinet {LAN_IP} netmask 0xffffff00 broadcast 192.168.1.255\n"
        "\tstatus: active",
    ]
    for n, mtu in [(0, 1380), (1, 2000), (2, 1000)]:
        parts.append(f"utun{n}: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu {mtu}\n\tnd6 options=201<PERFORMNUD,DAD>")
    parts.append("utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280\n"
                 "\tinet 100.64.0.2 --> 100.64.0.2 netmask 0xffffffff")
    for n in (4, 5):
        parts.append(f"utun{n}: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380\n\tnd6 options=201<PERFORMNUD,DAD>")
    parts.append("utun1024: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 9000\n"
                 "\tinet 198.18.0.1 --> 198.18.0.1 netmask 0xfffffffc")
    if s["vpn"]:
        parts.append("utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400\n"
                     f"\tinet {VPN_IP} --> {VPN_GW} netmask 0xffffff00")
    return "\n".join(parts) + "\n"


def ps(s):
    rows = [
        (812, 1, "root", "/Library/PrivilegedHelperTools/io.github.clash-verge-rev.clash-verge-rev.service.bundle/Contents/MacOS/clash-verge-service"),
        (2210, 1, "user", "/Applications/Clash Verge.app/Contents/MacOS/clash-verge"),
        (2215, 812, "root", "/Library/Application Support/clash-verge-service/cores/verge-mihomo"),
        (3101, 1, "user", "/Applications/Example VPN.app/Contents/MacOS/Example VPN"),
        (3102, 3101, "user", "/Applications/Example VPN.app/Contents/Frameworks/Example VPN Helper.app/Contents/MacOS/Example VPN Helper"),
        (3105, 1, "user", "~/Library/Application Support/Example VPN/agent/example-agent"),
    ]
    if s["vpn"]:
        rows.append((7300, 3101, "root", TUNNEL_EXE))
    rows.sort()
    out = ["  PID  PPID USER             STARTED                      COMM"]
    for pid, ppid, user, path in rows:
        out.append(f"{pid:>5} {ppid:>5} {user:<16} Mon Jan  5 09:30:00 2026     {path}")
    return "\n".join(out) + "\n"


def status(active):
    return json.dumps({"session": {"active": active, "pending": False, "address": VPN_IP, "resolvers": VPN_DNS},
                       "profile": {"name": "synthetic-profile", "token": "synthetic-token"}}, indent=2) + "\n"


for name, s in SCENARIOS.items():
    w(name, "dynstore-primary.txt", dynstore_primary(s))
    w(name, "dynstore-service-dns.txt", dynstore_service_dns())
    w(name, "scutil-dns.txt", scutil_dns(s))
    w(name, "netstat-rn.txt", netstat(s))
    w(name, "ifconfig.txt", ifconfig(s))
    w(name, "ps.txt", ps(s))
    if s["status"] is not None:
        w(name, "vpn-status.json", status(s["status"]))

adapter = {
    "id": "example",
    "name": "Example VPN",
    "process": {"executablePaths": [TUNNEL_EXE, "~/Library/Application Support/Example VPN/bin/example-tunnel"]},
    "statusFile": {"path": "~/Library/Application Support/Example VPN/state.json",
                   "connected": "/session/active", "connecting": "/session/pending",
                   "tunnelIP": "/session/address", "dns": "/session/resolvers"},
    "tunnel": {"minRoutes": 10},
}
with open(os.path.join(base, "example-vpn.json"), "w") as f:
    f.write(json.dumps(adapter, indent=2, ensure_ascii=False) + "\n")

readme = """# 合成快照

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
"""
with open(os.path.join(base, "README.md"), "w") as f:
    f.write(readme)
print("ok")
