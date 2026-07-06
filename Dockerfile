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

# ===== 配置 apt 镜像源 (回退机制) =====
RUN (sed -i 's|http://archive.ubuntu.com|http://mirrors.ustc.edu.cn|g' /etc/apt/sources.list && \
     sed -i 's|http://security.ubuntu.com|http://mirrors.ustc.edu.cn|g' /etc/apt/sources.list) || \
    (sed -i 's|http://mirrors.ustc.edu.cn|http://archive.ubuntu.com|g' /etc/apt/sources.list; true)

# ===== 安装基础工具 =====
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl wget unzip tar p7zip-full python3 python3-pip \
    build-essential cmake ninja-build pkg-config \
    clang perl \
    openjdk-17-jdk-headless \
    qttools5-dev-tools \
    && rm -rf /var/lib/apt/lists/*

# ===== 复制本地源码包 =====
COPY docker-sources/openssl-3.3.2.tar.gz /tmp/
COPY docker-sources/boost_1_86_0.tar.gz /tmp/
COPY docker-sources/libtorrent /build/libtorrent-src
COPY docker-sources/qbittorrent /build/qbittorrent-src

# ===== 安装 Android SDK =====
# 安装 SDK platform 34 (本地文件)
COPY docker-sources/platform-34-ext7_r02.zip /tmp/
RUN mkdir -p ${ANDROID_HOME}/platforms && \
    unzip -q /tmp/platform-34-ext7_r02.zip -d ${ANDROID_HOME}/platforms/ && \
    rm /tmp/platform-34-ext7_r02.zip

# 安装 build-tools 34.0.0 (本地文件)
COPY docker-sources/build-tools_r34-linux.zip /tmp/
RUN mkdir -p ${ANDROID_HOME}/build-tools/34.0.0 && \
    mkdir -p /tmp/bt-extract && \
    unzip -q /tmp/build-tools_r34-linux.zip -d /tmp/bt-extract && \
    mv /tmp/bt-extract/*/* ${ANDROID_HOME}/build-tools/34.0.0/ 2>/dev/null; \
    mv /tmp/bt-extract/* ${ANDROID_HOME}/build-tools/34.0.0/ 2>/dev/null; \
    rm -rf /tmp/build-tools_r34-linux.zip /tmp/bt-extract

# ===== 安装 NDK 27 (本地文件) =====
COPY docker-sources/android-ndk-r27b-linux.zip /tmp/
RUN mkdir -p ${ANDROID_HOME}/ndk && \
    unzip -q /tmp/android-ndk-r27b-linux.zip -d /tmp/ndk-extract && \
    mv /tmp/ndk-extract/android-ndk-r27b ${ANDROID_HOME}/ndk/27.0.12077973 && \
    rm -rf /tmp/android-ndk-r27b-linux.zip /tmp/ndk-extract

ENV PATH="${JAVA_HOME}/bin:${ANDROID_HOME}/platform-tools:${PATH}"

# ===== 安装预编译 Qt5 for Android (本地文件) =====
COPY docker-sources/qtbase-android.7z /tmp/
RUN mkdir -p /opt/qt5-prebuilt/5.15.2/android && \
    cd /opt/qt5-prebuilt/5.15.2/android && \
    7z x -y /tmp/qtbase-android.7z && \
    rm -f /tmp/qtbase-android.7z && \
    echo "Qt5 installed at:" && find /opt/qt5-prebuilt -name "Qt5Config.cmake"

# ===== 编译 OpenSSL =====
WORKDIR /build
RUN tar xzf /tmp/openssl-3.3.2.tar.gz && \
    cd openssl-3.3.2 && \
    export ANDROID_NDK_ROOT=${ANDROID_NDK} && \
    export PATH=${TOOLCHAIN}/bin:${PATH} && \
    ./Configure android-arm64 -D__ANDROID_API__=24 \
        --prefix=${PREFIX} --openssldir=${PREFIX}/ssl \
        no-shared no-tests no-ui-console -fPIC && \
    make -j$(nproc) build_libs && make install_sw

# ===== 编译 Boost =====
RUN tar xzf /tmp/boost_1_86_0.tar.gz && \
    cd boost_1_86_0 && \
    ./bootstrap.sh --with-toolset=clang && \
    echo "using clang : android : ${TOOLCHAIN}/bin/aarch64-linux-android24-clang++ : <archiver>${TOOLCHAIN}/bin/llvm-ar <ranlib>${TOOLCHAIN}/bin/llvm-ranlib <linkflags>-llog <compileflags>--target=aarch64-linux-android24 <compileflags>-fPIC ;" > user-config.jam && \
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
RUN cd /build/libtorrent-src && mkdir build && cd build && \
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
        -Dencryption=ON && \
    cmake --build . -j$(nproc) && cmake --install .

# ===== 编译 qBittorrent =====
# Qt5 预编译路径 (7z解压后有嵌套目录)
ENV QT5_ANDROID=/opt/qt5-prebuilt/5.15.2/android/5.15.2/android

# 补丁: 让 CMakeLists.txt 支持预编译翻译文件 (无 LinguistTools 时)
RUN python3 -c "
import re
f = '/build/qbittorrent-src/src/app/CMakeLists.txt'
t = open(f).read()
# Patch: add elseif branch for pre-compiled translations
old1 = '''if (QBT_QM_FILES)
    target_sources(qbt_app PRIVATE
        \${QBT_QM_FILES}
        \"\${qBittorrent_BINARY_DIR}/src/lang/lang.qrc\"
    )
endif()'''
new1 = '''if (QBT_QM_FILES)
    target_sources(qbt_app PRIVATE
        \${QBT_QM_FILES}
        \"\${qBittorrent_BINARY_DIR}/src/lang/lang.qrc\"
    )
elseif (EXISTS \"\${qBittorrent_BINARY_DIR}/src/lang/lang.qrc\")
    file(GLOB _PRECOMPILED_QM \"\${qBittorrent_BINARY_DIR}/src/lang/*.qm\")
    target_sources(qbt_app PRIVATE
        \${_PRECOMPILED_QM}
        \"\${qBittorrent_BINARY_DIR}/src/lang/lang.qrc\"
    )
endif()'''
old2 = '''if (QBT_WEBUI_QM_FILES)
        target_sources(qbt_app PRIVATE
            \${QBT_WEBUI_QM_FILES}
            \${qBittorrent_BINARY_DIR}/src/webui/www/translations/webui_translations.qrc
        )
    endif()'''
new2 = '''if (QBT_WEBUI_QM_FILES)
        target_sources(qbt_app PRIVATE
            \${QBT_WEBUI_QM_FILES}
            \${qBittorrent_BINARY_DIR}/src/webui/www/translations/webui_translations.qrc
        )
    elseif (EXISTS \"\${qBittorrent_BINARY_DIR}/src/webui/www/translations/webui_translations.qrc\")
        file(GLOB _PRECOMPILED_WEBUI_QM \"\${qBittorrent_BINARY_DIR}/src/webui/www/translations/*.qm\")
        target_sources(qbt_app PRIVATE
            \${_PRECOMPILED_WEBUI_QM}
            \${qBittorrent_BINARY_DIR}/src/webui/www/translations/webui_translations.qrc
        )
    endif()'''
t = t.replace(old1, new1).replace(old2, new2)
open(f, 'w').write(t)
print('CMakeLists.txt patched')
"

# 预编译翻译文件 (在 cmake configure 之前，以便 cmake 能找到 .qrc)
RUN SRC=/build/qbittorrent-src && \
    BUILD=/build/qbittorrent-src/build && \
    mkdir -p ${BUILD}/src/lang ${BUILD}/src/webui/www/translations && \
    echo "=== Compiling app translations ===" && \
    for ts in ${SRC}/src/lang/*.ts; do \
        base=$(basename "$ts" .ts) && \
        lrelease "$ts" -qm "${BUILD}/src/lang/${base}.qm" 2>/dev/null; \
    done && \
    echo "=== Compiling WebUI translations ===" && \
    for ts in ${SRC}/src/webui/www/translations/*.ts; do \
        base=$(basename "$ts" .ts) && \
        lrelease "$ts" -qm "${BUILD}/src/webui/www/translations/${base}.qm" 2>/dev/null; \
    done && \
    echo "=== Generating QRC files ===" && \
    echo '<RCC><qresource prefix="/lang">' > ${BUILD}/src/lang/lang.qrc && \
    for qm in ${BUILD}/src/lang/*.qm; do \
        echo "    <file>$(basename $qm)</file>" >> ${BUILD}/src/lang/lang.qrc; \
    done && \
    echo '</qresource></RCC>' >> ${BUILD}/src/lang/lang.qrc && \
    echo '<RCC><qresource prefix="/www/translations">' > ${BUILD}/src/webui/www/translations/webui_translations.qrc && \
    for qm in ${BUILD}/src/webui/www/translations/*.qm; do \
        echo "    <file>$(basename $qm)</file>" >> ${BUILD}/src/webui/www/translations/webui_translations.qrc; \
    done && \
    echo '</qresource></RCC>' >> ${BUILD}/src/webui/www/translations/webui_translations.qrc && \
    echo "=== Translation files ready ===" && \
    ls ${BUILD}/src/lang/*.qm | wc -l && echo " app .qm files" && \
    ls ${BUILD}/src/webui/www/translations/*.qm | wc -l && echo " webui .qm files"

RUN cd /build/qbittorrent-src && mkdir -p build && cd build && \
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
        -DLibtorrentRasterbar_DIR=${PREFIX}/lib/cmake/LibtorrentRasterbar && \
    cmake --build . -j$(nproc) && cmake --install .

# ===== 收集产物 =====
RUN mkdir -p /output/lib && \
    cp ${PREFIX}/bin/qbittorrent-nox /output/ && \
    cp ${PREFIX}/lib/*.so /output/lib/ 2>/dev/null; \
    cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/ 2>/dev/null; \
    ${STRIP} /output/qbittorrent-nox 2>/dev/null; true

CMD ["echo", "Build complete. Copy /output/qbittorrent-nox"]
