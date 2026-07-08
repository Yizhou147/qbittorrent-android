#!/bin/bash
set -e

NDK=/opt/android-sdk/ndk/27.0.12077973
TOOLCHAIN=${NDK}/toolchains/llvm/prebuilt/linux-x86_64
PREFIX=/opt/qbt-output
QT_INSTALL=/opt/qt5-custom
export PATH=${TOOLCHAIN}/bin:$PATH

echo "=== 1. Rebuild Qt5 (incremental) ==="
cd /build/qt5-build
ninja -j4 2>&1 | tail -20
echo "=== Qt5 install ==="
ninja install 2>&1 | tail -10
echo "=== Verify JNI_OnLoad in libQt5Core ==="
${TOOLCHAIN}/bin/llvm-nm -D ${QT_INSTALL}/lib/libQt5Core_arm64-v8a.so | grep JNI_OnLoad

echo "=== 2. Rebuild qBittorrent (incremental) ==="
cd /build/qbittorrent-src/build
ninja -j4 2>&1 | tail -20

echo "=== 3. Collect outputs ==="
QBT_LIB=$(find . -name "libqbt*.so" | grep -v _autogen | head -1)
if [ -z "$QBT_LIB" ]; then
    echo "ERROR: libqbt.so not found"
    exit 1
fi
echo "Found: $QBT_LIB"
cp ${QT_INSTALL}/lib/libQt5Core_arm64-v8a.so /output/
cp ${QT_INSTALL}/lib/libQt5Network_arm64-v8a.so /output/
cp ${QT_INSTALL}/lib/libQt5Xml_arm64-v8a.so /output/
cp ${QT_INSTALL}/lib/libQt5Sql_arm64-v8a.so /output/
cp "$QBT_LIB" /output/libqbt.so
${TOOLCHAIN}/bin/llvm-strip /output/*.so 2>/dev/null || true
echo "=== Output ==="
ls -lh /output/*.so
echo "=== DONE ==="
