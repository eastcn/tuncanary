#!/usr/bin/env bash
# 用离屏渲染生成 README 截图（全部为虚构数据），写入 docs/images/。
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
TUNCANARY_RENDER_DIR="$work" scripts/test.sh UI.RenderPreview >/dev/null

out=docs/images
mkdir -p "$out"
for mode in light dark; do
    cp "$work/popover-allGreen-$mode.png" "$out/popover-ok-$mode.png"
    cp "$work/popover-dnsCritical-$mode.png" "$out/popover-dns-critical-$mode.png"
    # 站点区域中“海外”一组，含代理诊断结果。
    sips -c 420 760 --cropOffset 890 0 "$work/popover-googleWarning-full-$mode.png" \
        --out "$out/proxy-diagnosis-$mode.png" >/dev/null
done
ls -l "$out"
