#!/bin/bash
set -e

export ANDROID_NDK=/opt/android-sdk/ndk/27.0.12077973
export PREFIX=/opt/qbt-output
export QT5=/opt/qt5-custom
export TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64

echo "===== Configuring qBittorrent ====="
cd /build/qbittorrent-src
rm -rf build && mkdir build && cd build

# Create empty qrc files in build dir
mkdir -p src/lang src/webui/www/translations
cat > src/lang/lang.qrc << 'QRCEOF'
<RCC>
    <qresource prefix="/lang">
    </qresource>
</RCC>
QRCEOF
cat > src/webui/www/translations/webui_translations.qrc << 'QRCEOF'
<RCC>
    <qresource prefix="/translations">
    </qresource>
</RCC>
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
cp ${QT5}/lib/libQt5*.so /output/lib/
cp ${PREFIX}/lib/libtorrent-rasterbar.so /output/lib/
cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/
cp ${QT5}/plugins/sqldrivers/libplugins_sqldrivers_qsqlite_arm64-v8a.so /output/lib/ 2>/dev/null || true
${TOOLCHAIN}/bin/llvm-strip /output/qbittorrent-nox /output/lib/*.so 2>/dev/null || true

echo "===== Output ====="
ls -lh /output/
ls -lh /output/lib/
echo "===== JNI check ====="
readelf -s /output/lib/libQt5Core_arm64-v8a.so 2>/dev/null | grep -ci jni || echo "0 JNI symbols"
echo "DONE"
