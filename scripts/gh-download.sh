#!/bin/bash
# GitHub 下载助手（镜像优先，直连兜底）
#
# 用法: ./scripts/gh-download.sh <url> <输出文件>
#   url 形如 https://github.com/<owner>/<repo>/releases/download/... 或
#          https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.tar.gz
#
# 镜像顺序可被 GH_MIRRORS 环境变量覆盖（逗号分隔）。
set -euo pipefail

URL="${1:?用法: gh-download.sh <github-url> <output>}"
OUT="${2:?用法: gh-download.sh <github-url> <output>}"

# ghfast.top 实测最快; gh-proxy.com/ghproxy.net 为备用
MIRRORS="${GH_MIRRORS:-https://ghfast.top,https://gh-proxy.com,https://ghproxy.net}"

try_fetch() {
    local url="$1"
    echo "  -> $url"
    if curl -fL --retry 2 --connect-timeout 20 --max-time 900 -o "$OUT" "$url"; then
        local size
        size=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
        if [ "$size" -gt 10000 ]; then
            echo "OK: $OUT ($size bytes)"
            return 0
        fi
        echo "  文件过小 ($size bytes), 视为失败"
    fi
    rm -f "$OUT"
    return 1
}

# 1) 镜像优先
IFS=',' read -ra MIRROR_LIST <<< "$MIRRORS"
for m in "${MIRROR_LIST[@]}"; do
    echo "[镜像] ${m}"
    try_fetch "${m}/${URL}" && exit 0
done

# 2) 直连兜底（沙箱内可能走代理）
echo "[直连] $URL"
try_fetch "$URL" && exit 0

echo "ERROR: 所有通道均失败: $URL" >&2
exit 1
