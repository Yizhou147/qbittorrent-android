#!/bin/bash
# emulator-smoke 用的公共函数 (由 test.yml 里各步骤 source)
#
# fetch: 带重试与"进程是否还活着"判断的 HTTP 请求。
# 模拟器上偶发的网络抖动会让 curl 拿不到响应 (exit 52/56), 那样直接 fail 会很迷惑;
# 这里先看进程还在不在: 在就重试, 不在就把最近的致命日志打到 job 日志里。
# 用法: CODE=$(fetch <url> <输出文件> [curl 参数...])
fetch() {
    local url="$1" out="$2"; shift 2
    local code i
    for i in 1 2 3; do
        code=$(curl -s -o "$out" -w '%{http_code}' --max-time 20 "$@" "$url" 2>/dev/null || true)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            echo "$code"
            return 0
        fi
        {
            echo "  [fetch] 第 $i 次请求无响应: $url"
            if adb shell pidof -s "$PKG" > /dev/null 2>&1; then
                echo "  [fetch] 进程还在, 3 秒后重试 (可能是模拟器网络抖动)"
            else
                echo "  [fetch] 应用进程已不在 —— 请求 $url 时崩溃, 最近日志:"
                adb shell logcat -d 2>/dev/null \
                    | grep -E "JNI DETECTED|Fatal signal|SIGABRT|Abort message|FATAL EXCEPTION" | tail -20
            fi
        } >&2
        sleep 3
    done
    echo "::error::请求 $url 连续 3 次无响应 (见上方是否有崩溃标记)"
    exit 1
}
