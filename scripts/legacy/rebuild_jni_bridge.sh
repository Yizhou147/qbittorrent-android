#!/bin/bash
set -e

NDK=/opt/android-sdk/ndk/27.0.12077973
TOOLCHAIN=${NDK}/toolchains/llvm/prebuilt/linux-x86_64
PREFIX=/opt/qbt-output
QT_INSTALL=/opt/qt5-custom
export PATH=${TOOLCHAIN}/bin:$PATH
export CC=${TOOLCHAIN}/bin/aarch64-linux-android35-clang
export CXX=${TOOLCHAIN}/bin/aarch64-linux-android35-clang++

echo "=== Rebuild qBittorrent as shared library with JNI bridge ==="
SRC=/build/qbittorrent-src

# Verify JNI bridge file exists
ls -la ${SRC}/src/app/android_jni_bridge.cpp

cd ${SRC} && rm -rf build && mkdir build && cd build
mkdir -p src/lang src/webui/www/translations
cat > src/lang/lang.qrc << 'QRCEOF'
<RCC><qresource prefix="/lang"></qresource></RCC>
QRCEOF
cat > src/webui/www/translations/webui_translations.qrc << 'QRCEOF'
<RCC><qresource prefix="/translations"></qresource></RCC>
QRCEOF

cmake .. -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=${NDK}/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-35 -DANDROID_STL=c++_shared \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_FIND_ROOT_PATH="${PREFIX};${QT_INSTALL}" -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DQt5_DIR=${QT_INSTALL}/lib/cmake/Qt5 \
    -DGUI=OFF -DWEBUI=ON -DTESTING=OFF \
    -DOPENSSL_ROOT_DIR=${PREFIX} -DOPENSSL_INCLUDE_DIR=${PREFIX}/include \
    -DOPENSSL_CRYPTO_LIBRARY=${PREFIX}/lib/libcrypto.so -DOPENSSL_SSL_LIBRARY=${PREFIX}/lib/libssl.so \
    -DLibtorrentRasterbar_DIR=${PREFIX}/lib/cmake/LibtorrentRasterbar \
    2>&1 | tail -20

echo "=== Building ==="
ninja -j4 2>&1 | tail -30

echo "=== Check output ==="
find . -name "libqbt.so" -o -name "qbt_app*" | head -10
ls -la src/app/ | grep -E "libqbt|qbt"

echo "=== Collect output ==="
# Find the built shared library
QBT_LIB=$(find . -name "libqbt.so" | head -1)
if [ -z "$QBT_LIB" ]; then
    echo "ERROR: libqbt.so not found! Looking for any qbt artifacts..."
    find . -name "*qbt*" -type f
    exit 1
fi

cp "$QBT_LIB" /output/
${TOOLCHAIN}/bin/llvm-strip /output/libqbt.so 2>/dev/null || true

echo "=== Verify JNI symbol ==="
${TOOLCHAIN}/bin/llvm-nm -D /output/libqbt.so | grep nativeMain || echo "WARNING: nativeMain symbol not found!"
${TOOLCHAIN}/bin/llvm-readelf -sW /output/libqbt.so | grep nativeMain || echo "WARNING: nativeMain not in readelf!"

echo "=== Output ==="
ls -lh /output/libqbt.so
echo "=== DONE ==="
