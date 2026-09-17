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
                if mark_emulator_unsupported; then
                    echo "SKIP"
                    return 0
                fi
            fi
        } >&2
        sleep 3
    done
    echo "::error::请求 $url 连续 3 次无响应 (见上方是否有崩溃标记)"
    exit 1
}

# 模拟器翻译器缺陷判定: x86_64 模拟器靠 ndk_translation 翻译 arm64, 而它没实现
# fcvtzs (double->int) 这类基线指令。qb 处理含浮点的接口时必然 SIGILL —— 环境限制。
# 不同变体/不同网速下这个崩溃发生的时间不一样 (Qt5 变体更早: 它的 OpenSSL 静态编在
# libQt5Network 里, 构造期就算好了能力集, 我们来不及关), 所以检查要"能跑就跑,
# 撞上环境限制就跳过", 而不是直接失败或干脆不检查。
emulator_translator_killed() {
    adb shell logcat -d 2>/dev/null | grep -q "ndk_translation: Undefined instruction"
}

mark_emulator_unsupported() {
    if emulator_translator_killed; then
        echo "::warning::应用被模拟器翻译器缺陷杀掉 (ndk_translation 未实现某条指令) —— CI 环境限制, 非项目 bug"
        echo "           本步骤剩余检查跳过; 功能验证见真机脚本 ci/smoke-functional.sh"
        echo "QBT_EMULATOR_UNSUPPORTED=1" >> "${GITHUB_ENV:-/dev/null}"
        return 0
    fi
    return 1
}
