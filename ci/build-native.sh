#!/bin/bash
set -ex

PREFIX=/opt/qbt-output
QT5_ANDROID=/opt/qt5-android/5.15.2/android

# Install Android NDK r27b
echo "=== Installing Android NDK ==="
curl -fsSL -o /tmp/ndk.zip https://dl.google.com/android/repository/android-ndk-r27b-linux.zip
unzip -q /tmp/ndk.zip -d /opt/
mv /opt/android-ndk-r27b /opt/ndk
rm /tmp/ndk.zip

export ANDROID_NDK=/opt/ndk
export ANDROID_NDK_HOME=/opt/ndk
export ANDROID_NDK_ROOT=/opt/ndk
export TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64
export CC=${TOOLCHAIN}/bin/aarch64-linux-android24-clang
export CXX=${TOOLCHAIN}/bin/aarch64-linux-android24-clang++
export AR=${TOOLCHAIN}/bin/llvm-ar
export RANLIB=${TOOLCHAIN}/bin/llvm-ranlib
export STRIP=${TOOLCHAIN}/bin/llvm-strip
export PATH=${TOOLCHAIN}/bin:$PATH

# Step 1: Install pre-built Qt5 via aqtinstall
echo "=== Step 1: Install pre-built Qt5 ==="
pip3 install --no-cache-dir aqtinstall -i https://pypi.tuna.tsinghua.edu.cn/simple
aqt install-qt linux android 5.15.2 android -O /opt/qt5-android
echo "Qt5 installed at:"
find /opt/qt5-android -name "Qt5Config.cmake" | head -5
echo "Done: Qt5"

# Step 2: Build OpenSSL
echo "=== Step 2: Build OpenSSL ==="
cd /build
tar xzf /src/openssl-3.3.2.tar.gz
cd openssl-3.3.2
./Configure android-arm64 -D__ANDROID_API__=24 \
  --prefix=${PREFIX} --openssldir=${PREFIX}/ssl \
  no-shared no-tests no-ui-console -fPIC
make -j$(nproc) build_libs
make install_sw
cd /build && rm -rf openssl-3.3.2
echo "Done: OpenSSL"

# Step 3: Build Boost
echo "=== Step 3: Build Boost ==="
cd /build
tar xzf /src/boost_1_86_0.tar.gz
cd boost_1_86_0
./bootstrap.sh --with-toolset=clang
echo "using clang : android : ${TOOLCHAIN}/bin/aarch64-linux-android24-clang++ : <archiver>${TOOLCHAIN}/bin/llvm-ar <ranlib>${TOOLCHAIN}/bin/llvm-ranlib <linkflags>-llog <compileflags>--target=aarch64-linux-android24 <compileflags>-fPIC ;" > user-config.jam
./b2 install \
  --prefix=${PREFIX} \
  --with-system --with-filesystem --with-thread \
  --with-date_time --with-chrono --with-random \
  --with-program_options \
  --user-config=user-config.jam \
  toolset=clang-android \
  link=static threading=multi variant=release \
  runtime-link=static target-os=android \
  architecture=arm address-model=64 \
  cxxflags="-std=c++17 --target=aarch64-linux-android24" \
  linkflags="--target=aarch64-linux-android24 -llog" \
  -j$(nproc) --abbreviate-paths -d1
cd /build && rm -rf boost_1_86_0
echo "Done: Boost"

# Step 4: Build libtorrent
echo "=== Step 4: Build libtorrent ==="
cd /build
tar xzf /src/libtorrent-2.0.11.tar.gz
cd libtorrent-rasterbar-2.0.11
mkdir build && cd build
cmake .. \
  -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK}/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DANDROID_STL=c++_shared \
  -DCMAKE_INSTALL_PREFIX=${PREFIX} \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBoost_INCLUDE_DIR=${PREFIX}/include \
  -DBoost_SYSTEM_LIBRARY=${PREFIX}/lib/libboost_system.a \
  -DBoost_FILESYSTEM_LIBRARY=${PREFIX}/lib/libboost_filesystem.a \
  -DBoost_THREAD_LIBRARY=${PREFIX}/lib/libboost_thread.a \
  -DBoost_DATE_TIME_LIBRARY=${PREFIX}/lib/libboost_date_time.a \
  -DBoost_CHRONO_LIBRARY=${PREFIX}/lib/libboost_chrono.a \
  -DBoost_RANDOM_LIBRARY=${PREFIX}/lib/libboost_random.a \
  -DBoost_PROGRAM_OPTIONS_LIBRARY=${PREFIX}/lib/libboost_program_options.a \
  -DOPENSSL_ROOT_DIR=${PREFIX} \
  -DOPENSSL_INCLUDE_DIR=${PREFIX}/include \
  -DOPENSSL_CRYPTO_LIBRARY=${PREFIX}/lib/libcrypto.a \
  -DOPENSSL_SSL_LIBRARY=${PREFIX}/lib/libssl.a \
  -Dstatic_runtime=ON \
  -Dencryption=ON
cmake --build . -j$(nproc)
cmake --install .
cd /build && rm -rf libtorrent-rasterbar-2.0.11

# Strip libtorrent shared library (remove debug symbols, ~124MB -> ~10MB)
echo "Stripping libtorrent-rasterbar.so..."
${STRIP} ${PREFIX}/lib/libtorrent-rasterbar.so
ls -lh ${PREFIX}/lib/libtorrent-rasterbar.so

# Verify required symbols are exported
echo "Verifying libtorrent symbols..."
${TOOLCHAIN}/bin/llvm-nm -D ${PREFIX}/lib/libtorrent-rasterbar.so | grep -c "add_torrent_params" && echo "OK: add_torrent_params symbols found" || echo "WARNING: add_torrent_params symbols NOT found"

echo "Done: libtorrent"

# Step 5: Build qBittorrent
echo "=== Step 5: Build qBittorrent ==="
cd /build
tar xzf /src/qbittorrent-4.6.7.tar.gz
cd qBittorrent-release-4.6.7

# Apply Android patches
echo "Applying Android patches..."
# 1. JNI bridge (new file)
cp /patches/android_jni_bridge.cpp src/app/
# 2. Modified src/app/CMakeLists.txt (Android shared lib + skip LinguistTools)
cp /patches/app_CMakeLists.txt src/app/CMakeLists.txt
# 3. Modified cmake/Modules/CheckPackages.cmake (skip LinguistTools for Qt5)
cp /patches/CheckPackages.cmake cmake/Modules/CheckPackages.cmake
# 4. Patch resumedatastorage.cpp to replace QThread::create
python3 /patches/patch_resumedata.py src/base/bittorrent/resumedatastorage.cpp

mkdir build && cd build
cmake .. \
  -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK}/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DANDROID_STL=c++_shared \
  -DCMAKE_INSTALL_PREFIX=${PREFIX} \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_FIND_ROOT_PATH="${PREFIX};${QT5_ANDROID}" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
  -DQt5_DIR=${QT5_ANDROID}/lib/cmake/Qt5 \
  -DGUI=OFF \
  -DWEBUI=ON \
  -DTESTING=OFF \
  -DBoost_INCLUDE_DIR=${PREFIX}/include \
  -DBoost_SYSTEM_LIBRARY=${PREFIX}/lib/libboost_system.a \
  -DBoost_FILESYSTEM_LIBRARY=${PREFIX}/lib/libboost_filesystem.a \
  -DBoost_THREAD_LIBRARY=${PREFIX}/lib/libboost_thread.a \
  -DBoost_DATE_TIME_LIBRARY=${PREFIX}/lib/libboost_date_time.a \
  -DBoost_CHRONO_LIBRARY=${PREFIX}/lib/libboost_chrono.a \
  -DBoost_RANDOM_LIBRARY=${PREFIX}/lib/libboost_random.a \
  -DBoost_PROGRAM_OPTIONS_LIBRARY=${PREFIX}/lib/libboost_program_options.a \
  -DOPENSSL_ROOT_DIR=${PREFIX} \
  -DOPENSSL_INCLUDE_DIR=${PREFIX}/include \
  -DOPENSSL_CRYPTO_LIBRARY=${PREFIX}/lib/libcrypto.a \
  -DOPENSSL_SSL_LIBRARY=${PREFIX}/lib/libssl.a \
  -DLibtorrentRasterbar_DIR=${PREFIX}/lib/cmake/LibtorrentRasterbar

cmake --build . -j$(nproc)

# Collect output
mkdir -p /output/lib
cp ${PREFIX}/lib/libtorrent-rasterbar.so /output/lib/ 2>/dev/null || true
cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/ 2>/dev/null || true

# Copy qBittorrent .so (name is libqbt_arm64-v8a.so, not libqbittorrent*)
find . -name "libqbt*.so" -o -name "libqbt*.so.*" | head -5 | while read f; do
  cp "$f" /output/lib/libqbt.so
done
# Also check install prefix for the .so
find ${PREFIX} -name "libqbt*.so" -o -name "libqbt*.so.*" | head -5 | while read f; do
  cp "$f" /output/lib/libqbt.so
done

# Strip all .so files in output
echo "Stripping all .so files in output..."
for f in /output/lib/*.so; do
  ${STRIP} "$f" 2>/dev/null || true
done
ls -lh /output/lib/

echo "Done: qBittorrent"
ls -lh /output/
