# Parameterized cross-compilation of qBittorrent for Android (arm64-v8a).
#
# Source trees must be present before build:
#   docker-sources/libtorrent/     libtorrent source (vanilla release)
#   docker-sources/qbittorrent/    qBittorrent source (vanilla release, patched by ci/apply-patches.sh)
#   docker-sources/openssl-3.3.2.tar.gz
#   docker-sources/<boost tarball> (name passed via BOOST_TARBALL build-arg)
#   docker-sources/platform-34-ext7_r02.zip, build-tools_r34-linux.zip, android-ndk-r27b-linux.zip
#
# Build-args select the variant, e.g.:
#   qb 4.6.7: --build-arg QT_KIND=qt5 --build-arg QT_VERSION=5.15.2 --build-arg CXX_STANDARD=17
#   qb 5.2.3: --build-arg QT_KIND=qt6 --build-arg QT_VERSION=6.6.3 --build-arg CXX_STANDARD=20
#             --build-arg EXTRA_CMAKE_FLAGS=-DSTACKTRACE=OFF
FROM ubuntu:22.04

ARG QT_KIND=qt5
ARG QT_VERSION=5.15.2
ARG CXX_STANDARD=17
ARG BOOST_TARBALL=boost_1_86_0.tar.gz
ARG EXTRA_CMAKE_FLAGS=""
# libtorrent 编译追加的 C++ flags (如降级 narrowing 错误为警告)
ARG EXTRA_LT_CXXFLAGS=""

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_NDK=${ANDROID_HOME}/ndk/27.0.12077973
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PREFIX=/opt/qbt-output
ENV TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64

# OpenSSL/Boost are compiled against android-24. libtorrent and qBittorrent are
# compiled against android-35 below: NDK r27 gives only 8-byte TLS alignment at
# API 24, while Android 16's linker requires >= 64 bytes.
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
# lrelease (host) pre-compiles .ts translations because the Android Qt packages
# ship no LinguistTools: qt5 -> qttools5-dev-tools, qt6 -> qt6-l10n-tools.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl wget unzip tar p7zip-full python3 python3-pip \
    build-essential cmake ninja-build pkg-config \
    clang perl \
    openjdk-17-jdk-headless \
    qttools5-dev-tools \
    qt6-l10n-tools \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir aqtinstall

# ===== 复制本地源码包 =====
COPY docker-sources/openssl-3.3.2.tar.gz /tmp/
COPY docker-sources/${BOOST_TARBALL} /tmp/
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

# ===== 编译 OpenSSL =====
WORKDIR /build
RUN tar xzf /tmp/openssl-3.3.2.tar.gz && \
    cd openssl-3.3.2 && \
    export ANDROID_NDK_ROOT=${ANDROID_NDK} && \
    export PATH=${TOOLCHAIN}/bin:${PATH} && \
    # shared: Qt 需要链接 libssl.so/libcrypto.so (qb 4.x 的 WebUI SSL 字段
    # 无条件使用 QSslKey); 同时生成静态 .a 供 libtorrent 链接
    ./Configure android-arm64 -D__ANDROID_API__=35 \
        --prefix=${PREFIX} --openssldir=${PREFIX}/ssl \
        shared no-tests no-ui-console -fPIC && \
    make -j$(nproc) build_libs && make install_sw

# ===== Qt 安装 =====
# qt5: 源码重编 qtbase 5.15.2 (v1.1 已验证的 JNI 补丁配方, 见 ci/build-qt5.sh)
# qt6: 源码重编 qtbase 6.6.3 for android (需 aqt 宿主 Qt6 提供 QT_HOST_PATH)
# 产物: /opt/qt5-custom 或 /opt/qt6-custom, 库命名 libQt{5,6}*.so (收集时改名)
COPY ci/build-qt5.sh ci/build-qt6.sh /tmp/
RUN if [ "$QT_KIND" = "qt6" ]; then \
        aqt_ok=0; \
        for i in 1 2 3 4; do \
            aqt install-qt linux desktop ${QT_VERSION} gcc_64 -O /opt/qt-host && aqt_ok=1 && break; \
            echo "aqt retry $i"; sleep 15; \
        done; \
        [ "$aqt_ok" = "1" ] && echo "/opt/qt-host/${QT_VERSION}/gcc_64" > /tmp/qt_host_path; \
    else \
        echo "" > /tmp/qt_host_path; \
    fi

RUN if [ "$QT_KIND" = "qt6" ]; then \
        bash /tmp/build-qt6.sh; \
    else \
        bash /tmp/build-qt5.sh; \
    fi && \
    if [ "$QT_KIND" = "qt6" ]; then \
        QT_CMAKE_DIR=/opt/qt6-custom/lib/cmake/Qt6; \
        QT_CUSTOM=/opt/qt6-custom; \
        LRELEASE=/usr/lib/qt6/bin/lrelease; \
    else \
        QT_CMAKE_DIR=/opt/qt5-custom/lib/cmake/Qt5; \
        QT_CUSTOM=/opt/qt5-custom; \
        LRELEASE=/usr/lib/qt5/bin/lrelease; \
    fi && \
    echo "QT_CMAKE_DIR=${QT_CMAKE_DIR}" && test -d "${QT_CMAKE_DIR}" && \
    echo "LRELEASE=${LRELEASE}" && test -x "${LRELEASE}" && \
    echo "${QT_CMAKE_DIR}" > /tmp/qt_cmake_dir && \
    echo "${LRELEASE}" > /tmp/lrelease_path && \
    echo "${QT_CUSTOM}" > /tmp/qt_custom


# ===== 编译 Boost =====
RUN tar xzf /tmp/${BOOST_TARBALL} && \
    cd $(basename ${BOOST_TARBALL} .tar.gz) && \
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

# ===== 编译 libtorrent (API 35 target, 见文件头说明) =====
RUN export API=35 && \
    export CC=${TOOLCHAIN}/bin/aarch64-linux-android${API}-clang && \
    export CXX=${TOOLCHAIN}/bin/aarch64-linux-android${API}-clang++ && \
    cd /build/libtorrent-src && mkdir build && cd build && \
    cmake .. \
        -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK}/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-${API} \
        -DANDROID_STL=c++_shared \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=${CXX_STANDARD} \
        -DCMAKE_CXX_FLAGS="${EXTRA_LT_CXXFLAGS}" \
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

# ===== 预编译翻译文件 (在 cmake configure 之前，以便 cmake 能找到 .qrc) =====
RUN SRC=/build/qbittorrent-src && \
    BUILD=/build/qbittorrent-src/build && \
    LRELEASE=$(cat /tmp/lrelease_path) && \
    mkdir -p ${BUILD}/src/lang ${BUILD}/src/webui/www/translations && \
    echo "=== Compiling app translations ===" && \
    for ts in ${SRC}/src/lang/*.ts; do \
        base=$(basename "$ts" .ts) && \
        ${LRELEASE} "$ts" -qm "${BUILD}/src/lang/${base}.qm" 2>/dev/null; \
    done && \
    echo "=== Compiling WebUI translations ===" && \
    for ts in ${SRC}/src/webui/www/translations/*.ts; do \
        base=$(basename "$ts" .ts) && \
        ${LRELEASE} "$ts" -qm "${BUILD}/src/webui/www/translations/${base}.qm" 2>/dev/null; \
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

# ===== 编译 qBittorrent (API 35 target, 共享库 libqbt.so + JNI 桥接) =====
RUN export API=35 && \
    export CC=${TOOLCHAIN}/bin/aarch64-linux-android${API}-clang && \
    export CXX=${TOOLCHAIN}/bin/aarch64-linux-android${API}-clang++ && \
    QT_CMAKE_DIR=$(cat /tmp/qt_cmake_dir) && \
    QT_ROOT=$(dirname $(dirname $(dirname ${QT_CMAKE_DIR}))) && \
    QT_HOST_PATH=$(cat /tmp/qt_host_path) && \
    QT_MAJOR=$(echo $QT_KIND | sed 's/qt//') && \
    cd /build/qbittorrent-src && mkdir -p build && cd build && \
    cmake .. \
        -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK}/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-${API} \
        -DANDROID_STL=c++_shared \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=${CXX_STANDARD} \
        -DCMAKE_FIND_ROOT_PATH="${PREFIX};${QT_ROOT}" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
        -DQt${QT_MAJOR}_DIR=${QT_CMAKE_DIR} \
        ${QT_HOST_PATH:+-DQT_HOST_PATH=${QT_HOST_PATH}} \
        -DGUI=OFF \
        -DWEBUI=ON \
        -DTESTING=OFF \
        ${EXTRA_CMAKE_FLAGS} \
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

# ===== 收集产物 (含 Qt 库和 sqlite 插件，供 APK jniLibs 使用) =====
# 只打包 qbittorrent-nox 需要的 Qt 模块; 自定义编译产物名为 libQt*.so,
# 统一改名为 *_arm64-v8a.so (与 v1.1 命名一致, Java 层扫描加载)
RUN QT_CUSTOM=$(cat /tmp/qt_custom) && \
    mkdir -p ${PREFIX}/lib && \
    for m in Core Network Sql Xml; do \
        cp ${QT_CUSTOM}/lib/libQt*${m}.so ${PREFIX}/lib/; \
    done && \
    for f in ${PREFIX}/lib/libQt*.so; do \
        case "$f" in \
            *_arm64-v8a.so) ;; \
            *) mv "$f" "${f%.so}_arm64-v8a.so" ;; \
        esac; \
    done && \
    if [ -f "${QT_CUSTOM}/plugins/sqldrivers/libqsqlite.so" ]; then \
        cp ${QT_CUSTOM}/plugins/sqldrivers/libqsqlite.so ${PREFIX}/lib/libplugins_sqldrivers_qsqlite_arm64-v8a.so; \
    fi && \
    mkdir -p /output/lib && \
    cp ${PREFIX}/bin/qbittorrent-nox /output/ 2>/dev/null; \
    cp ${PREFIX}/lib/*.so /output/lib/ && \
    cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/ 2>/dev/null; \
    # OpenSSL 动态库 (QtNetwork 链接): 按 soname 命名打包
    for so in ${PREFIX}/lib/libssl.so.* ${PREFIX}/lib/libcrypto.so.*; do \
        case "$so" in *\*.*) cp "$so" /output/lib/ ;; esac; \
    done; \
    ${STRIP} /output/lib/libqbt*.so /output/lib/libtorrent-rasterbar.so /output/lib/libQt*.so 2>/dev/null; \
    ls -lh /output/lib/

CMD ["echo", "Build complete. Copy /output/lib"]
