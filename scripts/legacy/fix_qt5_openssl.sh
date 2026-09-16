#!/bin/bash
set -e

QT_SRC="/build/qt-everywhere-src-5.15.2"
QT_BUILD="/build/qt5-build"
QT_INSTALL="/opt/qt5-custom"
NDK="/opt/android-sdk/ndk/27.0.12077973"
PREFIX=/opt/qbt-output

echo "=== 1. Patching qjni.cpp to handle NULL javaVM() ==="
JNI_FILE="${QT_SRC}/qtbase/src/corelib/kernel/qjni.cpp"

# Restore original first
cp /build/docker-sources/qt-everywhere-src-5.15.2.tar.xz /dev/null 2>/dev/null || true
# Re-apply patches (they might already be applied)
sed -i 's/        QtAndroidPrivate::javaVM()->DetachCurrentThread();/        if (QtAndroidPrivate::javaVM()) QtAndroidPrivate::javaVM()->DetachCurrentThread();/' "$JNI_FILE" 2>/dev/null || true

python3 -c "
with open('${JNI_FILE}', 'r') as f:
    c = f.read()
if 'if (!vm) return;' not in c:
    c = c.replace(
        'JavaVM *vm = QtAndroidPrivate::javaVM();\n    const jint ret = vm->GetEnv',
        'JavaVM *vm = QtAndroidPrivate::javaVM();\n    if (!vm) return;\n    const jint ret = vm->GetEnv'
    )
    with open('${JNI_FILE}', 'w') as f:
        f.write(c)
    print('Constructor patched')
else:
    print('Constructor already patched')
"

echo "=== 2. Fix mkspecs - clean up old OpenSSL entries ==="
MKSPEC="${QT_SRC}/qtbase/mkspecs/android-clang/qmake.conf"
# Remove any old OpenSSL entries
sed -i '/# OpenSSL paths for cross-compilation/,$ d' "$MKSPEC" 2>/dev/null || true

echo "=== 3. Create .qmake.conf with OpenSSL paths ==="
cat > "${QT_SRC}/.qmake.conf" << EOF
OPENSSL_INCDIR = ${PREFIX}/include
OPENSSL_LIBDIR = ${PREFIX}/lib
OPENSSL_LIBS = -L${PREFIX}/lib -lssl -lcrypto -ldl
QMAKE_INCDIR += ${PREFIX}/include
QMAKE_LIBDIR += ${PREFIX}/lib
EOF
echo "Created .qmake.conf:"
cat "${QT_SRC}/.qmake.conf"

echo "=== 4. Clean build dir and reconfigure Qt5 WITH OpenSSL ==="
cd ${QT_BUILD}
rm -rf * 2>/dev/null || true

# Also revert std::numeric_limits and backtrace patches if already applied
# These are idempotent so re-applying is fine
cd ${QT_SRC}

# Re-apply std::numeric_limits fix (idempotent)
find . -name "*.h" -o -name "*.cpp" | xargs grep -l "std::numeric_limits" 2>/dev/null | while read f; do
    if ! grep -q '#include <limits>' "$f"; then
        sed -i '0,/#include/{/#include/a #include <limits>}' "$f" 2>/dev/null || true
    fi
done
if [ -f qtbase/src/corelib/global/qendian.h ]; then
    if ! grep -q '#include <limits>' qtbase/src/corelib/global/qendian.h; then
        sed -i '1i #include <limits>' qtbase/src/corelib/global/qendian.h
    fi
fi

# Re-apply backtrace fix (idempotent)
if [ -f qtbase/src/corelib/global/qlogging.cpp ]; then
    if grep -q '__has_include(<execinfo.h>)' qtbase/src/corelib/global/qlogging.cpp && ! grep -q '!defined(Q_OS_ANDROID)' qtbase/src/corelib/global/qlogging.cpp; then
        sed -i 's/__has_include(<execinfo.h>)/(__has_include(<execinfo.h>) \&\& !defined(Q_OS_ANDROID))/g' qtbase/src/corelib/global/qlogging.cpp
    fi
fi

# Re-apply JNI_OnLoad disable (idempotent)
for f in $(find . -name "androidjnimain.cpp" -o -name "qjni*.cpp" 2>/dev/null); do
    sed -i 's/JNI_OnLoad/JNI_OnLoad_Disabled/g' "$f" 2>/dev/null || true
done

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
    -no-opengl -no-vulkan \
    -openssl-linked \
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
    2>&1 | tail -30

echo "=== 5. Build Qt5 ==="
make -j$(nproc) 2>&1 | tail -30

echo "=== 6. Install Qt5 ==="
make install 2>&1 | tail -10

echo "=== 7. Verify ==="
readelf -s ${QT_INSTALL}/lib/libQt5Network.so 2>/dev/null | grep -c QSslSocket && echo "SSL symbols found" || echo "No SSL symbols"
readelf -s ${QT_INSTALL}/lib/libQt5Core.so 2>/dev/null | grep -ci jni && echo "JNI symbols found" || echo "No JNI symbols"

echo "=== 8. Rebuild libtorrent ==="
cd /build/libtorrent-src
rm -rf build && mkdir build && cd build
cmake .. -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=${NDK}/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_shared \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_FIND_ROOT_PATH="${PREFIX}" -DBoost_INCLUDE_DIR=${PREFIX}/include \
    -DOPENSSL_ROOT_DIR=${PREFIX} -Dstatic_runtime=ON -Dencryption=ON -Ddeprecated-functions=OFF \
    2>&1 | tail -5
ninja -j4 2>&1 | tail -5
ninja install 2>&1 | tail -5

echo "=== 9. Restore & patch qBittorrent ==="
SRC="/build/qbittorrent-src"
cp /build/docker-sources/qbittorrent/cmake/Modules/CheckPackages.cmake ${SRC}/cmake/Modules/CheckPackages.cmake
cp /build/docker-sources/qbittorrent/src/app/CMakeLists.txt ${SRC}/src/app/CMakeLists.txt
sed -i 's/Core Network Sql Xml LinguistTools/Core Network Sql Xml/g' ${SRC}/cmake/Modules/CheckPackages.cmake

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

echo "=== 10. Build qBittorrent ==="
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
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_shared \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_FIND_ROOT_PATH="${PREFIX};${QT_INSTALL}" -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DQt5_DIR=${QT_INSTALL}/lib/cmake/Qt5 \
    -DGUI=OFF -DWEBUI=ON -DTESTING=OFF \
    -DOPENSSL_ROOT_DIR=${PREFIX} -DOPENSSL_INCLUDE_DIR=${PREFIX}/include \
    -DOPENSSL_CRYPTO_LIBRARY=${PREFIX}/lib/libcrypto.a -DOPENSSL_SSL_LIBRARY=${PREFIX}/lib/libssl.a \
    -DLibtorrentRasterbar_DIR=${PREFIX}/lib/cmake/LibtorrentRasterbar \
    2>&1 | tail -10

ninja -j4 2>&1 | tail -20
ninja install 2>&1 | tail -5

echo "=== 11. Collect output ==="
rm -rf /output/* && mkdir -p /output/lib
TOOLCHAIN=${NDK}/toolchains/llvm/prebuilt/linux-x86_64
cp ${PREFIX}/bin/qbittorrent-nox /output/
cp ${QT_INSTALL}/lib/libQt5Core.so /output/lib/libQt5Core_arm64-v8a.so
cp ${QT_INSTALL}/lib/libQt5Network.so /output/lib/libQt5Network_arm64-v8a.so
cp ${QT_INSTALL}/lib/libQt5Sql.so /output/lib/libQt5Sql_arm64-v8a.so
cp ${QT_INSTALL}/lib/libQt5Xml.so /output/lib/libQt5Xml_arm64-v8a.so
cp ${PREFIX}/lib/libtorrent-rasterbar.so /output/lib/
cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/
cp ${QT_INSTALL}/plugins/sqldrivers/libqsqlite.so /output/lib/libplugins_sqldrivers_qsqlite_arm64-v8a.so 2>/dev/null || true
${TOOLCHAIN}/bin/llvm-strip /output/qbittorrent-nox /output/lib/*.so 2>/dev/null || true
echo "=== Output ==="
ls -lh /output/ /output/lib/
echo "=== DONE ==="
