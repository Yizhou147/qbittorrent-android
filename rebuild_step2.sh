#!/bin/bash
set -e

TOOLCHAIN=/opt/android-sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64
QT_INSTALL=/opt/qt5-custom

echo "=== Install Qt5 ==="
cd /build/qt5-build && make install 2>&1 | tail -5

echo "=== Verify JNI_OnLoad ==="
${TOOLCHAIN}/bin/llvm-nm -D ${QT_INSTALL}/lib/libQt5Core_arm64-v8a.so | grep JNI_OnLoad

echo "=== Rebuild qBittorrent ==="
cd /build/qbittorrent-src/build
ninja -j4 2>&1 | tail -15

echo "=== Collect ==="
QBT_LIB=$(find . -name "libqbt*.so" -not -path "*_autogen*" | head -1)
echo "Found qbt lib: $QBT_LIB"

cp ${QT_INSTALL}/lib/libQt5Core_arm64-v8a.so /output/
cp ${QT_INSTALL}/lib/libQt5Network_arm64-v8a.so /output/
cp ${QT_INSTALL}/lib/libQt5Xml_arm64-v8a.so /output/
cp ${QT_INSTALL}/lib/libQt5Sql_arm64-v8a.so /output/
cp "$QBT_LIB" /output/libqbt.so
${TOOLCHAIN}/bin/llvm-strip /output/*.so 2>/dev/null || true

echo "=== Output ==="
ls -lh /output/*.so
echo "=== DONE ==="
