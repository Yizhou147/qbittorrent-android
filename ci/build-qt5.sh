#!/bin/bash
# 从源码编译 qtbase 5.15.2 for Android arm64 (v1.1 已验证的 JNI 补丁配方)
#
# 必须从源码重编的原因: 预编译 Qt 的 JNI_OnLoad 会 RegisterNatives 并在运行期
# 触发依赖 Activity 上下文的 JNI 调用, 在本项目的非 Qt-Activity 进程里会崩溃。
# 补丁后: 最小化 JNI_OnLoad (仅设置 JavaVM) + qjni.cpp 空指针守卫,
# Qt 的 Android 集成安全惰性化 (qBittorrent nox 用不到 Activity 相关能力)。
set -eo pipefail

export ANDROID_NDK=/opt/android-sdk/ndk/27.0.12077973
export QT_INSTALL=/opt/qt5-custom
export PREFIX=/opt/qbt-output
export TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64

echo "===== 下载 qtbase 5.15.2 源码 ====="
cd /build
if [ ! -d qtbase-everywhere-src-5.15.2 ]; then
    curl -L --retry 3 -o /tmp/qtbase5.tar.xz \
        "https://download.qt.io/archive/qt/5.15/5.15.2/submodules/qtbase-everywhere-src-5.15.2.tar.xz"
    tar xf /tmp/qtbase5.tar.xz -C /build/
fi
cd /build/qtbase-everywhere-src-5.15.2

echo "===== 补丁 1: qjni.cpp NULL javaVM 守卫 ====="
JNI_FILE="src/corelib/kernel/qjni.cpp"
sed -i 's/        QtAndroidPrivate::javaVM()->DetachCurrentThread();/        if (QtAndroidPrivate::javaVM()) QtAndroidPrivate::javaVM()->DetachCurrentThread();/' "$JNI_FILE"
python3 - << 'PYEOF'
with open('/build/qtbase-everywhere-src-5.15.2/src/corelib/kernel/qjni.cpp') as f:
    c = f.read()
old = 'JavaVM *vm = QtAndroidPrivate::javaVM();\n    const jint ret = vm->GetEnv'
new = 'JavaVM *vm = QtAndroidPrivate::javaVM();\n    if (!vm) return;\n    const jint ret = vm->GetEnv'
assert old in c, "qjni.cpp constructor pattern not found"
c = c.replace(old, new)
with open('/build/qtbase-everywhere-src-5.15.2/src/corelib/kernel/qjni.cpp', 'w') as f:
    f.write(c)
print("qjni.cpp patched")
PYEOF

echo "===== 补丁 2: 禁用 android 相关文件的 JNI_OnLoad ====="
while IFS= read -r f; do
    if grep -q "JNI_OnLoad" "$f" 2>/dev/null; then
        echo "  rename: $f"
        sed -i 's/JNI_OnLoad/JNI_OnLoad_Disabled/g' "$f"
    fi
done < <(find . -name "androidjnimain.cpp" -o -name "qjni*.cpp" -o -path "*android*" -name "*.cpp")

echo "===== 补丁 3: qjnihelpers.cpp 添加最小 JNI_OnLoad (仅设置 JavaVM) ====="
sed -i '/^JavaVM \*QtAndroidPrivate::javaVM()/i\
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void * /*reserved*/)\
{\
    g_javaVM = vm;\
    return JNI_VERSION_1_6;\
}\
' src/corelib/kernel/qjnihelpers.cpp
grep -n "JNI_OnLoad" src/corelib/kernel/qjnihelpers.cpp | head -3

echo "===== 补丁 4: qlogging.cpp Android 下禁用 execinfo ====="
sed -i 's/__has_include(<execinfo.h>)/(__has_include(<execinfo.h>) \&\& !defined(Q_OS_ANDROID))/' \
    src/corelib/global/qlogging.cpp 2>/dev/null || true

echo "===== 补丁 5: 新版 clang/libstdc++ 需要 <limits> ====="
# v1.1 配方: 只处理使用 std::numeric_limits 的文件, 插到第一个 #include 之前;
# 跳过 qcompilerdetection.h (bootstrap 阶段特殊编译, 加了会 'limits' file not found)
grep -rl "std::numeric_limits" src/ 2>/dev/null | while IFS= read -r f; do
    case "$f" in *qcompilerdetection.h) continue ;; esac
    if ! grep -q '#include <limits>' "$f"; then
        sed -i '0,/#include/s//#include <limits>\n&/' "$f"
        echo "  limits: $f"
    fi
done

echo "===== 补丁 5b: android/default_pre.prf 的 ranlib 用 llvm-ranlib ====="
# NDK r27 无 aarch64-linux-android-ranlib; 该 prf 在 qmake.conf 之后加载, 必须在此处覆盖
sed -i 's|QMAKE_RANLIB            = $${CROSS_COMPILE}ranlib|QMAKE_RANLIB            = $$NDK_LLVM_PATH/bin/llvm-ranlib|' \
    mkspecs/features/android/default_pre.prf
grep -n "QMAKE_RANLIB" mkspecs/features/android/default_pre.prf

echo "===== 补丁 6: mkspecs 注入静态 OpenSSL 路径 ====="
cat >> mkspecs/android-clang/qmake.conf << EOF

# NDK r27 无 GCC 时代工具链包装器, ranlib 用 llvm-ranlib
QMAKE_RANLIB = $$NDK_LLVM_PATH/bin/llvm-ranlib
# OpenSSL (static) for cross-compilation
QMAKE_INCDIR += ${PREFIX}/include
QMAKE_LIBDIR += ${PREFIX}/lib
OPENSSL_INCDIR = ${PREFIX}/include
OPENSSL_LIBDIR = ${PREFIX}/lib
OPENSSL_LIBS = -L${PREFIX}/lib -lssl -lcrypto -ldl
EOF

echo "===== openssl 链接自检 (诊断) ====="
cat > /tmp/ossltest.cpp << 'EOFCPP'
#include <openssl/ssl.h>
#include <openssl/opensslv.h>
int main() { SSL_free(nullptr); return OPENSSL_VERSION_NUMBER > 0 ? 0 : 1; }
EOFCPP
if ${TOOLCHAIN}/bin/aarch64-linux-android24-clang++ /tmp/ossltest.cpp \
    -I${PREFIX}/include -L${PREFIX}/lib -lssl -lcrypto -ldl -o /tmp/ossltest 2>/tmp/ossltest.err; then
    echo "openssl 手动链接 OK"
else
    echo "openssl 手动链接失败:"
    head -20 /tmp/ossltest.err
fi

echo "===== openssl ABI 后缀别名 (qt5 android 链接 -lssl_arm64-v8a) ====="
ln -sf libssl.so.3 ${PREFIX}/lib/libssl_arm64-v8a.so
ln -sf libcrypto.so.3 ${PREFIX}/lib/libcrypto_arm64-v8a.so
ls -la ${PREFIX}/lib/ | grep -E "ssl|crypto"

echo "===== 配置 Qt5 ====="
# qt5 configure 的 openssl 探测测试读取 OPENSSL_LIBS 环境变量
export OPENSSL_LIBS="-L${PREFIX}/lib -lssl -lcrypto -ldl"
mkdir -p /build/qt5-build && cd /build/qt5-build
../qtbase-everywhere-src-5.15.2/configure \
    -prefix ${QT_INSTALL} \
    -platform linux-clang \
    -xplatform android-clang \
    -android-ndk ${ANDROID_NDK} \
    -android-sdk /opt/android-sdk \
    -android-arch arm64-v8a \
    -no-gui -no-widgets -no-dbus -no-accessibility \
    -no-opengl -no-vulkan \
    -openssl-linked \
    -no-libjpeg -no-libpng -no-harfbuzz -no-freetype \
    -no-glib -no-mtdev -no-evdev -no-tslib -no-icu -no-cups -no-pch \
    -nomake tests -nomake examples \
    -opensource -confirm-license \
    -c++std c++17 \
    -shared 2>&1 | tail -60

echo "===== 编译 Qt5 (约 20-40 分钟) ====="
if ! make -j$(nproc) > /tmp/qt5-make.log 2>&1; then
    echo "===== Qt5 编译失败, 每个 make Error 的上下文 ====="
    grep -B8 -E "Error [0-9]+" /tmp/qt5-make.log | head -120 || true
    echo "===== error:/not found 行 ====="
    grep -E "error:|not found" /tmp/qt5-make.log | head -20 || true
    echo "===== make 日志最后 40 行 ====="
    tail -40 /tmp/qt5-make.log || true
    exit 1
fi
make install

echo "===== 产物 ====="
ls -la ${QT_INSTALL}/lib/libQt5*.so
