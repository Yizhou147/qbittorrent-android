#!/bin/bash
# 准备本地 Docker 构建所需的源码目录 (从官方 GitHub release 下载并打补丁)
#
# 用法: ./scripts/prepare-sources.sh <qbittorrent版本> [libtorrent版本]
#   版本示例: 4.3.9 | 4.6.7 | 5.2.3
#
# 之后执行:
#   docker build -t qbittorrent-android \
#     --build-arg QT_KIND=qt5 --build-arg QT_VERSION=5.15.2 --build-arg CXX_STANDARD=17 .
set -euo pipefail

QBT_VER="${1:?用法: prepare-sources.sh <qbittorrent版本> [libtorrent版本]}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$QBT_VER" in
    4.3.9) LT_VER="${2:-v1.2.20}";;
    4.6.7) LT_VER="${2:-v2.0.10}";;
    5.2.3) LT_VER="${2:-v2.0.14}";;
    *) echo "未支持的版本: $QBT_VER (支持: 4.3.9 / 4.6.7 / 5.2.3)" >&2; exit 1;;
esac

cd "$ROOT"
mkdir -p docker-sources

echo "=== 下载 qBittorrent release-$QBT_VER ==="
curl -L --retry 3 -o docker-sources/qbittorrent.tar.gz \
    "https://github.com/qbittorrent/qBittorrent/archive/refs/tags/release-$QBT_VER.tar.gz"

echo "=== 克隆 libtorrent $LT_VER (需要 git 子模块) ==="
rm -rf docker-sources/libtorrent
git clone --depth 1 --branch "$LT_VER" --recursive --shallow-submodules \
    https://github.com/arvidn/libtorrent docker-sources/libtorrent

echo "=== 下载 OpenSSL 3.3.2 / Boost 1.86.0 ==="
curl -L --retry 3 -o docker-sources/openssl-3.3.2.tar.gz \
    "https://github.com/openssl/openssl/releases/download/openssl-3.3.2/openssl-3.3.2.tar.gz"
curl -L --retry 3 -o docker-sources/boost_1_86_0.tar.gz \
    "https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.gz"

echo "=== 解压并给 qBittorrent 打 Android 移植补丁 ==="
rm -rf docker-sources/qbittorrent
mkdir -p docker-sources/qbittorrent
tar xzf docker-sources/qbittorrent.tar.gz -C docker-sources/qbittorrent --strip-components=1
bash ci/apply-patches.sh "$QBT_VER" docker-sources/qbittorrent

# SDK/NDK zip 由 Dockerfile COPY，如缺失会报错；可从 dl.google.com 手动下载:
#   platform-34-ext7_r02.zip  build-tools_r34-linux.zip  android-ndk-r27b-linux.zip
for f in platform-34-ext7_r02.zip build-tools_r34-linux.zip android-ndk-r27b-linux.zip; do
    if [ ! -f "docker-sources/$f" ]; then
        echo "警告: docker-sources/$f 不存在, 请手动下载后放入 docker-sources/" >&2
    fi
done

echo "=== 源码准备完成, 构建命令示例 ==="
case "$QBT_VER" in
    5.2.3)
        echo "docker build -t qbittorrent-android \\"
        echo "  --build-arg QT_KIND=qt6 --build-arg QT_VERSION=6.6.3 \\"
        echo "  --build-arg CXX_STANDARD=20 --build-arg EXTRA_CMAKE_FLAGS=-DSTACKTRACE=OFF ."
        ;;
    *)
        echo "docker build -t qbittorrent-android \\"
        echo "  --build-arg QT_KIND=qt5 --build-arg QT_VERSION=5.15.2 \\"
        echo "  --build-arg CXX_STANDARD=17 ."
        ;;
esac
