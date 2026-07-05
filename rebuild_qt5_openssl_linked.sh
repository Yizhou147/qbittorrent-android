#!/bin/bash
set -e

# ============================================================
# Rebuild Qt5 with -openssl-linked (static OpenSSL)
# Target: aarch64-linux-android35
# ============================================================

NDK=/opt/android-sdk/ndk/27.0.12077973
TOOLCHAIN=${NDK}/toolchains/llvm/prebuilt/linux-x86_64
PREFIX=/opt/qbt-output
QT_INSTALL=/opt/qt5-custom
OPENSSL_PREFIX=/opt/openssl-arm64
SRC_QT5=/build/qt-everywhere-src-5.15.2

export PATH=${TOOLCHAIN}/bin:$PATH
export CC=${TOOLCHAIN}/bin/aarch64-linux-android35-clang
export CXX=${TOOLCHAIN}/bin/aarch64-linux-android35-clang++

echo "============================================"
echo "Phase 1: Rebuild OpenSSL 3.3.2 (static, API 35)"
echo "============================================"
cd /build/openssl-3.3.2
make clean 2>/dev/null || true
./Configure android-arm64 -D__ANDROID_API__=35 \
    --prefix=${OPENSSL_PREFIX} --openssldir=${OPENSSL_PREFIX}/ssl \
    no-shared \
    2>&1 | tail -5
make -j$(nproc) 2>&1 | tail -5
make install_sw 2>&1 | tail -5
echo "OpenSSL static libs:"
ls -la ${OPENSSL_PREFIX}/lib/libssl.a ${OPENSSL_PREFIX}/lib/libcrypto.a
ls -la ${OPENSSL_PREFIX}/include/openssl/ssl.h

echo "============================================"
echo "Phase 2: Verify JNI patches in Qt5 source"
echo "============================================"
JNIHELPER=${SRC_QT5}/qtbase/src/corelib/kernel/qjnihelpers.cpp
if grep -q "extern.*JNI_OnLoad" "$JNIHELPER"; then
    echo "JNI_OnLoad already in qjnihelpers.cpp"
else
    echo "Adding JNI_OnLoad to qjnihelpers.cpp"
    sed -i '/^JavaVM \*QtAndroidPrivate::javaVM()/i\
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void * /*reserved*/)\
{\
    g_javaVM = vm;\
    return JNI_VERSION_1_6;\
}\
' "$JNIHELPER"
fi

JNIMAIN=${SRC_QT5}/qtbase/src/plugins/platforms/android/androidjnimain.cpp
if grep -q "JNI_OnLoad_Disabled" "$JNIMAIN"; then
    echo "androidjnimain.cpp JNI_OnLoad already disabled"
else
    echo "Disabling JNI_OnLoad in androidjnimain.cpp"
    sed -i 's/Q_DECL_EXPORT jint JNICALL JNI_OnLoad(/Q_DECL_EXPORT jint JNICALL JNI_OnLoad_Disabled_Disabled(/' "$JNIMAIN"
fi

echo "============================================"
echo "Phase 3: Configure Qt5 with -openssl-linked"
echo "============================================"
rm -rf /build/qt5-build
mkdir -p /build/qt5-build
cd /build/qt5-build

export OPENSSL_LIBS="-L${OPENSSL_PREFIX}/lib -lssl -lcrypto -lz"

echo "OPENSSL_LIBS=${OPENSSL_LIBS}"
echo "Configuring Qt5..."

${SRC_QT5}/configure \
    -prefix ${QT_INSTALL} \
    -platform linux-clang \
    -xplatform android-clang \
    -android-ndk ${NDK} \
    -android-sdk /opt/android-sdk \
    -android-arch arm64-v8a \
    -android-ndk-host linux-x86_64 \
    -android-ndk-platform android-35 \
    -no-gui -no-widgets -no-dbus -no-accessibility -no-opengl -no-vulkan \
    -openssl-linked \
    -I ${OPENSSL_PREFIX}/include \
    -no-libjpeg -no-libpng -no-harfbuzz -no-freetype -no-glib -no-mtdev -no-evdev -no-tslib -no-icu -no-cups -no-pch \
    -nomake tests -nomake examples \
    -skip qt3d -skip qtactiveqt -skip qtandroidextras -skip qtcharts \
    -skip qtconnectivity -skip qtdatavis3d -skip qtdeclarative -skip qtdoc \
    -skip qtgamepad -skip qtgraphicaleffects -skip qtimageformats -skip qtlocation \
    -skip qtlottie -skip qtmacextras -skip qtmultimedia -skip qtnetworkauth \
    -skip qtpurchasing -skip qtquick3d -skip qtquickcontrols -skip qtquickcontrols2 \
    -skip qtquicktimeline -skip qtremoteobjects -skip qtscript -skip qtscxml \
    -skip qtsensors -skip qtserialbus -skip qtserialport -skip qtspeech -skip qtsvg \
    -skip qttools -skip qttranslations -skip qtvirtualkeyboard -skip qtwayland \
    -skip qtwebchannel -skip qtwebengine -skip qtwebglplugin -skip qtwebsockets \
    -skip qtwebview -skip qtwinextras -skip qtx11extras -skip qtxmlpatterns \
    -opensource -confirm-license \
    -c++std c++17 \
    -shared

echo ""
echo "=== Checking configure result ==="
if grep -q "Qt directly linked to OpenSSL.*yes" config.summary 2>/dev/null; then
    echo "SUCCESS: OpenSSL linked = YES"
else
    echo "WARNING: OpenSSL linked may not be YES, checking..."
    grep -i "openssl" config.summary 2>/dev/null || echo "No openssl in config.summary"
fi
if [ ! -f /build/qt5-build/Makefile ]; then
    echo "ERROR: Qt5 configure failed - no Makefile generated!"
    tail -50 /build/qt5-build/config.log 2>/dev/null
    exit 1
fi

echo "============================================"
echo "Phase 4: Build Qt5 (this takes 30-60 min)"
echo "============================================"
make -j$(nproc) 2>&1 | tail -20
make install 2>&1 | tail -10
echo "Qt5 installed to ${QT_INSTALL}"
ls ${QT_INSTALL}/lib/libQt5Core*.so 2>/dev/null

echo "============================================"
echo "Phase 5: Rebuild libtorrent with static OpenSSL"
echo "============================================"
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
    -Dstatic_runtime=ON -Dencryption=ON -Ddeprecated-functions=OFF \
    2>&1 | tail -15
ninja -j$(nproc) 2>&1 | tail -10
ninja install 2>&1 | tail -5
echo "libtorrent built"

echo "============================================"
echo "Phase 6: Rebuild qBittorrent"
echo "============================================"
QBT_SRC=/build/qbittorrent-src

# Copy patched files
cp /build/docker-sources/qbittorrent/src/app/CMakeLists.txt ${QBT_SRC}/src/app/CMakeLists.txt
cp /build/docker-sources/qbittorrent/src/app/android_jni_bridge.cpp ${QBT_SRC}/src/app/android_jni_bridge.cpp
cp /build/docker-sources/qbittorrent/cmake/Modules/CheckPackages.cmake ${QBT_SRC}/cmake/Modules/CheckPackages.cmake
sed -i 's/Core Network Sql Xml LinguistTools/Core Network Sql Xml/g' ${QBT_SRC}/cmake/Modules/CheckPackages.cmake

# Build
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
    -DLibtorrentRasterbar_DIR=${PREFIX}/lib/cmake/LibtorrentRasterbar \
    2>&1 | tail -15

ninja -j$(nproc) 2>&1 | tail -20

echo "============================================"
echo "Phase 7: Collect output"
echo "============================================"
rm -rf /output/* && mkdir -p /output/lib
cp ${QT_INSTALL}/lib/libQt5Core_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Network_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Sql_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Xml_arm64-v8a.so /output/lib/
cp ${PREFIX}/lib/libtorrent-rasterbar.so /output/lib/
cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/
cp ${QT_INSTALL}/plugins/sqldrivers/libqsqlite.so /output/lib/libplugins_sqldrivers_qsqlite_arm64-v8a.so 2>/dev/null || true
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
echo "=== Final Output ==="
ls -lh /output/libqbt.so 2>/dev/null
ls -lh /output/lib/
echo ""
echo "=== OpenSSL linkage verification ==="
echo "Qt5Network:"
readelf -d /output/lib/libQt5Network_arm64-v8a.so 2>/dev/null | grep -i 'NEEDED\|openssl\|ssl\|crypto' | head -10 || true
echo ""
echo "Qt5Core:"
readelf -d /output/lib/libQt5Core_arm64-v8a.so 2>/dev/null | grep -i 'NEEDED' | head -10 || true
echo ""
echo "=== DONE ==="
