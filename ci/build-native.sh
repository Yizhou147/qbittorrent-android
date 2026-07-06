#!/bin/bash
set -ex

# Install Android NDK r25c
echo "=== Installing Android NDK ==="
curl -fsSL -o /tmp/ndk.zip https://dl.google.com/android/repository/android-ndk-r25c-linux.zip
unzip -q /tmp/ndk.zip -d /opt/
mv /opt/android-ndk-r25c /opt/ndk
rm /tmp/ndk.zip

export ANDROID_NDK_HOME=/opt/ndk
export ANDROID_NDK_ROOT=/opt/ndk
export TOOLCHAIN=${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64
export TARGET=aarch64-linux-android24
export API=24
export CC=${TOOLCHAIN}/bin/${TARGET}-clang
export CXX=${TOOLCHAIN}/bin/${TARGET}-clang++
export AR=${TOOLCHAIN}/bin/llvm-ar
export RANLIB=${TOOLCHAIN}/bin/llvm-ranlib
export STRIP=${TOOLCHAIN}/bin/llvm-strip
export PATH=${TOOLCHAIN}/bin:$PATH

# Step 1: Build OpenSSL
echo "=== Step 1: Build OpenSSL ==="
cd /build
tar xzf /src/openssl-3.3.2.tar.gz
cd openssl-3.3.2
./Configure android-arm64 no-shared no-tests \
  --prefix=/opt/openssl \
  -D__ANDROID_API__=${API}
make -j$(nproc) build_libs
make install_dev
cd /build && rm -rf openssl-3.3.2
echo "Done: OpenSSL"

# Step 2: Build Qt5
echo "=== Step 2: Build Qt5 ==="
cd /build
tar xf /src/qt-everywhere-src-5.15.2.tar.xz
cd qt-everywhere-src-5.15.2

# Patch: disable JNI_OnLoad in androidjnimain.cpp
JNI_FILE=$(find . -name "androidjnimain.cpp" | head -1)
if [ -n "$JNI_FILE" ]; then
  sed -i "s/JNI_OnLoad/JNI_OnLoad_Disabled/g" "$JNI_FILE"
fi

# Patch: add JNI_OnLoad to qjnihelpers.cpp
QJNI_FILE=$(find . -name "qjnihelpers.cpp" | head -1)
if [ -n "$QJNI_FILE" ]; then
  printf "\nextern \"C\" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void * /*reserved*/)\n{\n    extern JavaVM *g_javaVM;\n    g_javaVM = vm;\n    return JNI_VERSION_1_6;\n}\n" >> "$QJNI_FILE"
fi

# Patch: NULL check in qjni.cpp
QJNI2_FILE=$(find . -name "qjni.cpp" | head -1)
if [ -n "$QJNI2_FILE" ]; then
  sed -i "s/vm->GetEnv(\&env, JNI_VERSION_1_6)/vm ? vm->GetEnv(\&env, JNI_VERSION_1_6) : -1/g" "$QJNI2_FILE"
fi

mkdir -p /build/qt5-build && cd /build/qt5-build

../qt-everywhere-src-5.15.2/configure \
  -prefix /opt/qt5 \
  -platform linux-g++ \
  -xplatform android-clang \
  -android-ndk ${ANDROID_NDK_HOME} \
  -android-ndk-host linux-x86_64 \
  -android-arch arm64-v8a \
  -android-abis arm64-v8a \
  -no-gui -no-widgets \
  -no-opengl -no-vulkan \
  -openssl-linked -I/opt/openssl/include -L/opt/openssl/lib \
  -skip qtx11extras -skip qtmacextras -skip qtwinextras \
  -skip qtdeclarative -skip qtquickcontrols -skip qtquickcontrols2 \
  -skip qtmultimedia -skip qtwebengine -skip qtwebview \
  -skip qt3d -skip qtcanvas3d -skip qtcharts -skip qtdatavis3d \
  -skip qtgamepad -skip qtnetworkauth -skip qtpurchasing \
  -skip qtremoteobjects -skip qtscxml -skip qtsensors \
  -skip qtserialbus -skip qtserialport -skip qtspeech \
  -skip qtvirtualkeyboard -skip qtwebchannel -skip qtwebsockets \
  -skip qtsvg -skip qtgraphicaleffects -skip qtimageformats \
  -skip qtlottie -skip qtdoc \
  -nomake tests -nomake examples \
  -confirm-license \
  -opensource

make -j$(nproc)
make install
cd /build && rm -rf qt5-build qt-everywhere-src-5.15.2
echo "Done: Qt5"

# Step 3: Build Boost
echo "=== Step 3: Build Boost ==="
cd /build
tar xzf /src/boost_1_86_0.tar.gz
cd boost_1_86_0
echo "using clang : : ${CXX} : <archiver>${AR} <ranlib>${RANLIB} ;" > user-config.jam
./bootstrap.sh --prefix=/opt/boost
./b2 install --user-config=user-config.jam \
  toolset=clang \
  link=shared \
  threading=multi \
  variant=release \
  --with-system \
  -j$(nproc)
cd /build && rm -rf boost_1_86_0
echo "Done: Boost"

# Step 4: Build libtorrent
echo "=== Step 4: Build libtorrent ==="
cd /build
tar xzf /src/libtorrent-2.0.11.tar.gz
cd libtorrent-rasterbar-2.0.11
mkdir build && cd build
cmake .. \
  -DCMAKE_SYSTEM_NAME=Android \
  -DCMAKE_SYSTEM_VERSION=${API} \
  -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
  -DCMAKE_ANDROID_NDK=${ANDROID_NDK_HOME} \
  -DCMAKE_C_COMPILER=${CC} \
  -DCMAKE_CXX_COMPILER=${CXX} \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_INSTALL_PREFIX=/opt/libtorrent \
  -DCMAKE_BUILD_TYPE=Release \
  -DBoost_INCLUDE_DIR=/opt/boost/include \
  -DBoost_SYSTEM_LIBRARY=/opt/boost/lib/libboost_system.so \
  -Dshared=ON \
  -Dstatic=OFF
make -j$(nproc)
make install
cd /build && rm -rf libtorrent-rasterbar-2.0.11
echo "Done: libtorrent"

# Step 5: Build qBittorrent
echo "=== Step 5: Build qBittorrent ==="
cd /build
tar xzf /src/qbittorrent-4.6.7.tar.gz
cd qbittorrent-4.6.7

# Copy patched JNI bridge
if [ -f /patches/android_jni_bridge.cpp ]; then
  cp /patches/android_jni_bridge.cpp src/app/
fi
if [ -f /patches/CMakeLists.txt ]; then
  cp /patches/CMakeLists.txt src/app/
fi
if [ -f /patches/CheckPackages.cmake ]; then
  cp /patches/CheckPackages.cmake cmake/Modules/
fi

mkdir build && cd build
export CMAKE_PREFIX_PATH="/opt/qt5;/opt/libtorrent;/opt/boost;/opt/openssl"
export LD_LIBRARY_PATH="/opt/qt5/lib:/opt/libtorrent/lib:/opt/boost/lib:/opt/openssl/lib"

cmake .. \
  -DCMAKE_SYSTEM_NAME=Android \
  -DCMAKE_SYSTEM_VERSION=${API} \
  -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
  -DCMAKE_ANDROID_NDK=${ANDROID_NDK_HOME} \
  -DCMAKE_C_COMPILER=${CC} \
  -DCMAKE_CXX_COMPILER=${CXX} \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DCMAKE_BUILD_TYPE=Release \
  -DQT6=OFF \
  -DWEBUI=ON \
  -DSTACKTRACE=OFF \
  -DTESTING=OFF

make -j$(nproc)

# Collect output
QBT_LIB=$(find . -name "libqbt*.so" -not -path "*_autogen*" | head -1)
cp "$QBT_LIB" /output/libqbt.so
${STRIP} /output/libqbt.so

echo "Done: qBittorrent"
ls -lh /output/libqbt.so
