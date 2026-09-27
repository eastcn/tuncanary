# TunCanary

[中文](README.md)

TunCanary is a macOS menu bar app that checks whether system DNS queries bypass the TUN interface of a Clash-style proxy.

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

It also probes a list of sites in groups and alerts after two consecutive failed rounds.

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

Exit codes: `0` OK, `1` warning, `2` failure, `3` unconfirmed, `64` usage error. JSON keys and values will stay compatible across releases.

## DNS guard (optional)

The menu bar app only reports problems. The DNS guard is a separate, optional component that is not installed by default. It runs as root and, while the proxy's TUN is running, sets the primary network service's saved DNS to a target you choose, so queries go back through the proxy.

It works in two phases:

| Phase | Condition | Default |
| --- | --- | --- |
| Disconnected | TUN running, VPN disconnected, saved DNS is not the target | On |
| Connected | TUN running, VPN connected, saved DNS is not the target, and the proxy resolves an intranet probe domain you choose | Off |

Before turning on the connected phase, make sure the proxy sends intranet domains to the VPN's DNS. Otherwise intranet names stop resolving once the guard rewrites DNS.

How it behaves:

- A LaunchDaemon runs it when the system network configuration changes and every 30 seconds. Each run makes one decision and exits.
- It samples twice, 3 seconds apart, and writes only if both samples agree. It never writes while the VPN is switching or its state is unconfirmed. During a switch it samples again every 5 seconds, up to 3 times in the same run, so it can write as soon as the switch settles. In the connected phase, a failed intranet probe is retried the same way.
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

The menu bar app only reads state. It never changes DNS, TUN, proxy or VPN settings. Only the separately installed DNS guard changes the network service's saved DNS (see above). The app also reads the guard's config, state and events under `/Library/Application Support/TunCanary/` when they exist. It collects and uploads nothing. Diagnostics, command-line output and notifications are redacted: private IP addresses keep only the first octet, and the intranet URL and home directory are removed. A redacted log of when faults appeared, changed and cleared (at most 200 entries) is kept locally in `~/Library/Application Support/TunCanary/events.jsonl`; `scripts/uninstall.sh --clear-settings` removes it.

## License

[MIT](LICENSE).

TunCanary is not affiliated with Clash Verge Rev, mihomo, Cloudflare, Anthropic, or any other product or website mentioned here.
