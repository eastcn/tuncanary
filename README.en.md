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

## Privacy

TunCanary only reads state. It never changes DNS, TUN, proxy or VPN settings. It collects and uploads nothing. Diagnostics, command-line output and notifications are redacted: private IP addresses keep only the first octet, and the intranet URL and home directory are removed. A redacted log of when faults appeared, changed and cleared (at most 200 entries) is kept locally in `~/Library/Application Support/TunCanary/events.jsonl`; `scripts/uninstall.sh --clear-settings` removes it.

## License

[MIT](LICENSE).

TunCanary is not affiliated with Clash Verge Rev, mihomo, Cloudflare, Anthropic, or any other product or website mentioned here.
