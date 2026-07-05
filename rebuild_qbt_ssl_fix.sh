#!/bin/bash
set -e

echo "=== Rebuilding libqbt ==="
cd /build/qbittorrent-src/build
ninja qbt_app 2>&1 | tail -5

echo "=== Collecting output ==="
QBT_LIB=$(find . -name "libqbt*.so" -not -path "*_autogen*" | head -1)
cp "$QBT_LIB" /output/libqbt.so
/opt/android-sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip /output/libqbt.so
ls -lh /output/libqbt.so
echo "Done!"
