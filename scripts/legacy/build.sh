#!/bin/bash
#
# qBittorrent Android APK 一键构建脚本
# 需要: Docker
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
OUTPUT_DIR="$PROJECT_DIR/output"
APK_DIR="$PROJECT_DIR/apk-project"

echo "=========================================="
echo "  qBittorrent Android APK 构建"
echo "=========================================="

# 检查 Docker
if ! command -v docker &>/dev/null; then
    echo "❌ 需要安装 Docker"
    echo "   Ubuntu: sudo apt install docker.io"
    echo "   macOS: brew install --cask docker"
    exit 1
fi

# Step 1: 用 Docker 交叉编译 qBittorrent
echo ""
echo "📦 Step 1: Docker 交叉编译 qBittorrent (预计 30-60 分钟)..."
echo ""

docker build -t qbittorrent-android-builder "$PROJECT_DIR"

mkdir -p "$OUTPUT_DIR"
docker create --name qbt-temp qbittorrent-android-builder
docker cp qbt-temp:/output/qbittorrent-nox "$OUTPUT_DIR/"
docker rm qbt-temp

echo ""
echo "✅ qBittorrent 编译完成: $OUTPUT_DIR/qbittorrent-nox"
echo ""

# Step 2: 构建 APK
echo "📱 Step 2: 构建 Android APK..."
echo ""

# 复制 native binary 到 Android 项目
cp "$OUTPUT_DIR/qbittorrent-nox" "$APK_DIR/app/src/main/assets/qbittorrent-nox"

# 构建 APK (需要 Android SDK)
if command -v gradle &>/dev/null || [ -f "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
    cd "$APK_DIR"
    chmod +x gradlew
    ./gradlew assembleRelease
    echo ""
    echo "✅ APK 构建完成!"
    echo "📂 APK 位置: $APK_DIR/app/build/outputs/apk/release/"
else
    echo "⚠️  未检测到 Android SDK，跳过 APK 构建"
    echo "   请在 Android Studio 中打开 $APK_DIR 目录来构建 APK"
    echo ""
    echo "   或者手动安装 qBittorrent-nox:"
    echo "   adb push $OUTPUT_DIR/qbittorrent-nox /data/local/qbt/"
    echo "   adb shell chmod 755 /data/local/qbt/qbittorrent-nox"
    echo "   adb shell /data/local/qbt/qbittorrent-nox --webui-port=8080 --daemon"
fi

echo ""
echo "=========================================="
echo "  完成！"
echo "=========================================="
