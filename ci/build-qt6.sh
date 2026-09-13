#!/bin/bash
# 从源码编译 qtbase 6.6.3 for Android arm64 (与 qt5 相同思路的 JNI 补丁)
#
# qt6 需要: 宿主 Qt6 (QT_HOST_PATH, 由 Dockerfile 用 aqt 装好) + NDK r27。
# 补丁后 JNI_OnLoad 仅设置 JavaVM, 运行期 JNI 空指针有守卫, Android 集成惰性化。
set -eo pipefail

export ANDROID_NDK=/opt/android-sdk/ndk/27.0.12077973
export QT_INSTALL=/opt/qt6-custom
export TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64
HOST_QT=$(cat /tmp/qt_host_path)

echo "===== 下载 qtbase 6.6.3 源码 ====="
cd /build
if [ ! -d qtbase-everywhere-src-6.6.3 ]; then
    curl -L --retry 3 -o /tmp/qtbase6.tar.xz \
        "https://download.qt.io/archive/qt/6.6/6.6.3/submodules/qtbase-everywhere-src-6.6.3.tar.xz"
    tar xf /tmp/qtbase6.tar.xz -C /build/
fi
cd /build/qtbase-everywhere-src-6.6.3

echo "===== 补丁 1: qjnihelpers.cpp JNI_OnLoad 最小化 (仅设置 JavaVM) ====="
python3 - << 'PYEOF'
path = '/build/qtbase-everywhere-src-6.6.3/src/corelib/kernel/qjnihelpers.cpp'
with open(path) as f:
    c = f.read()

start = c.index('JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved)')
end = c.index('}', c.rindex('return JNI_VERSION_1_6;', start)) + 1
minimal = '''JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved)
{
    Q_UNUSED(reserved);
    QtAndroidPrivate::setJavaVM(vm);
    return JNI_VERSION_1_6;
}'''
c = c[:start] + minimal + c[end:]
with open(path, 'w') as f:
    f.write(c)
print("qjnihelpers.cpp JNI_OnLoad minimized")
PYEOF
grep -n -A5 "JNIEXPORT jint JNICALL JNI_OnLoad" src/corelib/kernel/qjnihelpers.cpp | head -8

echo "===== 补丁 2: qjnienvironment.cpp NULL javaVM 守卫 ====="
sed -i 's/        QtAndroidPrivate::javaVM()->DetachCurrentThread();/        if (QtAndroidPrivate::javaVM()) QtAndroidPrivate::javaVM()->DetachCurrentThread();/' \
    src/corelib/kernel/qjnienvironment.cpp
python3 - << 'PYEOF'
path = '/build/qtbase-everywhere-src-6.6.3/src/corelib/kernel/qjnienvironment.cpp'
with open(path) as f:
    c = f.read()
old = 'JavaVM *vm = QtAndroidPrivate::javaVM();\n    const jint ret = vm->GetEnv'
new = 'JavaVM *vm = QtAndroidPrivate::javaVM();\n    if (!vm) return;\n    const jint ret = vm->GetEnv'
assert old in c, "qnienvironment constructor pattern not found"
c = c.replace(old, new)
with open(path, 'w') as f:
    f.write(c)
print("qnienvironment.cpp patched")
PYEOF

echo "===== 配置 Qt6 ====="
mkdir -p /build/qt6-build && cd /build/qt6-build
../qtbase-everywhere-src-6.6.3/configure \
    -prefix ${QT_INSTALL} \
    -platform linux \
    -android-ndk ${ANDROID_NDK} \
    -android-sdk /opt/android-sdk \
    -android-arch arm64-v8a \
    -qt-host-path ${HOST_QT} \
    -nomake examples -nomake tests \
    -no-gui -no-widgets -no-dbus -no-opengl -no-vulkan \
    -no-openssl \
    -shared 2>&1 | tail -30

echo "===== 编译 Qt6 (约 40-60 分钟) ====="
cmake --build . -j$(nproc) 2>&1 | tail -10
cmake --install .

echo "===== 产物 ====="
ls -la ${QT_INSTALL}/lib/libQt6*.so
