#!/usr/bin/env bash
# 注销登录项、退出应用，并移除安装器创建的应用与命令行入口。
set -euo pipefail

usage() {
    cat <<'EOF'
用法：scripts/uninstall.sh [--clear-settings] [--skip-login-item] [--help]

默认保留 TunCanary 设置。传入 --clear-settings 时，一并删除
io.github.eastcn.tuncanary 的 UserDefaults 设置和本机的故障事件日志。
传入 --skip-login-item 时跳过登录项注销（例如系统无法查询登录项时）。
登录项未注册或系统找不到时，默认流程也会视为无需注销并继续。
EOF
}

clear_settings=0
skip_login_item=0
for argument in "$@"; do
    case "$argument" in
        --help|-h) usage; exit 0 ;;
        --clear-settings) clear_settings=1 ;;
        --skip-login-item) skip_login_item=1 ;;
        *) usage >&2; exit 64 ;;
    esac
done

apps_dir="$HOME/Applications"
app="$apps_dir/TunCanary.app"
binary="$app/Contents/MacOS/TunCanary"
bin_dir="$HOME/.local/bin"
wrapper="$bin_dir/tuncanary"
bundle_id="io.github.eastcn.tuncanary"
marker="# TunCanary installer wrapper"
event_log="$HOME/Library/Application Support/TunCanary/events.jsonl"

running_pids() {
    local executable="$1" pattern='^' char index result status
    for (( index = 0; index < ${#executable}; index++ )); do
        char="${executable:index:1}"
        case "$char" in
            [a-zA-Z0-9/_-]) pattern+="$char" ;;
            *) pattern+="\\$char" ;;
        esac
    done
    if result="$(pgrep -f "${pattern}([[:space:]]|$)")"; then
        printf '%s\n' "$result"
    else
        status=$?
        (( status == 1 )) || { printf '无法查询运行中的应用进程。\n' >&2; return "$status"; }
    fi
}

[[ ! -L "$apps_dir" && ! -L "$bin_dir" ]] || { printf '安装目录是符号链接，拒绝卸载。\n' >&2; exit 1; }
[[ ! -L "$app" && ! -L "$wrapper" ]] || { printf '安装目标是符号链接，拒绝卸载。\n' >&2; exit 1; }
if [[ -e "$app" ]]; then
    [[ -d "$app" && -x "$binary" ]] || { printf '应用包不完整，拒绝删除：%s\n' "$app" >&2; exit 1; }
    actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$actual_id" == "$bundle_id" ]] || { printf '应用的 bundle id 不符，拒绝删除：%s\n' "$app" >&2; exit 1; }
    codesign --verify --deep --strict "$app" || { printf '应用签名无效，拒绝执行卸载入口：%s\n' "$app" >&2; exit 1; }
fi
if [[ -e "$wrapper" ]]; then
    [[ -f "$wrapper" && "$(sed -n '2p' "$wrapper")" == "$marker" ]] || {
        printf '命令行入口不是本安装器创建的文件，拒绝删除：%s\n' "$wrapper" >&2; exit 1;
    }
fi

if [[ -e "$app" ]]; then
    # 登录项必须在删除应用包前由包内进程注销；未注册时包内进程会说明无需注销并返回成功。
    if (( skip_login_item == 1 )); then
        printf '已按参数跳过登录项注销。\n'
    else
        "$binary" --unregister-login-item
    fi
    pids="$(running_pids "$binary")"
    if [[ -n "$pids" ]]; then
        while IFS= read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done <<< "$pids"
        for (( attempt = 0; attempt < 50; attempt++ )); do
            pids="$(running_pids "$binary")"
            [[ -z "$pids" ]] && break
            sleep 0.2
        done
        pids="$(running_pids "$binary")"
        [[ -z "$pids" ]] || { printf '应用未退出，卸载已取消。\n' >&2; exit 1; }
    fi
fi

if (( clear_settings == 1 )); then
    if defaults read "$bundle_id" >/dev/null 2>&1; then
        defaults delete "$bundle_id" >/dev/null
    fi
    if [[ -f "$event_log" && ! -L "$event_log" ]]; then rm -f -- "$event_log"; fi
fi

if [[ -e "$app" ]]; then rm -rf -- "$app"; fi
if [[ -e "$wrapper" ]]; then rm -f -- "$wrapper"; fi
printf '已卸载 TunCanary。'
if (( clear_settings == 1 )); then printf '设置已清除。\n'; else printf '设置已保留。\n'; fi
