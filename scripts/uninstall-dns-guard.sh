#!/usr/bin/env bash
# 卸载 DNS 守护进程。不改回 DNS，不操作代理进程。
set -euo pipefail

usage() {
    cat <<'EOF'
用法：sudo scripts/uninstall-dns-guard.sh

停用 LaunchDaemon，删除 scripts/install-dns-guard.sh 安装的文件，包括配置、
状态文件、事件日志和升级时的备份。

卸载不会改回网络服务保存的 DNS：那时的 VPN 和 TUN 状态可能已经变了。
卸载后请自己核对，例如：networksetup -getdnsservers Wi-Fi
EOF
}

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 64 ;;
esac

label="io.github.eastcn.tuncanary.dns-guard"
# TUNCANARY_GUARD_ROOT 只用于测试，见 install-dns-guard.sh。
root="${TUNCANARY_GUARD_ROOT:-/}"
root="${root%/}"
test_mode=0
[[ -n "$root" ]] && test_mode=1
support_dir="$root/Library/Application Support/TunCanary"
marker="$support_dir/.dns-guard-installed"
plist="$root/Library/LaunchDaemons/$label.plist"

(( test_mode == 1 )) || [[ "$(id -u)" == 0 ]] || { printf '请用 sudo 运行。\n' >&2; exit 1; }

if [[ -e "$plist" || -L "$plist" ]]; then
    [[ -f "$plist" && ! -L "$plist" ]] || { printf 'LaunchDaemon 不是普通文件，拒绝删除：%s\n' "$plist" >&2; exit 1; }
    existing="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null || true)"
    [[ "$existing" == "$label" ]] || { printf 'LaunchDaemon 不是本项目安装的，拒绝删除：%s\n' "$plist" >&2; exit 1; }
fi
if (( test_mode == 0 )); then
    launchctl bootout "system/$label" 2>/dev/null || true
fi
rm -f -- "$plist"

if [[ -d "$support_dir" && ! -L "$support_dir" ]]; then
    [[ -e "$marker" ]] || {
        printf '未找到安装标记，只停用了 LaunchDaemon，没有删除文件：%s\n' "$support_dir" >&2; exit 1;
    }
    rm -f -- "$support_dir/bin/tuncanary-dns-guard" "$support_dir/dns-guard.json" \
        "$support_dir/dns-guard-state.json" "$support_dir/dns-guard-events.jsonl"
    rm -rf -- "$support_dir/adapters"
    find "$support_dir" -maxdepth 1 -type d -name 'backup-*' -exec rm -rf -- {} +
    rmdir "$support_dir/bin" 2>/dev/null || true
    rm -f -- "$marker"
    rmdir "$support_dir" 2>/dev/null || true
fi

printf '已卸载 DNS 守护进程。保存的 DNS 没有改回，请按当前状态自行核对。\n'
