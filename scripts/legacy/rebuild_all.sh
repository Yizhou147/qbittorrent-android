#!/bin/bash
set -e

NDK=/opt/android-sdk/ndk/27.0.12077973
TOOLCHAIN=${NDK}/toolchains/llvm/prebuilt/linux-x86_64
PREFIX=/opt/qbt-output
QT_INSTALL=/opt/qt5-custom
export PATH=${TOOLCHAIN}/bin:$PATH
export CC=${TOOLCHAIN}/bin/aarch64-linux-android35-clang
export CXX=${TOOLCHAIN}/bin/aarch64-linux-android35-clang++

QT_SRC="/build/qt-everywhere-src-5.15.2"

echo "=== 1. Fix JNI_OnLoad: selective re-enable ==="
# Step 1a: First, revert ALL files to original JNI_OnLoad (undo previous blanket disable)
for f in $(find ${QT_SRC} -name "androidjnimain.cpp" -o -name "qjnihelpers.cpp" -o -name "qjni*.cpp" 2>/dev/null); do
    sed -i 's/JNI_OnLoad_Disabled/JNI_OnLoad/g' "$f" 2>/dev/null || true
done
echo "Reverted all JNI_OnLoad_Disabled to JNI_OnLoad"

# Step 1b: Now selectively disable ONLY in androidjnimain.cpp (Qt platform plugin init)
for f in $(find ${QT_SRC} -name "androidjnimain.cpp" 2>/dev/null); do
    sed -i 's/JNI_OnLoad/JNI_OnLoad_Disabled/g' "$f" 2>/dev/null || true
    echo "Disabled JNI_OnLoad in: $f"
done

# Step 1c: Verify qjnihelpers.cpp has JNI_OnLoad (should NOT be disabled)
QJNI_HELPERS=$(find ${QT_SRC} -name "qjnihelpers.cpp" -path "*/android/*" | head -1)
if [ -n "$QJNI_HELPERS" ]; then
    if grep -q 'JNI_OnLoad_Disabled' "$QJNI_HELPERS"; then
        echo "ERROR: qjnihelpers.cpp still has JNI_OnLoad_Disabled!"
        exit 1
    fi
    echo "OK: qjnihelpers.cpp has JNI_OnLoad enabled"
fi

# Step 1d: Keep NULL check in qjni.cpp (safety net for vm->GetEnv)
JNI_FILE="${QT_SRC}/qtbase/src/corelib/kernel/qjni.cpp"
python3 -c "
with open('${JNI_FILE}', 'r') as f:
    c = f.read()
# Ensure destructor NULL check
c = c.replace(
    'QtAndroidPrivate::javaVM()->DetachCurrentThread();',
    'if (QtAndroidPrivate::javaVM()) QtAndroidPrivate::javaVM()->DetachCurrentThread();'
)
# Ensure constructor NULL check
if 'if (!vm) return;' not in c:
    c = c.replace(
        'JavaVM *vm = QtAndroidPrivate::javaVM();\n    const jint ret = vm->GetEnv',
        'JavaVM *vm = QtAndroidPrivate::javaVM();\n    if (!vm) return;\n    const jint ret = vm->GetEnv'
    )
with open('${JNI_FILE}', 'w') as f:
    f.write(c)
print('qjni.cpp NULL checks verified')
"

echo "=== 2. Rebuild OpenSSL as shared ==="
cd /build
rm -rf openssl-3.3.2
tar xzf /build/docker-sources/openssl-3.3.2.tar.gz
cd openssl-3.3.2
./Configure android-arm64 -D__ANDROID_API__=35 \
    --prefix=${PREFIX} --openssldir=${PREFIX}/ssl \
    shared \
    2>&1 | tail -5
make -j4 2>&1 | tail -5
make install_sw 2>&1 | tail -5
echo "OpenSSL shared libs:"
ls -la ${PREFIX}/lib/libssl.so* ${PREFIX}/lib/libcrypto.so* 2>/dev/null

echo "=== 3. Clean and rebuild Qt5 ==="
QT_BUILD="/build/qt5-build"
rm -rf ${QT_BUILD} && mkdir -p ${QT_BUILD} && cd ${QT_BUILD}

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
    -openssl-runtime \
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

make -j4 2>&1 | tail -10
make install 2>&1 | tail -5
echo "Qt5 installed"

echo "=== 4. Rebuild libtorrent ==="
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
echo "libtorrent built"

echo "=== 5. Restore and patch qBittorrent ==="
SRC=/build/qbittorrent-src
cp /build/docker-sources/qbittorrent/cmake/Modules/CheckPackages.cmake ${SRC}/cmake/Modules/CheckPackages.cmake
cp /build/docker-sources/qbittorrent/src/app/CMakeLists.txt ${SRC}/src/app/CMakeLists.txt
sed -i 's/Core Network Sql Xml LinguistTools/Core Network Sql Xml/g' ${SRC}/cmake/Modules/CheckPackages.cmake

APP_CMAKE="${SRC}/src/app/CMakeLists.txt"
WEBUI_LINE=$(grep -n '^if (WEBUI)' "$APP_CMAKE" | head -1 | cut -d: -f1)
ENDIF_LINE=$(tail -n +$WEBUI_LINE "$APP_CMAKE" | grep -n '^endif()' | head -1 | cut -d: -f1)
ENDIF_LINE=$((WEBUI_LINE + ENDIF_LINE - 1))
{
  echo '# Translation disabled for Android'
  echo 'set(QBT_QM_FILES "")'
  echo 'set(QBT_WEBUI_QM_FILES "")'
  echo ''
  tail -n +$((ENDIF_LINE + 1)) "$APP_CMAKE"
} > /tmp/cmake_new.txt
mv /tmp/cmake_new.txt "$APP_CMAKE"

echo "=== 6. Build qBittorrent ==="
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

echo "=== 7. Collect output ==="
rm -rf /output/* && mkdir -p /output/lib
cp ${PREFIX}/bin/qbittorrent-nox /output/
# Qt5 libs use _arm64-v8a suffix for Android cross-compilation
cp ${QT_INSTALL}/lib/libQt5Core_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Network_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Sql_arm64-v8a.so /output/lib/
cp ${QT_INSTALL}/lib/libQt5Xml_arm64-v8a.so /output/lib/
cp ${PREFIX}/lib/libtorrent-rasterbar.so /output/lib/
cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/
cp ${QT_INSTALL}/plugins/sqldrivers/libplugins_sqldrivers_qsqlite_arm64-v8a.so /output/lib/ 2>/dev/null || \
    cp ${QT_INSTALL}/plugins/sqldrivers/libqsqlite.so /output/lib/libplugins_sqldrivers_qsqlite_arm64-v8a.so 2>/dev/null || true
# Copy OpenSSL shared libs for runtime loading by Qt5
cp ${PREFIX}/lib/libssl.so /output/lib/
cp ${PREFIX}/lib/libcrypto.so /output/lib/
${TOOLCHAIN}/bin/llvm-strip /output/qbittorrent-nox /output/lib/*.so 2>/dev/null || true
echo "=== Output ==="
ls -lh /output/ /output/lib/
echo "=== DONE ==="
