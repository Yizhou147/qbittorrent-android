#!/bin/bash
# 真机功能测试: 种子的 添加/查询/暂停/恢复/删除 + 离线 web seed 真实下载(校验 SHA1)。
#
# 为什么不在 CI 模拟器上跑:
#   x86_64 模拟器靠 ndk_translation 翻译 arm64 代码, 而该翻译器没有实现 fcvtzs
#   (double->int) 这类基线指令 —— qb 一算 BT 状态就 SIGILL; 而且带 ARM 翻译的镜像
#   只到 API 30 (API 33 直接 INSTALL_FAILED_NO_MATCHING_ABIS)。所以 BT 相关功能
#   在模拟器上没法验证, 改用这个脚本在真机上跑。
#
# 用法:
#   ci/smoke-functional.sh <应用包名> [WebUI端口]
# 例:
#   ci/smoke-functional.sh com.qbittorrent.android.qb523 8080
#
# 前置: 设备已连接(adb devices 可见), 应用已安装且 WebUI 已就绪。
# 说明: web seed 用 http://127.0.0.1:<端口> —— 通过 adb reverse 让设备访问到本机的
#       临时 http 服务, 全程离线, 不需要外网也不需要 peer。
set -uo pipefail

PKG="${1:?用法: $0 <应用包名> [WebUI端口]}"
PORT="${2:-8080}"
FWD=18080
WEBSEED_PORT="${WEBSEED_PORT:-8899}"
BASE="http://localhost:${FWD}"
HOSTH=(-H "Host: localhost:${PORT}" -H "Referer: http://localhost:${PORT}")

cd "$(dirname "$0")/.." || exit 1
export PKG

FAILED=0
fail() { echo "  [失败] $*"; FAILED=1; }
ok() { echo "  [通过] $*"; }

# fetch() 来自冒烟用的公共库 (失败重试 + 进程存活判断)
. ci/smoke-lib.sh

echo "=== 准备: adb forward + 等 WebUI ==="
adb forward "tcp:${FWD}" "tcp:${PORT}" > /dev/null || { echo "adb forward 失败"; exit 1; }
V=""
for _ in $(seq 1 24); do
    V=$(curl -s --max-time 5 -H "Host: localhost:${PORT}" "${BASE}/api/v2/app/version" 2>/dev/null || true)
    [ -n "$V" ] && break
    sleep 5
done
[ -n "$V" ] || { echo "WebUI 没就绪, 请先启动应用"; exit 1; }
echo "  应用版本: $V"
PID0=$(adb shell pidof -s "$PKG" | tr -d '\r')
echo "  pid=$PID0"

check_alive() {
    local pid_now
    pid_now=$(adb shell pidof -s "$PKG" | tr -d '\r')
    if [ "$pid_now" != "$PID0" ]; then
        fail "进程被重启 ($PID0 -> $pid_now)"
        adb shell logcat -d 2>/dev/null | grep -E "Fatal signal|JNI DETECTED|Abort message" | tail -5
        return 1
    fi
    return 0
}

echo
echo "=== 1) 种子往返: 添加 -> 查询 -> 暂停 -> 恢复 -> 删除 ==="
HASH=$(python3 ci/make-test-torrent.py /tmp/smoke-rt.torrent) || exit 1
echo "  测试种子 info-hash=$HASH"
CODE=$(curl -s -o /tmp/rt-add.out -w '%{http_code}' --max-time 30 "${HOSTH[@]}" \
    -F "torrents=@/tmp/smoke-rt.torrent;type=application/x-bittorrent" \
    "${BASE}/api/v2/torrents/add")
echo "  添加: HTTP $CODE -> $(head -c 120 /tmp/rt-add.out)"
[ "$CODE" = "200" ] && ok "添加种子" || fail "添加种子 HTTP $CODE"
check_alive || exit 1

INFO=""
FOUND=0
for i in $(seq 1 10); do
    INFO=$(curl -s --max-time 15 "${HOSTH[@]}" "${BASE}/api/v2/torrents/info" || true)
    if echo "$INFO" | jq -e --arg h "$HASH" 'map(select(.hash == $h)) | length > 0' > /dev/null 2>&1; then
        FOUND=1; break
    fi
    sleep 3
done
if [ "$FOUND" = "1" ]; then
    ok "种子出现在 /torrents/info"
    echo "$INFO" | jq -r --arg h "$HASH" '.[] | select(.hash==$h) | "    name=\(.name) state=\(.state) save_path=\(.save_path)"'
    SAVE=$(echo "$INFO" | jq -r --arg h "$HASH" '.[] | select(.hash==$h) | .save_path')
    case "$SAVE" in
        *Download*) ok "save_path 生效: $SAVE" ;;
        *) fail "save_path 不是 Java 设置的下载目录: $SAVE" ;;
    esac
else
    fail "种子没出现在 /torrents/info"
    echo "$INFO" | head -c 300
fi

curl -s --max-time 15 "${HOSTH[@]}" -d "hashes=$HASH" "${BASE}/api/v2/torrents/pause" > /dev/null
sleep 2
STATE=$(curl -s --max-time 15 "${HOSTH[@]}" "${BASE}/api/v2/torrents/info" \
    | jq -r --arg h "$HASH" '.[] | select(.hash==$h) | .state' 2>/dev/null)
case "$STATE" in
    paused*) ok "暂停生效 (state=$STATE)" ;;
    *) fail "暂停没生效 (state=$STATE)" ;;
esac
curl -s --max-time 15 "${HOSTH[@]}" -d "hashes=$HASH" "${BASE}/api/v2/torrents/resume" > /dev/null
sleep 2
STATE=$(curl -s --max-time 15 "${HOSTH[@]}" "${BASE}/api/v2/torrents/info" \
    | jq -r --arg h "$HASH" '.[] | select(.hash==$h) | .state' 2>/dev/null)
case "$STATE" in
    paused*) fail "恢复没生效 (state 仍为 $STATE)" ;;
    *) ok "恢复生效 (state=$STATE)" ;;
esac

curl -s --max-time 15 "${HOSTH[@]}" -d "hashes=$HASH&deleteFiles=false" \
    "${BASE}/api/v2/torrents/delete" > /dev/null
sleep 2
LEFT=$(curl -s --max-time 15 "${HOSTH[@]}" "${BASE}/api/v2/torrents/info" \
    | jq -r --arg h "$HASH" 'map(select(.hash==$h)) | length' 2>/dev/null)
[ "$LEFT" = "0" ] && ok "删除生效" || fail "删除后种子仍在 (count=$LEFT)"
check_alive || exit 1

echo
echo "=== 2) 离线 web seed 真实下载 (校验文件内容) ==="
SRV_DIR=/tmp/qbt-webseed
rm -rf "$SRV_DIR"; mkdir -p "$SRV_DIR"
DHASH=$(python3 ci/make-test-torrent.py "$SRV_DIR/payload.torrent" 262144 \
    "http://127.0.0.1:${WEBSEED_PORT}/payload.bin") || exit 1
mv "$SRV_DIR/payload.torrent.content" "$SRV_DIR/payload.bin"
SRC_SHA=$(sha1sum "$SRV_DIR/payload.bin" | awk '{print $1}')
echo "  info-hash=$DHASH 源文件 sha1=$SRC_SHA"
(cd "$SRV_DIR" && nohup python3 -m http.server "$WEBSEED_PORT" --bind 127.0.0.1 \
    > /tmp/qbt-webseed.log 2>&1 &)
adb reverse "tcp:${WEBSEED_PORT}" "tcp:${WEBSEED_PORT}" > /dev/null 2>&1
sleep 2
curl -sf -o /dev/null "http://127.0.0.1:${WEBSEED_PORT}/payload.bin" \
    || { fail "本机 http 服务没起来"; FAILED=1; }

CODE=$(curl -s -o /tmp/dl-add.out -w '%{http_code}' --max-time 30 "${HOSTH[@]}" \
    -F "torrents=@${SRV_DIR}/payload.torrent;type=application/x-bittorrent" \
    "${BASE}/api/v2/torrents/add")
echo "  添加: HTTP $CODE -> $(head -c 120 /tmp/dl-add.out)"
[ "$CODE" = "200" ] && ok "添加下载任务" || fail "添加下载任务 HTTP $CODE"

DONE=0
for i in $(seq 1 48); do
    INFO=$(curl -s --max-time 15 "${HOSTH[@]}" "${BASE}/api/v2/torrents/info" || true)
    P=$(echo "$INFO" | jq -r --arg h "$DHASH" '.[] | select(.hash==$h) | .progress' 2>/dev/null | head -1)
    ST=$(echo "$INFO" | jq -r --arg h "$DHASH" '.[] | select(.hash==$h) | .state' 2>/dev/null | head -1)
    SAVE=$(echo "$INFO" | jq -r --arg h "$DHASH" '.[] | select(.hash==$h) | .save_path' 2>/dev/null | head -1)
    echo "    第 $i 次: state=$ST progress=$P"
    [ "$P" = "1" ] && { DONE=1; break; }
    sleep 5
done
if [ "$DONE" = "1" ]; then
    ok "下载完成 (state=$ST)"
    REMOTE_FILE="${SAVE}/qbittorrent-android-smoke.bin"
    DEV_SHA=$(adb exec-out "cat '${REMOTE_FILE}'" 2>/dev/null | sha1sum | awk '{print $1}')
    if [ "$DEV_SHA" = "$SRC_SHA" ]; then
        ok "文件内容一致 (sha1=$DEV_SHA)"
    else
        fail "文件内容不一致 (设备 $DEV_SHA vs 源 $SRC_SHA)"
    fi
else
    fail "4 分钟内没下载完成 (state=$ST progress=$P)"
    tail -20 /tmp/qbt-webseed.log 2>/dev/null
    adb shell logcat -d 2>/dev/null | grep -iE "web.?seed|url.?list|error" | tail -10
fi
curl -s --max-time 15 "${HOSTH[@]}" -d "hashes=$DHASH&deleteFiles=true" \
    "${BASE}/api/v2/torrents/delete" > /dev/null
pkill -f "http.server ${WEBSEED_PORT}" 2>/dev/null
adb reverse --remove "tcp:${WEBSEED_PORT}" > /dev/null 2>&1
check_alive || exit 1

echo
if [ "$FAILED" = "0" ]; then
    echo "全部通过: 种子往返 + 离线真实下载"
else
    echo "有失败项, 见上面 [失败]"
fi
exit "$FAILED"
