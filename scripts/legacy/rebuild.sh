#!/bin/bash
set -e

export ANDROID_NDK=/opt/android-sdk/ndk/27.0.12077973
export PREFIX=/opt/qbt-output
export TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64

echo "===== Rebuilding libtorrent with c++_shared ====="
cd /build/libtorrent-src
rm -rf build && mkdir build && cd build
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
echo "===== libtorrent DONE ====="

echo "===== Rebuilding qBittorrent with c++_shared ====="
QT5_ANDROID=/opt/qt5-prebuilt/5.15.2/android
cd /build/qbittorrent-src
rm -rf build && mkdir build && cd build
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
cmake --install .
echo "===== qBittorrent DONE ====="

echo "===== Collecting output ====="
rm -rf /output/*
mkdir -p /output/lib
cp ${PREFIX}/bin/qbittorrent-nox /output/
cp ${PREFIX}/lib/*.so /output/lib/ 2>/dev/null || true
cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/ 2>/dev/null || true
${TOOLCHAIN}/bin/llvm-strip /output/qbittorrent-nox 2>/dev/null || true
${TOOLCHAIN}/bin/llvm-strip /output/lib/*.so 2>/dev/null || true
echo "===== Output files ====="
ls -lh /output/
ls -lh /output/lib/
echo "===== ALL DONE ====="
