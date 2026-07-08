#!/bin/bash
set -e

QT_SRC="/build/qt-everywhere-src-5.15.2"
QT_BUILD="/build/qt5-build"
QT_INSTALL="/opt/qt5-custom"
NDK="/opt/android-sdk/ndk/27.0.12077973"

echo "=== 1. Patching qjni.cpp to handle NULL javaVM() ==="
JNI_FILE="${QT_SRC}/qtbase/src/corelib/kernel/qjni.cpp"

# Fix the destructor: add NULL check
sed -i 's/        QtAndroidPrivate::javaVM()->DetachCurrentThread();/        if (QtAndroidPrivate::javaVM()) QtAndroidPrivate::javaVM()->DetachCurrentThread();/' "$JNI_FILE"

# Fix the constructor: add NULL check for vm (use Python for multi-line)
python3 -c "
import re
with open('${JNI_FILE}', 'r') as f:
    c = f.read()
c = c.replace(
    'JavaVM *vm = QtAndroidPrivate::javaVM();\n    const jint ret = vm->GetEnv',
    'JavaVM *vm = QtAndroidPrivate::javaVM();\n    if (!vm) return;\n    const jint ret = vm->GetEnv'
)
with open('${JNI_FILE}', 'w') as f:
    f.write(c)
print('Constructor patched')
"

# Verify the patches
echo "--- Destructor (line 246):"
sed -n '246p' "$JNI_FILE"
echo "--- Constructor (lines 257-260):"
sed -n '257,260p' "$JNI_FILE"

echo "=== 2. Also patch qjnihelpers.cpp - add androidSdkVersion fallback ==="
HELPER_FILE="${QT_SRC}/qtbase/src/corelib/kernel/qjnihelpers.cpp"
# Make sure androidSdkVersion returns 0 when no VM
# (already returns g_androidSdkVersion which is initialized to 0, so this is fine)

echo "=== 3. Reconfigure and rebuild Qt5 (no OpenSSL) ==="
cd ${QT_BUILD}
rm -rf * 2>/dev/null || true

# Remove old mkspecs patches (from OpenSSL attempts)
cd ${QT_SRC}
git checkout qtbase/mkspecs/android-clang/qmake.conf 2>/dev/null || true
# Revert any OpenSSL mkspecs additions
sed -i '/# OpenSSL paths for cross-compilation/,$ d' qtbase/mkspecs/android-clang/qmake.conf 2>/dev/null || true

cd ${QT_BUILD}
../qt-everywhere-src-5.15.2/configure \
    -prefix ${QT_INSTALL} \
    -platform linux-clang \
    -xplatform android-clang \
    -android-ndk ${NDK} \
    -android-sdk /opt/android-sdk \
    -android-arch arm64-v8a \
    -android-ndk-host linux-x86_64 \
    -no-gui -no-widgets -no-dbus -no-accessibility \
    -no-opengl -no-vulkan -no-openssl \
    -no-libjpeg -no-libpng -no-harfbuzz -no-freetype \
    -no-glib -no-mtdev -no-evdev -no-tslib -no-icu -no-cups -no-pch \
    -nomake tests -nomake examples \
    -skip qt3d -skip qtactiveqt -skip qtandroidextras \
    -skip qtcharts -skip qtconnectivity -skip qtdatavis3d \
    -skip qtdeclarative -skip qtdoc -skip qtgamepad \
    -skip qtgraphicaleffects -skip qtimageformats -skip qtlocation \
    -skip qtlottie -skip qtmacextras -skip qtmultimedia \
    -skip qtnetworkauth -skip qtpurchasing -skip qtquick3d \
    -skip qtquickcontrols -skip qtquickcontrols2 -skip qtquicktimeline \
    -skip qtremoteobjects -skip qtscript -skip qtscxml \
    -skip qtsensors -skip qtserialbus -skip qtserialport \
    -skip qtspeech -skip qtsvg -skip qttools \
    -skip qttranslations -skip qtvirtualkeyboard -skip qtwayland \
    -skip qtwebchannel -skip qtwebengine -skip qtwebglplugin \
    -skip qtwebsockets -skip qtwebview -skip qtwinextras \
    -skip qtx11extras -skip qtxmlpatterns \
    -opensource -confirm-license \
    -c++std c++17 \
    -shared \
    2>&1 | tail -20

make -j$(nproc) 2>&1 | tail -20

echo "=== 4. Reinstall Qt5 ==="
make install 2>&1 | tail -10

echo "=== 5. Verify fix ==="
readelf -s ${QT_INSTALL}/lib/libQt5Core.so 2>/dev/null | grep -ci jni && echo "JNI symbols found (expected)" || echo "No JNI symbols"

echo "=== 6. Rebuild libtorrent with fixed Qt5 ==="
cd /build/libtorrent-src
rm -rf build && mkdir build && cd build
cmake .. \
    -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=${NDK}/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DANDROID_STL=c++_shared \
    -DCMAKE_INSTALL_PREFIX=/opt/qbt-output \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_FIND_ROOT_PATH="/opt/qbt-output" \
    -DBoost_INCLUDE_DIR=/opt/qbt-output/include \
    -DOPENSSL_ROOT_DIR=/opt/qbt-output \
    -Dstatic_runtime=ON \
    -Dencryption=ON \
    -Ddeprecated-functions=OFF \
    2>&1 | tail -5
ninja -j4 2>&1 | tail -5
ninja install 2>&1 | tail -5

echo "=== 7. Restore & patch qBittorrent source ==="
SRC="/build/qbittorrent-src"
cp /build/docker-sources/qbittorrent/cmake/Modules/CheckPackages.cmake ${SRC}/cmake/Modules/CheckPackages.cmake
cp /build/docker-sources/qbittorrent/src/app/CMakeLists.txt ${SRC}/src/app/CMakeLists.txt

# Remove LinguistTools
sed -i 's/Core Network Sql Xml LinguistTools/Core Network Sql Xml/g' \
    ${SRC}/cmake/Modules/CheckPackages.cmake

# Disable translations
APP_CMAKE="${SRC}/src/app/CMakeLists.txt"
WEBUI_LINE=$(grep -n "^if (WEBUI)" "$APP_CMAKE" | head -1 | cut -d: -f1)
ENDIF_LINE=$(tail -n +$WEBUI_LINE "$APP_CMAKE" | grep -n "^endif()" | head -1 | cut -d: -f1)
ENDIF_LINE=$((WEBUI_LINE + ENDIF_LINE - 1))
{ echo "# Translation disabled for Android"
  echo 'set(QBT_QM_FILES "")'
  echo 'set(QBT_WEBUI_QM_FILES "")'
  echo ""
  tail -n +$((ENDIF_LINE + 1)) "$APP_CMAKE"
} > /tmp/cmake_new.txt
mv /tmp/cmake_new.txt "$APP_CMAKE"

echo "=== 8. Rebuild qBittorrent ==="
cd ${SRC}
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
    -DCMAKE_TOOLCHAIN_FILE=${NDK}/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DANDROID_STL=c++_shared \
    -DCMAKE_INSTALL_PREFIX=/opt/qbt-output \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_FIND_ROOT_PATH="/opt/qbt-output;${QT_INSTALL}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DQt5_DIR=${QT_INSTALL}/lib/cmake/Qt5 \
    -DGUI=OFF \
    -DWEBUI=ON \
    -DTESTING=OFF \
    -DOPENSSL_ROOT_DIR=/opt/qbt-output \
    -DOPENSSL_INCLUDE_DIR=/opt/qbt-output/include \
    -DOPENSSL_CRYPTO_LIBRARY=/opt/qbt-output/lib/libcrypto.a \
    -DOPENSSL_SSL_LIBRARY=/opt/qbt-output/lib/libssl.a \
    -DLibtorrentRasterbar_DIR=/opt/qbt-output/lib/cmake/LibtorrentRasterbar \
    2>&1 | tail -10

ninja -j4 2>&1 | tail -20
ninja install 2>&1 | tail -5

echo "=== 9. Collect output ==="
rm -rf /output/*
mkdir -p /output/lib
TOOLCHAIN=${NDK}/toolchains/llvm/prebuilt/linux-x86_64
cp /opt/qbt-output/bin/qbittorrent-nox /output/
cp ${QT_INSTALL}/lib/libQt5Core.so /output/lib/libQt5Core_arm64-v8a.so
cp ${QT_INSTALL}/lib/libQt5Network.so /output/lib/libQt5Network_arm64-v8a.so
cp ${QT_INSTALL}/lib/libQt5Sql.so /output/lib/libQt5Sql_arm64-v8a.so
cp ${QT_INSTALL}/lib/libQt5Xml.so /output/lib/libQt5Xml_arm64-v8a.so
cp /opt/qbt-output/lib/libtorrent-rasterbar.so /output/lib/
cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/
cp ${QT_INSTALL}/plugins/sqldrivers/libqsqlite.so /output/lib/libplugins_sqldrivers_qsqlite_arm64-v8a.so 2>/dev/null || true
${TOOLCHAIN}/bin/llvm-strip /output/qbittorrent-nox /output/lib/*.so 2>/dev/null || true

echo "=== Output ==="
ls -lh /output/
ls -lh /output/lib/
echo "=== DONE ==="
