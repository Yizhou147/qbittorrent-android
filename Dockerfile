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

# ===== 安装基础工具 =====
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl wget unzip tar p7zip python3 python3-pip \
    build-essential cmake ninja-build pkg-config \
    clang perl \
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

# 确保 sdkmanager 有执行权限并接受许可
RUN chmod +x ${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager && \
    chmod +x ${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager && \
    yes | sdkmanager --licenses > /dev/null 2>&1 || true && \
    sdkmanager "platform-tools" "platforms;android-34" "ndk;27.0.12077973" "build-tools;34.0.0"

# ===== 编译 OpenSSL =====
WORKDIR /build
RUN curl -fsSL "https://www.openssl.org/source/openssl-3.3.2.tar.gz" | tar xz && \
    cd openssl-3.3.2 && \
    export ANDROID_NDK_ROOT=${ANDROID_NDK} && \
    export PATH=${TOOLCHAIN}/bin:${PATH} && \
    ./Configure android-arm64 -D__ANDROID_API__=24 \
        --prefix=${PREFIX} --openssldir=${PREFIX}/ssl \
        no-shared no-tests no-ui-console -fPIC && \
    make -j$(nproc) build_libs && make install_sw

# ===== 编译 Boost =====
RUN curl -fsSL "https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.gz" | tar xz && \
    cd boost_1_86_0 && \
    ./bootstrap.sh --with-toolset=clang && \
    echo "using clang : android : ${TOOLCHAIN}/bin/aarch64-linux-android24-clang++ : <archiver>${TOOLCHAIN}/bin/llvm-ar <ranlib>${TOOLCHAIN}/bin/llvm-ranlib <linkflags>-llog <compileflags>--target=aarch64-linux-android24 <compileflags>-fPIC ;" > user-config.jam && \
    cat user-config.jam && \
    ${TOOLCHAIN}/bin/aarch64-linux-android24-clang++ --version && \
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

# ===== 编译 libtorrent =====
RUN git clone --depth 1 --recursive --branch v2.0.10 \
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

# ===== 编译 Qt5 for Android (qBittorrent 4.6.7 需要) =====
# Qt5 Android 预编译包已下架，需要从源码编译
RUN cd /tmp && \
    curl -fsSL -o qt5-src.tar.xz "https://download.qt.io/official_releases/qt/5.15/5.15.2/single/qt-everywhere-src-5.15.2.tar.xz" && \
    tar xf qt5-src.tar.xz && \
    mv qt-everywhere-src-5.15.2 /opt/qt5-src && \
    rm qt5-src.tar.xz

# 先为主机编译 Qt5 工具 (qmake 等)
RUN cd /opt/qt5-src && \
    ./configure -prefix /opt/qt5-host \
        -opensource -confirm-license \
        -nomake tests -nomake examples \
        -skip qtwebengine -skip qt3d -skip qtquick3d \
        -skip qtdatavis3d -skip qtlottie -skip qtscxml \
        -skip qtspeech -skip qtgamepad -skip qtpurchasing \
        -skip qtremoteobjects -skip qtsensors -skip qtserialbus \
        -skip qtserialport -skip qtlocation -skip qtmultimedia \
        -skip qtwebview -skip qtwebsockets -skip qtwebchannel \
        -skip qtconnectivity -skip qtgraphicaleffects \
        -skip qtquickcontrols -skip qtquickcontrols2 \
        -skip qtdeclarative -skip qtxmlpatterns \
        -skip qtcanvas3d -skip qtdoc -skip qttranslations \
        -skip qtactiveqt -skip qtx11extras && \
    make -j$(nproc) && make install

# 使用 NDK 交叉编译 Qt5 for Android ARM64
RUN cd /opt/qt5-src && \
    export ANDROID_SDK_ROOT=${ANDROID_HOME} && \
    export ANDROID_NDK_ROOT=${ANDROID_NDK} && \
    export PATH=/opt/qt5-host/bin:${TOOLCHAIN}/bin:${PATH} && \
    export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 && \
    ./configure -prefix /opt/qt5-android \
        -opensource -confirm-license \
        -xplatform android-clang \
        -android-ndk ${ANDROID_NDK} \
        -android-sdk ${ANDROID_HOME} \
        -android-abis arm64-v8a \
        -android-api-level 24 \
        -nomake tests -nomake examples \
        -skip qtwebengine -skip qt3d -skip qtquick3d \
        -skip qtdatavis3d -skip qtlottie -skip qtscxml \
        -skip qtspeech -skip qtgamepad -skip qtpurchasing \
        -skip qtremoteobjects -skip qtsensors -skip qtserialbus \
        -skip qtserialport -skip qtlocation -skip qtmultimedia \
        -skip qtwebview -skip qtwebsockets -skip qtwebchannel \
        -skip qtconnectivity -skip qtgraphicaleffects \
        -skip qtquickcontrols -skip qtquickcontrols2 \
        -skip qtdeclarative -skip qtxmlpatterns \
        -skip qtcanvas3d -skip qtdoc -skip qttranslations \
        -skip qtactiveqt -skip qtx11extras \
        -no-compile-examples && \
    make -j$(nproc) && make install

# ===== 编译 qBittorrent =====
RUN git clone --depth 1 --branch release-4.6.7 \
      https://github.com/qbittorrent/qBittorrent.git /build/qbittorrent && \
    cd /build/qbittorrent && mkdir build && cd build && \
    QT5_DIR=$(find /opt/qt5 -name "Qt5Config.cmake" -exec dirname {} \; | head -1) && \
    echo "Qt5 found at: $QT5_DIR" && \
    cmake .. \
        -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK}/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-24 \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_FIND_ROOT_PATH="${PREFIX};/opt/qt5" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
        -DQt5_DIR=$QT5_DIR \
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
