#!/bin/bash
set -e

export ANDROID_NDK=/opt/android-sdk/ndk/27.0.12077973
export PREFIX=/opt/qbt-output
export QT5=/opt/qt5-prebuilt/5.15.2/android
export TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64

echo "===== Using pre-built Qt5 at: ${QT5} ====="
echo "===== Qt5 Network check ====="
readelf -s ${QT5}/lib/libQt5Network_arm64-v8a.so 2>/dev/null | grep -c QSslSocket && echo "SSL symbols found" || echo "No SSL symbols"

echo "===== Restoring qBittorrent source ====="
cd /build/qbittorrent-src
cp /build/docker-sources/qbittorrent/cmake/Modules/CheckPackages.cmake cmake/Modules/CheckPackages.cmake
cp /build/docker-sources/qbittorrent/src/app/CMakeLists.txt src/app/CMakeLists.txt

echo "===== Patching qBittorrent ====="
# 1. Remove LinguistTools from CheckPackages.cmake
sed -i 's/Core Network Sql Xml LinguistTools/Core Network Sql Xml/g' cmake/Modules/CheckPackages.cmake

# 2. Replace translation section in src/app/CMakeLists.txt
APP_CMAKE="src/app/CMakeLists.txt"

# Find the WEBUI block boundaries
WEBUI_LINE=$(grep -n "^if (WEBUI)" "$APP_CMAKE" | head -1 | cut -d: -f1)
ENDIF_LINE=$(tail -n +$WEBUI_LINE "$APP_CMAKE" | grep -n "^endif()" | head -1 | cut -d: -f1)
ENDIF_LINE=$((WEBUI_LINE + ENDIF_LINE - 1))

# Replace translation section with empty vars
{ echo "# Translation disabled for Android build"
  echo 'set(QBT_QM_FILES "")'
  echo 'set(QBT_WEBUI_QM_FILES "")'
  echo ""
  tail -n +$((ENDIF_LINE + 1)) "$APP_CMAKE"
} > /tmp/cmake_new.txt
mv /tmp/cmake_new.txt "$APP_CMAKE"

echo "===== Patched. Configuring qBittorrent ====="

rm -rf build && mkdir build && cd build

# Create empty qrc files
mkdir -p src/lang src/webui/www/translations
cat > src/lang/lang.qrc << 'QRCEOF'
<RCC><qresource prefix="/lang"></qresource></RCC>
QRCEOF
cat > src/webui/www/translations/webui_translations.qrc << 'QRCEOF'
<RCC><qresource prefix="/translations"></qresource></RCC>
QRCEOF

cmake .. \
    -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK}/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DANDROID_STL=c++_shared \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_FIND_ROOT_PATH="${PREFIX};${QT5}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DQt5_DIR=${QT5}/lib/cmake/Qt5 \
    -DGUI=OFF \
    -DWEBUI=ON \
    -DTESTING=OFF \
    -DOPENSSL_ROOT_DIR=${PREFIX} \
    -DOPENSSL_INCLUDE_DIR=${PREFIX}/include \
    -DOPENSSL_CRYPTO_LIBRARY=${PREFIX}/lib/libcrypto.a \
    -DOPENSSL_SSL_LIBRARY=${PREFIX}/lib/libssl.a \
    -DLibtorrentRasterbar_DIR=${PREFIX}/lib/cmake/LibtorrentRasterbar \
    2>&1

echo "===== configure done, building ====="
cmake --build . -j4 2>&1 | tail -80

echo "===== installing ====="
cmake --install . 2>&1

echo "===== collecting output ====="
rm -rf /output/*
mkdir -p /output/lib
cp ${PREFIX}/bin/qbittorrent-nox /output/
# Only copy the Qt5 libs we need (arm64 only)
for lib in Core Network Sql Xml; do
    cp ${QT5}/lib/libQt5${lib}_arm64-v8a.so /output/lib/
done
# Copy Qt5Gui (needed by Qt5Network for SSL)
cp ${QT5}/lib/libQt5Gui_arm64-v8a.so /output/lib/ 2>/dev/null || true
cp ${PREFIX}/lib/libtorrent-rasterbar.so /output/lib/
cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/
# Copy SQLite plugin
cp ${QT5}/plugins/sqldrivers/libplugins_sqldrivers_qsqlite_arm64-v8a.so /output/lib/ 2>/dev/null || true
# Copy bearer plugin (network)
cp ${QT5}/plugins/bearer/libplugins_bearer_qandroidbearer_arm64-v8a.so /output/lib/ 2>/dev/null || true
# Copy platform plugin (qtforandroid - needed for Android-specific init)
cp ${QT5}/plugins/platforms/libplugins_platforms_qtforandroid_arm64-v8a.so /output/lib/ 2>/dev/null || true
${TOOLCHAIN}/bin/llvm-strip /output/qbittorrent-nox /output/lib/*.so 2>/dev/null || true

echo "===== Output ====="
ls -lh /output/
ls -lh /output/lib/
echo "DONE"
