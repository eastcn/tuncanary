# TunCanary

[中文](README.md)

TunCanary is a macOS menu bar app. When a proxy's TUN, a VPN and always-on tunnels such as Tailscale run side by side, it checks whether the local network has quietly gone wrong. The main check is whether system DNS queries bypass the TUN interface of a Clash-style proxy.

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/popover-ok-dark.png"><img src="docs/images/popover-ok-light.png" width="330" alt="Popover: all checks pass"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/popover-dns-critical-dark.png"><img src="docs/images/popover-dns-critical-light.png" width="330" alt="Popover: DNS not restored after the VPN disconnected"></picture>
</p>

<p align="center">Left: all checks pass. Right: DNS was not restored after the VPN disconnected, so queries bypass the proxy. The interface is in Chinese; the data is fictional.</p>

## Who it is for

TunCanary assumes you use a Clash-style proxy in TUN mode to manage the machine's network: the proxy, VPNs and tunnels such as Tailscale coexist, and TUN plus the proxy rules decide which path traffic takes. With a single proxy or a single VPN, the setup is simple and you probably do not need it.

TUN being off is a normal state, not a failure. The Proxy TUN card then shows "disabled in config", and the other checks keep running; only checks that depend on fake-ip are skipped.

## The problem

When a Clash-style proxy runs in TUN mode with fake-ip DNS, every name resolved through the system resolver should come back as a fake-ip address from the configured `fake-ip-range` (commonly `198.18.0.1/16`). A real address means the query did not go through the proxy.

This often happens alongside a VPN client. The client rewrites the network service's DNS when it connects and does not restore it when it disconnects, so queries go straight to the router on the local network. Websites still load, so connectivity checks do not notice, but DNS now leaks outside the proxy.

TunCanary periodically resolves a canary domain with the system resolver. If it gets a real address, it reports a failure and posts a notification.

## What it checks

| Card | Check |
| --- | --- |
| Proxy TUN | TUN enabled in the proxy config, an UP utun interface inside the fake-ip range, and the core process running |
| VPN | VPN processes, tunnels and routes, identified by adapter configs you write; unrecognized tunnels are reported. Conflicting evidence is shown as "unconfirmed" |
| Primary DNS | Whether the canary resolves to a fake-ip address; optionally, whether the network service's saved DNS matches your rules. The canary's AAAA result is shown as evidence only and never raises an alert |
| Proxy DNS | Whether the proxy's local DNS port answers |
| Tailnet | Shown only when a Tailscale tunnel exists or a tailnet subnet target is set. Whether tailnet routes go through the Tailscale tunnel, whether MagicDNS resolves this Mac's name back to its own address, and which route the tailnet subnet target takes |

It also probes a list of sites in groups, by default every 2 minutes, and alerts after three consecutive failed rounds. With proxy diagnosis on, the result appears under the site row: the rule and node this request hit.

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/proxy-diagnosis-dark.png"><img src="docs/images/proxy-diagnosis-light.png" width="380" alt="Proxy diagnosis under a site row"></picture></p>

The "出口 IP" (exit IP) section always shows each target's exit IP. Target details start collapsed and expand independently when a row is clicked; closing the popover collapses them again. Background sampling continues in either state. It samples automatically while the app runs and the system is awake, every 5 minutes by default. Set an interval from 5 to 1440 minutes in Settings. Background requests are staggered across targets; manual checks share the same cooldown. Each target shows the measured exit, location, sample time, change count and 30 days of local history. IPv4 and IPv6 are compared separately. Failed samples and gaps interrupt the observed unchanged period; changes between samples may be missed.

Cloudflare is always enabled. Claude, ChatGPT and ByteDance's test CDN are optional, along with up to five custom targets. Cloudflare targets use `/cdn-cgi/trace`; the ByteDance target reads an IP response header with HEAD at `perfops.byte-test.com`. Custom targets may use a Cloudflare domain or an HTTPS echo endpoint with a response header (HEAD) or JSON field (GET, e.g. `data.ip`). These measurements represent this app's requests to the configured endpoint. The legacy unofficial Taobao IP lookup remains manual only.

Select allowed countries and regions separately for each target. The picker offers six common regions and a searchable full list. With no selection, location is recorded without alerts. Two consecutive valid observations outside the allowed set trigger one notification; a confirmed recovery triggers one more. IP changes are recorded silently unless their notification switch is enabled. Unknown, stale or conflicting location evidence does not create a region alert. All notifications respect the global switch. A 429 respects `Retry-After`; failures back off, and a 403 or detected challenge pauses the target until you resume it. Requests carry no browser cookies and do not follow redirects.

Settings open from "设置" at the bottom of the popover and are split into three tabs: 站点 (sites, the VPN site, the tailnet subnet target, exit IP targets and test pages), 代理与 DNS (proxy client, DNS rules, probe domain) and 通用 (check interval, notifications, launch at login, VPN adapters). A tab with an error shows a red dot.

The Tailnet card turns red when the MagicDNS address or `100.64.0.0/10` is not routed through the Tailscale tunnel, when the tailnet subnet target leaves through the default route, the proxy's TUN or another tunnel (the subnet route is not in effect), or when a TCP connection to the target fails three rounds in a row. It turns yellow when MagicDNS does not answer, or when the system resolves this Mac's MagicDNS name to a fake-ip, another address, or not at all. It is grey, and the target is not probed, when the target lies in the current network's subnet (for example at the site itself, or on another network that happens to use the same range) or when Tailscale is not connected. A grey Tailnet card does not affect the overall status or the exit code. The TCP probe only opens a connection; a refused connection still proves the path works.

## VPNs and always-on tunnels

TunCanary treats two kinds of tunnel differently:

| | VPN | Always-on tunnel (e.g. Tailscale) |
| --- | --- | --- |
| Usage | Connected and disconnected on demand; often rewrites the network service's DNS when it connects | Stays connected; only handles its own address range and domains |
| Detection | Adapter configs you write, see [docs/ADAPTERS.md](docs/ADAPTERS.md) | Automatic: a utun with an address in `100.64.0.0/10` is treated as likely Tailscale |
| Affects verdicts | Yes. Whether the VPN is connected decides which DNS rule applies to the primary service | Not part of the VPN verdict; checked separately by the Tailnet card |

Do not write a VPN adapter for an always-on tunnel such as Tailscale. The adapter would make TunCanary think a VPN is always connected, and the DNS rule for the disconnected state would never apply. The DNS guard never modifies VPN-type network services such as Tailscale's.

The user interface and most documentation are currently in Chinese.

## Requirements

- macOS 13 or later.
- Xcode Command Line Tools with Swift 5.10 or later. Full Xcode is not required.

No third-party dependencies.

## Build and install

```sh
scripts/test.sh
scripts/build-app.sh
scripts/install.sh
```

`install.sh` installs `~/Applications/TunCanary.app`, writes the command-line wrapper `~/.local/bin/tuncanary`, and launches the app. Apps built locally are not quarantined, so Gatekeeper does not block them. Prebuilt packages are not provided yet.

To uninstall, run `scripts/uninstall.sh`. Add `--clear-settings` to remove settings as well.

## Command line

```sh
tuncanary --check          # one local check and a light site probe
tuncanary --check --full   # probe every enabled site three times
tuncanary --check --json   # JSON output
tuncanary --version        # print the version
```

Exit codes: `0` OK, `1` warning, `2` failure, `3` unconfirmed, `64` usage error. JSON keys and values will stay compatible across releases; new versions only add keys. Version 0.3.0 added `tailnet` (the tailnet subnet probe status) and items with `kind` `tailnet`.

The tailnet subnet target is set in Settings as `IPv4:port`, for example `192.168.1.10:443`. The first probe may trigger macOS's Local Network permission prompt; if you deny it, the row shows that permission is missing and it does not count as a failure. Diagnostics and JSON only say whether a target is configured.

"Diagnose proxy when a site fails" is off by default and works with Clash Verge Rev only. When a site first fails, or its failure type changes, the app retries once while following mihomo's log, finds the rule and outbound node this request hit, and, if the retry still fails through a node, has the proxy test that node's delay. Each site row also has a "诊断" button for a manual run. Results appear under the site row and in the diagnostics summary; they never change the verdict or trigger notifications. The control interface is the local socket Clash Verge Rev's service passes to the core (read from `verge-mihomo`'s arguments); it belongs to the current user and needs no secret. Failure details include error codes, and for TLS errors the underlying code and the server certificate's subject.

## DNS guard (optional)

The menu bar app only reports problems. The DNS guard is a separate, optional component that is not installed by default. It runs as root and, while the proxy's TUN is running, sets the primary network service's saved DNS to a target you choose, so queries go back through the proxy.

It works in two phases:

| Phase | Condition | Default |
| --- | --- | --- |
| Disconnected | TUN running, VPN disconnected, saved DNS is not the target | On |
| Connected | TUN running, VPN connected, saved DNS is not the target, and the proxy resolves a VPN probe domain you choose | Off |

Before turning on the connected phase, make sure the proxy sends VPN domains to the VPN's DNS. Otherwise VPN-only names stop resolving once the guard rewrites DNS.

How it behaves:

- A LaunchDaemon runs it when the system network configuration changes and every 30 seconds. Each run makes one decision and exits.
- It samples twice, 3 seconds apart, and writes only if both samples agree. It never writes while the VPN is switching or its state is unconfirmed. During a switch it samples again every 5 seconds, up to 3 times in the same run, so it can write as soon as the switch settles. In the connected phase, a failed VPN probe is retried the same way.
- It relies on VPN adapters to tell the VPN state. With no adapters, or an invalid adapter file, it never writes.
- It changes only the server list in the primary service's saved DNS and keeps the other DNS keys. It touches only allowed service types (Wi-Fi and Ethernet by default), never VPN services.
- After writing, it reads back the saved value and the default resolver; only a match counts as success. After 3 consecutive failures it pauses for 10 minutes.
- It never stops or restarts the proxy, and never changes proxy settings, VPN settings or routes.

Build as a normal user, then install with administrator rights:

```sh
scripts/build-app.sh
sudo scripts/install-dns-guard.sh
```

The install script copies the executable, its config and your VPN adapters to `/Library/Application Support/TunCanary/`, then loads `/Library/LaunchDaemons/io.github.eastcn.tuncanary.dns-guard.plist`. All of these are owned by root and read-only for other users.

- The target DNS defaults to the expected DNS in settings, which requires the disconnected rule to be "指定地址" (specific address). Or pass `--target-dns 223.5.5.5`.
- After changing adapters, run the install script again to copy them. It keeps the existing config and backs up old files first.
- To change the config, edit `dns-guard.json` with `sudo`. Turn on connected takeover in `connectedTakeover` and set `intranetProbeHost`.

To see what the guard would do without writing anything:

```sh
sudo "/Library/Application Support/TunCanary/bin/tuncanary-dns-guard" --dry-run
```

To uninstall:

```sh
sudo scripts/uninstall-dns-guard.sh
```

Uninstalling stops the guard and removes these files but does not revert DNS; check the saved DNS yourself afterwards.

Once installed, the primary DNS card shows whether the guard is installed and the result of its latest run and write. If the guard's target DNS differs from the expected DNS in settings, the card says so.

## Privacy

The menu bar app only reads state. It never changes DNS, TUN, proxy or VPN settings. Only the separately installed DNS guard changes the network service's saved DNS (see above). The app also reads the guard's config, state and events under `/Library/Application Support/TunCanary/` when they exist. When a Tailscale tunnel exists, it asks MagicDNS (`100.100.100.100`) for this Mac's name and resolves that name; when a tailnet subnet target is set, it opens TCP connections to it. Exit IP targets are contacted at the configured interval or on an eligible manual check. Location is queried from `ipwho.is/<measured IP>` and shared by exact IP for 7 days. This sends the measured exit IP to the location provider. MagicDNS names and the tailnet domain are never written to evidence or diagnostics. It uploads no local history or telemetry. Diagnostics, command-line output and notifications are redacted: private IP addresses keep only the first octet, and the VPN site URL and home directory are removed. A redacted log of when faults appeared, changed and cleared (at most 200 entries) is kept locally in `~/Library/Application Support/TunCanary/events.jsonl`; `scripts/uninstall.sh --clear-settings` removes it. Exit samples and location cache are kept separately in `~/Library/Application Support/TunCanary/egress-history.json`, readable and writable only by the current user. Samples expire after 30 days, with cleanup at startup and during operation. This history contains full exit IP addresses and is excluded from diagnostics, CLI JSON and fault-event exports. The same uninstall option deletes it.

## License

[MIT](LICENSE).

TunCanary is not affiliated with Clash Verge Rev, mihomo, Cloudflare, Anthropic, or any other product or website mentioned here.
