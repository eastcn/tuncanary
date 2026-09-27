#!/usr/bin/env bash
# 编译 TunCanary，并组装、签名可安装的 macOS 应用包。
set -euo pipefail

usage() {
    cat <<'EOF'
用法：scripts/build-app.sh [--help]

执行 swift build -c release，生成 build/TunCanary.app 并校验 ad-hoc 签名。
EOF
}

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 64 ;;
esac
if (( $# > 1 )); then usage >&2; exit 64; fi

repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
build_dir="$repo_dir/build"
app_path="$build_dir/TunCanary.app"
bundle_id="io.github.eastcn.tuncanary"
identity_source="$repo_dir/Sources/TunCanaryCore/Basics/AppIdentity.swift"
version="$(sed -n 's/^[[:space:]]*public static let version = "\([0-9A-Za-z.-]*\)"$/\1/p' "$identity_source")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
    printf '无法从 %s 读取版本号\n' "$identity_source" >&2; exit 1;
}

for tool in swift iconutil codesign plutil; do
    command -v "$tool" >/dev/null || { printf '缺少构建工具：%s\n' "$tool" >&2; exit 1; }
done

cd "$repo_dir"
[[ ! -L "$build_dir" ]] || { printf '构建目录是符号链接，拒绝写入：%s\n' "$build_dir" >&2; exit 1; }
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
binary="$bin_dir/TunCanary"
[[ -x "$binary" ]] || { printf '未找到 release 可执行文件：%s\n' "$binary" >&2; exit 1; }

mkdir -p "$build_dir"
[[ ! -L "$app_path" ]] || { printf '产物路径是符号链接，拒绝覆盖：%s\n' "$app_path" >&2; exit 1; }
if [[ -e "$app_path" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
    [[ -d "$app_path" && "$existing_id" == "$bundle_id" ]] || {
        printf '产物路径已有其他内容，拒绝覆盖：%s\n' "$app_path" >&2; exit 1;
    }
fi
work_dir="$(mktemp -d "$build_dir/.tuncanary-build.XXXXXX")"
stage="$work_dir/TunCanary.app"
iconset="$work_dir/TunCanary.iconset"
backup="$work_dir/previous.app"
published=0
had_previous=0
cleanup() {
    result=$?
    if (( published == 0 && had_previous == 1 )) && [[ ! -e "$app_path" && -d "$backup" ]]; then
        if ! mv "$backup" "$app_path"; then
            printf '恢复旧构建失败，备份已保留：%s\n' "$backup" >&2
            exit "$result"
        fi
    fi
    rm -rf -- "$work_dir"
    exit "$result"
}
trap cleanup EXIT

mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources" "$iconset"
cp "$binary" "$stage/Contents/MacOS/TunCanary"
chmod 755 "$stage/Contents/MacOS/TunCanary"
cat > "$stage/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>TunCanary</string>
    <key>CFBundleExecutable</key><string>TunCanary</string>
    <key>CFBundleIconFile</key><string>TunCanary.icns</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>TunCanary</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
plutil -lint "$stage/Contents/Info.plist" >/dev/null

"$binary" --export-icon "$iconset"
for file in \
    icon_16x16.png icon_16x16@2x.png \
    icon_32x32.png icon_32x32@2x.png \
    icon_128x128.png icon_128x128@2x.png \
    icon_256x256.png icon_256x256@2x.png \
    icon_512x512.png icon_512x512@2x.png; do
    [[ -s "$iconset/$file" ]] || { printf '图标导出缺失：%s\n' "$file" >&2; exit 1; }
done
iconutil -c icns -o "$stage/Contents/Resources/TunCanary.icns" "$iconset"
[[ -s "$stage/Contents/Resources/TunCanary.icns" ]]

codesign --force --sign - "$stage"
codesign --verify --deep --strict --verbose=2 "$stage"

if [[ -e "$app_path" ]]; then
    [[ -d "$app_path" ]] || { printf '产物路径不是目录：%s\n' "$app_path" >&2; exit 1; }
    mv "$app_path" "$backup"
    had_previous=1
fi
mv "$stage" "$app_path"
published=1
printf '已生成：%s\n' "$app_path"
