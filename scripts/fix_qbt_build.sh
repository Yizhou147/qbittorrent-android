#!/bin/bash
set -e

echo "===== Patching qBittorrent to remove LinguistTools dependency ====="

APP_CMAKE="/build/qbittorrent-src/src/app/CMakeLists.txt"

# Approach: Replace the translation-related CMake code with simple empty variables
# Write a new version of the translation section

# First, let's see what we have
echo "--- Original translation section ---"
head -35 "$APP_CMAKE"

# Create empty qrc files for translations
mkdir -p /build/qbittorrent-src/build/src/lang
mkdir -p /build/qbittorrent-src/build/src/webui/www/translations

cat > /build/qbittorrent-src/build/src/lang/lang.qrc << 'QRCEOF'
<RCC>
    <qresource prefix="/lang">
    </qresource>
</RCC>
QRCEOF

cat > /build/qbittorrent-src/build/src/webui/www/translations/webui_translations.qrc << 'QRCEOF'
<RCC>
    <qresource prefix="/translations">
    </qresource>
</RCC>
QRCEOF

# Now replace the CMakeLists.txt translation section
# Replace everything from line 1 to the line before "if (WEBUI)" (or before add_executable)
cat > /tmp/new_head.txt << 'CMEOF'
# Translation disabled for Android build
set(QBT_QM_FILES "")
set(QBT_WEBUI_QM_FILES "")
CMEOF

# Find the line number of "if (WEBUI)" in the file
WEBUI_LINE=$(grep -n "^if (WEBUI)" "$APP_CMAKE" | head -1 | cut -d: -f1)
echo "WEBUI block starts at line $WEBUI_LINE"

# Find the endif() that closes the WEBUI block
ENDIF_LINE=$(tail -n +$WEBUI_LINE "$APP_CMAKE" | grep -n "^endif()" | head -1 | cut -d: -f1)
ENDIF_LINE=$((WEBUI_LINE + ENDIF_LINE - 1))
echo "WEBUI block ends at line $ENDIF_LINE"

# Replace lines 1 to ENDIF_LINE with our simple version
{ cat /tmp/new_head.txt; tail -n +$((ENDIF_LINE + 1)) "$APP_CMAKE"; } > /tmp/cmake_new.txt
mv /tmp/cmake_new.txt "$APP_CMAKE"

echo "--- Patched translation section ---"
head -20 "$APP_CMAKE"

echo "===== Patched. Now configuring qBittorrent ====="

export ANDROID_NDK=/opt/android-sdk/ndk/27.0.12077973
export PREFIX=/opt/qbt-output
export QT5=/opt/qt5-custom
export TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64

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
cmake --build . -j4 2>&1 | tail -50

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
