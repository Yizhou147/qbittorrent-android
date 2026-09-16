#!/bin/bash
set -e

NDK=/opt/android-sdk/ndk/27.0.12077973
TOOLCHAIN=${NDK}/toolchains/llvm/prebuilt/linux-x86_64
PREFIX=/opt/qbt-output
QT_INSTALL=/opt/qt5-custom
export PATH=${TOOLCHAIN}/bin:$PATH
export CC=${TOOLCHAIN}/bin/aarch64-linux-android35-clang
export CXX=${TOOLCHAIN}/bin/aarch64-linux-android35-clang++

echo "=== 1. Rebuild libtorrent (target=35) ==="
cd /build/libtorrent-src
rm -rf build && mkdir build && cd build
cmake .. -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=${NDK}/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-35 -DANDROID_STL=c++_shared \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_FIND_ROOT_PATH="${PREFIX}" -DBoost_INCLUDE_DIR=${PREFIX}/include \
    -DOPENSSL_ROOT_DIR=${PREFIX} -DOPENSSL_CRYPTO_LIBRARY=${PREFIX}/lib/libcrypto.so -DOPENSSL_SSL_LIBRARY=${PREFIX}/lib/libssl.so \
    -Dstatic_runtime=ON -Dencryption=ON -Ddeprecated-functions=OFF \
    2>&1 | tail -5
ninja -j4 2>&1 | tail -5
ninja install 2>&1 | tail -5
echo "libtorrent built with target=35"

echo "=== 2. Rebuild qBittorrent (target=35) ==="
SRC=/build/qbittorrent-src
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
    2>&1 | tail -10

ninja -j4 2>&1 | tail -20
ninja install 2>&1 | tail -5

echo "=== 3. Collect output ==="
rm -rf /output/* && mkdir -p /output/lib
cp ${PREFIX}/bin/qbittorrent-nox /output/
cp ${QT_INSTALL}/lib/libQt5Core_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Network_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Sql_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Xml_arm64-v8a.so /output/lib/
cp ${PREFIX}/lib/libtorrent-rasterbar.so /output/lib/
cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/
cp ${QT_INSTALL}/plugins/sqldrivers/libplugins_sqldrivers_qsqlite_arm64-v8a.so /output/lib/ 2>/dev/null || \
    cp ${QT_INSTALL}/plugins/sqldrivers/libqsqlite.so /output/lib/libplugins_sqldrivers_qsqlite_arm64-v8a.so 2>/dev/null || true
cp ${PREFIX}/lib/libssl.so /output/lib/
cp ${PREFIX}/lib/libcrypto.so /output/lib/
${TOOLCHAIN}/bin/llvm-strip /output/qbittorrent-nox /output/lib/*.so 2>/dev/null || true
echo "=== Output ==="
ls -lh /output/ /output/lib/

echo "=== 4. Verify TLS alignment ==="
${TOOLCHAIN}/bin/llvm-readelf -l /output/qbittorrent-nox | grep -i tls
echo "=== DONE ==="
