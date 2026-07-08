#!/bin/bash
set -e

NDK=/opt/android-sdk/ndk/27.0.12077973
TOOLCHAIN=${NDK}/toolchains/llvm/prebuilt/linux-x86_64
PREFIX=/opt/qbt-output
QT_INSTALL=/opt/qt5-custom
OPENSSL_PREFIX=/opt/openssl-arm64
QBT_SRC=/build/qbittorrent-src

echo "=== Rebuild libtorrent with static OpenSSL ==="
cd /build/libtorrent-src
rm -rf build && mkdir build && cd build
cmake .. -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=${NDK}/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-35 -DANDROID_STL=c++_shared \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_FIND_ROOT_PATH="${PREFIX}" \
    -DBoost_INCLUDE_DIR=${PREFIX}/include \
    -DOPENSSL_ROOT_DIR=${OPENSSL_PREFIX} \
    -DOPENSSL_INCLUDE_DIR=${OPENSSL_PREFIX}/include \
    -DOPENSSL_CRYPTO_LIBRARY=${OPENSSL_PREFIX}/lib/libcrypto.a \
    -DOPENSSL_SSL_LIBRARY=${OPENSSL_PREFIX}/lib/libssl.a \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -Dstatic_runtime=ON -Dencryption=ON -Ddeprecated-functions=OFF \
    2>&1 | tail -15
ninja -j$(nproc) 2>&1 | tail -10
ninja install 2>&1 | tail -5
echo "libtorrent rebuilt with static OpenSSL"

echo "=== Verify cmake config uses static OpenSSL ==="
grep -i 'openssl\|libssl\|libcrypto' /opt/qbt-output/lib/cmake/LibtorrentRasterbar/LibtorrentRasterbarTargets.cmake 2>/dev/null || echo "no openssl in targets"

echo "=== Rebuild qBittorrent ==="
# Re-copy patched files
cp /build/docker-sources/qbittorrent/src/app/CMakeLists.txt ${QBT_SRC}/src/app/CMakeLists.txt
cp /build/docker-sources/qbittorrent/src/app/android_jni_bridge.cpp ${QBT_SRC}/src/app/android_jni_bridge.cpp
cp /build/docker-sources/qbittorrent/cmake/Modules/CheckPackages.cmake ${QBT_SRC}/cmake/Modules/CheckPackages.cmake
sed -i 's/Core Network Sql Xml LinguistTools/Core Network Sql Xml/g' ${QBT_SRC}/cmake/Modules/CheckPackages.cmake

cd ${QBT_SRC} && rm -rf build && mkdir build && cd build
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
    -DOPENSSL_ROOT_DIR=${OPENSSL_PREFIX} \
    -DOPENSSL_INCLUDE_DIR=${OPENSSL_PREFIX}/include \
    -DOPENSSL_CRYPTO_LIBRARY=${OPENSSL_PREFIX}/lib/libcrypto.a \
    -DOPENSSL_SSL_LIBRARY=${OPENSSL_PREFIX}/lib/libssl.a \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DLibtorrentRasterbar_DIR=${PREFIX}/lib/cmake/LibtorrentRasterbar \
    2>&1 | tail -15

ninja -j$(nproc) 2>&1 | tail -20
echo "=== qBittorrent built ==="

echo "=== Collect output ==="
rm -rf /output/* && mkdir -p /output/lib
cp ${QT_INSTALL}/lib/libQt5Core_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Network_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Sql_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Xml_arm64-v8a.so /output/lib/
cp ${PREFIX}/lib/libtorrent-rasterbar.so /output/lib/
cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/
${TOOLCHAIN}/bin/llvm-strip /output/lib/*.so 2>/dev/null || true

QBT_LIB=$(find ${QBT_SRC}/build -name "libqbt*.so" -not -path "*_autogen*" | head -1)
if [ -n "$QBT_LIB" ]; then
    cp "$QBT_LIB" /output/libqbt.so
    ${TOOLCHAIN}/bin/llvm-strip /output/libqbt.so
    echo "qbt_app built: $QBT_LIB"
else
    echo "ERROR: libqbt.so not found!"
fi

echo ""
echo "=== Verify: no libssl/libcrypto in NEEDED ==="
echo "libqbt.so:"
readelf -d /output/libqbt.so 2>/dev/null | grep -i 'NEEDED\|ssl\|crypto' | head -15
echo ""
echo "libQt5Network:"
readelf -d /output/lib/libQt5Network_arm64-v8a.so 2>/dev/null | grep NEEDED
echo ""
echo "=== Final Output ==="
ls -lh /output/libqbt.so /output/lib/
echo "=== DONE ==="
