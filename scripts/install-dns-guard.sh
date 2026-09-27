#!/usr/bin/env bash
# 安装可选的 DNS 守护进程（LaunchDaemon，以 root 身份运行）。
set -euo pipefail

usage() {
    cat <<'EOF'
用法：sudo scripts/install-dns-guard.sh [--target-dns <地址,...>]

把 build/tuncanary-dns-guard、配置和当前用户的 VPN 适配器复制到
/Library/Application Support/TunCanary/，再加载 LaunchDaemon。
请先以普通用户运行 scripts/build-app.sh。

--target-dns  首次安装时的目标 DNS。省略时取 TunCanary 设置中断开期的预期 DNS。
              已有配置时保留原配置，不接受这个参数；修改请直接编辑配置文件。

安装不会立即改写 DNS，也不操作代理进程。安装后可以先试运行：
  sudo "/Library/Application Support/TunCanary/bin/tuncanary-dns-guard" --dry-run
EOF
}

target_dns=""
while (( $# > 0 )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --target-dns)
            (( $# >= 2 )) || { usage >&2; exit 64; }
            target_dns="$2"; shift 2 ;;
        *) usage >&2; exit 64 ;;
    esac
done

label="io.github.eastcn.tuncanary.dns-guard"
repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
source_binary="$repo_dir/build/tuncanary-dns-guard"

# TUNCANARY_GUARD_ROOT 只用于测试：安装到临时根目录，不要求 root，不改属主，不调用 launchctl。
root="${TUNCANARY_GUARD_ROOT:-/}"
root="${root%/}"
test_mode=0
[[ -n "$root" ]] && test_mode=1
support_dir="$root/Library/Application Support/TunCanary"
bin_dir="$support_dir/bin"
binary="$bin_dir/tuncanary-dns-guard"
config="$support_dir/dns-guard.json"
adapters_dir="$support_dir/adapters"
marker="$support_dir/.dns-guard-installed"
plist="$root/Library/LaunchDaemons/$label.plist"

if (( test_mode == 0 )); then
    [[ "$(id -u)" == 0 ]] || { printf '请用 sudo 运行。\n' >&2; exit 1; }
    user="${SUDO_USER:-}"
    [[ -n "$user" && "$user" != root ]] || { printf '无法确定登录用户：请以普通用户身份用 sudo 运行。\n' >&2; exit 1; }
    home="$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')"
    owner=(-o root -g wheel)
    as_user() { sudo -u "$user" "$@"; }
else
    user="$(id -un)"
    home="$HOME"
    owner=()
    as_user() { "$@"; }
fi
[[ "$home" == /* && -d "$home" ]] || { printf '无法确定用户主目录：%s\n' "$home" >&2; exit 1; }
user_adapters="$home/Library/Application Support/TunCanary/adapters"

[[ -f "$source_binary" && ! -L "$source_binary" ]] || { printf '请先运行 scripts/build-app.sh。\n' >&2; exit 1; }
version="$("$source_binary" --version)"
[[ "$version" == tuncanary-dns-guard\ * ]] || { printf '构建产物不是 DNS 守护进程：%s\n' "$source_binary" >&2; exit 1; }

# 只覆盖本项目安装的文件。
for path in "$support_dir" "$bin_dir" "$adapters_dir" "$binary" "$config" "$plist"; do
    [[ ! -L "$path" ]] || { printf '安装路径是符号链接，拒绝安装：%s\n' "$path" >&2; exit 1; }
done
[[ ! -e "$support_dir" || -d "$support_dir" ]] || { printf '安装路径不是目录：%s\n' "$support_dir" >&2; exit 1; }
if [[ -e "$plist" ]]; then
    existing="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null || true)"
    [[ "$existing" == "$label" ]] || { printf '已有其他 LaunchDaemon，拒绝覆盖：%s\n' "$plist" >&2; exit 1; }
fi
if [[ ! -e "$marker" ]]; then
    for path in "$binary" "$config" "$adapters_dir"; do
        [[ ! -e "$path" ]] || { printf '已有文件不是本项目安装的，拒绝覆盖：%s\n' "$path" >&2; exit 1; }
    done
fi

# 适配器：守护进程只读取 root 目录下的副本。没有适配器时无法确认 VPN 状态，守护进程不会写入。
adapter_files=()
if [[ -d "$user_adapters" ]]; then
    while IFS= read -r -d '' file; do adapter_files+=("$file"); done \
        < <(find "$user_adapters" -maxdepth 1 -type f -name '*.json' ! -name '.*' -print0 | sort -z)
fi
(( ${#adapter_files[@]} > 0 )) || {
    printf '未找到 VPN 适配器：%s\n请先按 docs/ADAPTERS.md 编写适配器，否则守护进程无法确认 VPN 状态。\n' "$user_adapters" >&2
    exit 1
}

if [[ -e "$config" ]]; then
    [[ -z "$target_dns" ]] || {
        printf '配置已存在，保留原配置。修改目标 DNS 请用 sudo 编辑：%s\n' "$config" >&2; exit 1;
    }
    keep_config=1
else
    keep_config=0
    if [[ -z "$target_dns" ]]; then
        target_dns="$(as_user "$source_binary" --suggest-target)" || {
            printf '请用 --target-dns 指定目标 DNS。\n' >&2; exit 1;
        }
    fi
fi

# 升级前备份本项目的旧文件。
if [[ -e "$marker" ]]; then
    backup="$support_dir/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup"
    for path in "$binary" "$config" "$adapters_dir" "$plist"; do
        [[ -e "$path" ]] && cp -R "$path" "$backup/"
    done
    printf '已备份旧文件：%s\n' "$backup"
fi

install -d -m 755 ${owner[@]+"${owner[@]}"} "$support_dir" "$bin_dir" "$root/Library/LaunchDaemons"
work="$(mktemp -d "$support_dir/.install.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

install -m 755 ${owner[@]+"${owner[@]}"} "$source_binary" "$work/tuncanary-dns-guard"
mv -f "$work/tuncanary-dns-guard" "$binary"

if (( keep_config == 0 )); then
    "$binary" --print-config --home "$home" --target-dns "$target_dns" > "$work/dns-guard.json"
    install -m 644 ${owner[@]+"${owner[@]}"} "$work/dns-guard.json" "$config"
fi

rm -rf -- "$adapters_dir"
install -d -m 755 ${owner[@]+"${owner[@]}"} "$adapters_dir"
for file in "${adapter_files[@]}"; do
    install -m 644 ${owner[@]+"${owner[@]}"} "$file" "$adapters_dir/$(basename "$file")"
done

printf '%s\n' "$version" > "$work/marker"
install -m 644 ${owner[@]+"${owner[@]}"} "$work/marker" "$marker"

cat > "$work/daemon.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array><string>/Library/Application Support/TunCanary/bin/tuncanary-dns-guard</string></array>
    <key>WatchPaths</key>
    <array><string>/Library/Preferences/SystemConfiguration/preferences.plist</string></array>
    <key>StartInterval</key><integer>30</integer>
    <key>RunAtLoad</key><true/>
    <key>Umask</key><integer>18</integer>
</dict>
</plist>
EOF
plutil -lint "$work/daemon.plist" >/dev/null
install -m 644 ${owner[@]+"${owner[@]}"} "$work/daemon.plist" "$plist"

if (( test_mode == 0 )); then
    launchctl bootout "system/$label" 2>/dev/null || true
    launchctl bootstrap system "$plist"
fi

printf '已安装 DNS 守护进程（%s）\n' "$version"
(( keep_config == 1 )) && printf '保留了原配置：%s\n' "$config"
printf '配置：%s\n适配器：%d 个\n' "$config" "${#adapter_files[@]}"
printf '事件日志：%s\n' "$support_dir/dns-guard-events.jsonl"
