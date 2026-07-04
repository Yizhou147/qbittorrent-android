FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_NDK=${ANDROID_HOME}/ndk/27.0.12077973
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PREFIX=/opt/qbt-output
ENV TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64
ENV CC=${TOOLCHAIN}/bin/aarch64-linux-android24-clang
ENV CXX=${TOOLCHAIN}/bin/aarch64-linux-android24-clang++
ENV AR=${TOOLCHAIN}/bin/llvm-ar
ENV RANLIB=${TOOLCHAIN}/bin/llvm-ranlib
ENV STRIP=${TOOLCHAIN}/bin/llvm-strip

# 安装基础工具
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl wget unzip tar python3 python3-pip \
    build-essential cmake ninja-build pkg-config \
    openjdk-17-jdk-headless \
    && rm -rf /var/lib/apt/lists/*

# 安装 Android SDK + NDK
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    cd /tmp && \
    curl -fsSL -o cmdtools.zip \
      "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" && \
    python3 -c "import zipfile; zipfile.ZipFile('cmdtools.zip').extractall('${ANDROID_HOME}/cmdline-tools/')" && \
    mv ${ANDROID_HOME}/cmdline-tools/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest && \
    rm cmdtools.zip

ENV PATH="${JAVA_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

RUN yes | sdkmanager --licenses > /dev/null 2>&1 && \
    sdkmanager "platform-tools" "platforms;android-34" "ndk;27.0.12077973" "build-tools;34.0.0"

# ===== 编译 OpenSSL =====
WORKDIR /build
RUN curl -fsSL "https://www.openssl.org/source/openssl-3.3.2.tar.gz" | tar xz && \
    cd openssl-3.3.2 && \
    ./Configure android-arm64 -D__ANDROID_API__=24 \
        --prefix=${PREFIX} --openssldir=${PREFIX}/ssl \
        no-shared no-tests no-ui-console -fPIC && \
    make -j$(nproc) build_libs && make install_sw

# ===== 编译 Boost =====
RUN curl -fsSL "https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.gz" | tar xz && \
    cd boost_1_86_0 && \
    ./bootstrap.sh --with-toolset=clang && \
    cat > user-config.jam << 'EOF'
using clang : android
    : /opt/android-sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang++
    : <archiver>/opt/android-sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar
      <ranlib>/opt/android-sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ranlib
      <linkflags>-llog
      <compileflags>--target=aarch64-linux-android24
      <compileflags>-fPIC
    ;
EOF
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
        -j$(nproc) --abbreviate-paths -d0

# ===== 编译 libtorrent =====
RUN git clone --depth 1 --branch v2.0.10 \
      https://github.com/arvidn/libtorrent.git /build/libtorrent && \
    cd /build/libtorrent && mkdir build && cd build && \
    cmake .. \
        -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK}/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-24 \
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
        -Dencryption=ON && \
    cmake --build . -j$(nproc) && cmake --install .

# ===== 编译 qBittorrent =====
RUN git clone --depth 1 --branch v5.0.2 \
      https://github.com/qbittorrent/qBittorrent.git /build/qbittorrent && \
    cd /build/qbittorrent && mkdir build && cd build && \
    cmake .. \
        -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK}/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-24 \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
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
        -DLibtorrentRasterbar_DIR=${PREFIX}/lib/cmake/LibtorrentRasterbar && \
    cmake --build . -j$(nproc) && cmake --install .

# ===== 收集产物 =====
RUN mkdir -p /output/lib && \
    cp ${PREFIX}/bin/qbittorrent-nox /output/ && \
    cp ${PREFIX}/lib/*.so /output/lib/ 2>/dev/null; \
    ${STRIP} /output/qbittorrent-nox 2>/dev/null; true

CMD ["echo", "Build complete. Copy /output/qbittorrent-nox"]
