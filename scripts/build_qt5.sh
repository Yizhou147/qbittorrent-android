#!/bin/bash
set -e

export ANDROID_NDK=/opt/android-sdk/ndk/27.0.12077973
export PREFIX=/opt/qt5-custom
export TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64
export OPENSSL_PREFIX=/opt/qbt-output

echo "===== Extracting Qt5 source ====="
cd /build
if [ ! -d qt-everywhere-src-5.15.2 ]; then
    tar xf /build/docker-sources/qt-everywhere-src-5.15.2.tar.xz -C /build/
fi

echo "===== Patching Qt5 ====="
cd /build/qt-everywhere-src-5.15.2

# Fix std::numeric_limits issue - add #include <limits> where needed
find . -name "*.h" -o -name "*.cpp" | xargs grep -l "std::numeric_limits" 2>/dev/null | while read f; do
    if ! grep -q '#include <limits>' "$f"; then
        sed -i '0,/#include/{/#include/a #include <limits>
}' "$f"
    fi
done

# Fix qendian.h specifically
if [ -f qtbase/src/corelib/global/qendian.h ]; then
    if ! grep -q '#include <limits>' qtbase/src/corelib/global/qendian.h; then
        sed -i '1i #include <limits>' qtbase/src/corelib/global/qendian.h
    fi
fi

# Disable JNI
for f in $(find . -name "*.cpp" -path "*/android/*" | head -20); do
    if grep -q "JNI_OnLoad" "$f" 2>/dev/null; then
        echo "Patching JNI: $f"
        sed -i 's/JNI_OnLoad/JNI_OnLoad_Disabled/g' "$f"
    fi
done
for f in $(find . -name "androidjnimain.cpp" -o -name "qjni*.cpp" 2>/dev/null); do
    echo "Patching JNI: $f"
    sed -i 's/JNI_OnLoad/JNI_OnLoad_Disabled/g' "$f"
done

# Fix backtrace issue on Android
if [ -f qtbase/src/corelib/global/qlogging.cpp ]; then
    sed -i 's/__has_include(<execinfo.h>)/(__has_include(<execinfo.h>) \&\& !defined(Q_OS_ANDROID))/g' \
        qtbase/src/corelib/global/qlogging.cpp
    echo "Patched qlogging.cpp for backtrace"
fi

# Add OpenSSL paths to Android mkspecs for cross-compilation
echo "Patching mkspecs for OpenSSL..."
echo "" >> qtbase/mkspecs/android-clang/qmake.conf
echo "# OpenSSL paths for cross-compilation" >> qtbase/mkspecs/android-clang/qmake.conf
echo "QMAKE_INCDIR += ${OPENSSL_PREFIX}/include" >> qtbase/mkspecs/android-clang/qmake.conf
echo "QMAKE_LIBDIR += ${OPENSSL_PREFIX}/lib" >> qtbase/mkspecs/android-clang/qmake.conf
echo "OPENSSL_INCDIR = ${OPENSSL_PREFIX}/include" >> qtbase/mkspecs/android-clang/qmake.conf
echo "OPENSSL_LIBDIR = ${OPENSSL_PREFIX}/lib" >> qtbase/mkspecs/android-clang/qmake.conf
echo "OPENSSL_LIBS = -L${OPENSSL_PREFIX}/lib -lssl -lcrypto -ldl" >> qtbase/mkspecs/android-clang/qmake.conf

echo "===== Configuring Qt5 ====="
mkdir -p /build/qt5-build && cd /build/qt5-build
rm -rf * 2>/dev/null || true

../qt-everywhere-src-5.15.2/configure \
    -prefix ${PREFIX} \
    -platform linux-clang \
    -xplatform android-clang \
    -android-ndk ${ANDROID_NDK} \
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
    2>&1 | tail -60

echo "===== Building Qt5 ====="
make -j$(nproc) 2>&1 | tail -30

echo "===== Installing Qt5 ====="
make install 2>&1

echo "===== Result ====="
ls -la ${PREFIX}/lib/libQt5*.so 2>/dev/null || echo "No .so files"
readelf -s ${PREFIX}/lib/libQt5Core.so 2>/dev/null | grep -ci jni && echo "JNI found!" || echo "No JNI symbols - GOOD"
readelf -s ${PREFIX}/lib/libQt5Network.so 2>/dev/null | grep -ci ssl && echo "SSL symbols found - GOOD" || echo "No SSL symbols"
echo "DONE"
