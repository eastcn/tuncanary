#!/usr/bin/env bash
# 安装已构建的应用，并提供固定路径的命令行入口。
set -euo pipefail

usage() {
    cat <<'EOF'
用法：scripts/install.sh [--help]

把 build/TunCanary.app 安装到 ~/Applications，写入 ~/.local/bin/tuncanary，
并启动菜单栏应用。请先运行 scripts/build-app.sh。
EOF
}

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 64 ;;
esac
if (( $# > 1 )); then usage >&2; exit 64; fi

repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
source_app="$repo_dir/build/TunCanary.app"
apps_dir="$HOME/Applications"
target_app="$apps_dir/TunCanary.app"
bin_dir="$HOME/.local/bin"
wrapper="$bin_dir/tuncanary"
bundle_id="io.github.eastcn.tuncanary"
marker="# TunCanary installer wrapper"

for tool in ditto codesign open pgrep; do
    command -v "$tool" >/dev/null || { printf '缺少安装工具：%s\n' "$tool" >&2; exit 1; }
done
plist_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}
[[ -d "$source_app" && ! -L "$source_app" ]] || { printf '请先运行 scripts/build-app.sh。\n' >&2; exit 1; }
[[ "$(plist_id "$source_app")" == "$bundle_id" ]] || { printf '构建产物的 bundle id 不符。\n' >&2; exit 1; }
codesign --verify --deep --strict "$source_app"

[[ ! -L "$apps_dir" && ! -L "$bin_dir" ]] || { printf '安装目录是符号链接，拒绝安装。\n' >&2; exit 1; }
mkdir -p "$apps_dir" "$bin_dir"
[[ ! -L "$target_app" && ! -L "$wrapper" ]] || { printf '安装目标是符号链接，拒绝覆盖。\n' >&2; exit 1; }
if [[ -e "$target_app" ]]; then
    [[ -d "$target_app" && "$(plist_id "$target_app")" == "$bundle_id" ]] || {
        printf '目标路径已有其他内容，拒绝覆盖：%s\n' "$target_app" >&2; exit 1;
    }
fi
if [[ -e "$wrapper" ]]; then
    [[ -f "$wrapper" ]] && [[ "$(sed -n '2p' "$wrapper")" == "$marker" ]] || {
        printf '命令行入口已有其他内容，拒绝覆盖：%s\n' "$wrapper" >&2; exit 1;
    }
fi

work_dir="$(mktemp -d "$apps_dir/.tuncanary-install.XXXXXX")"
stage_app="$work_dir/TunCanary.app"
previous_app="$work_dir/previous.app"
stage_wrapper="$work_dir/tuncanary"
previous_wrapper="$work_dir/previous-wrapper"
old_app_moved=0
new_app_moved=0
old_wrapper_moved=0
new_wrapper_moved=0
committed=0
cleanup() {
    result=$?
    restore_failed=0
    if (( committed == 0 )); then
        if (( new_wrapper_moved == 1 )); then rm -f -- "$wrapper" || restore_failed=1; fi
        if (( old_wrapper_moved == 1 )); then mv "$previous_wrapper" "$wrapper" || restore_failed=1; fi
        if (( new_app_moved == 1 )); then rm -rf -- "$target_app" || restore_failed=1; fi
        if (( old_app_moved == 1 )); then mv "$previous_app" "$target_app" || restore_failed=1; fi
    fi
    if (( restore_failed == 0 )); then
        rm -rf -- "$work_dir"
    else
        printf '恢复旧安装失败，备份已保留：%s\n' "$work_dir" >&2
    fi
    exit "$result"
}
trap cleanup EXIT

ditto "$source_app" "$stage_app"
codesign --verify --deep --strict "$stage_app"
cat > "$stage_wrapper" <<'EOF'
#!/usr/bin/env bash
# TunCanary installer wrapper
exec "$HOME/Applications/TunCanary.app/Contents/MacOS/TunCanary" "$@"
EOF
chmod 755 "$stage_wrapper"
if [[ -e "$wrapper" ]] && ! cmp -s "$wrapper" "$stage_wrapper"; then
    printf '命令行入口已被修改，拒绝覆盖：%s\n' "$wrapper" >&2
    exit 1
fi

running_pids() {
    local executable="$1" pattern='^' char index result status
    for (( index = 0; index < ${#executable}; index++ )); do
        char="${executable:index:1}"
        case "$char" in
            [a-zA-Z0-9/_-]) pattern+="$char" ;;
            *) pattern+="\\$char" ;;
        esac
    done
    # macOS 可能在可执行路径后附加 -psn 参数。
    if result="$(pgrep -f "${pattern}([[:space:]]|$)")"; then
        printf '%s\n' "$result"
    else
        status=$?
        (( status == 1 )) || { printf '无法查询运行中的应用进程。\n' >&2; return "$status"; }
    fi
}
stop_running_app() {
    local executable="$1" pids pid attempt
    pids="$(running_pids "$executable")" || return 1
    [[ -z "$pids" ]] && return 0
    while IFS= read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done <<< "$pids"
    for (( attempt = 0; attempt < 50; attempt++ )); do
        pids="$(running_pids "$executable")" || return 1
        [[ -z "$pids" ]] && return 0
        sleep 0.2
    done
    printf '旧应用未退出，安装已取消：%s\n' "$executable" >&2
    return 1
}
stop_running_app "$target_app/Contents/MacOS/TunCanary"

if [[ -e "$target_app" ]]; then mv "$target_app" "$previous_app"; old_app_moved=1; fi
mv "$stage_app" "$target_app"; new_app_moved=1
if [[ -e "$wrapper" ]]; then mv "$wrapper" "$previous_wrapper"; old_wrapper_moved=1; fi
mv "$stage_wrapper" "$wrapper"; new_wrapper_moved=1
open -a "$target_app"
committed=1
printf '已安装并启动：%s\n命令行入口：%s\n' "$target_app" "$wrapper"
