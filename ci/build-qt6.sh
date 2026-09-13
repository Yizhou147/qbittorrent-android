#!/bin/bash
# 从源码编译 qtbase 6.6.3 for Android arm64 (与 qt5 相同思路的 JNI 补丁)
#
# qt6 需要: 宿主 Qt6 (QT_HOST_PATH, 由 Dockerfile 用 aqt 装好) + NDK r27。
#
# 补丁集 (为什么需要, 见 README "Qt6 JNI 崩溃" 记录):
# 1. JNI_OnLoad 最小化 (仅设置 JavaVM) + 缓存 app 的 ClassLoader 到 g_jClassLoader。
#    原本 Qt 自己从 org.qtproject.qt.android.QtNative 取 ClassLoader, 而本 APK 不含
#    该 Java 类; 不缓存的话 QJniObject::loadClass() 对任何类名都返回 null (连
#    android/os/Environment 这类系统类也拿不到), 后续 JNI 调用会崩。
# 2. qjniobject.cpp: getMethodID/getFieldID 加 null clazz 守卫。
#    Qt6 把 Android 实现改写成了类型化模板 callStaticMethod<T>, 它不再判空; 旧版 Qt5
#    的 varargs API 有判空, 所以同样的类解析空洞 Qt5 能忍、Qt6 一碰就被 ART abort
#    (JNI DETECTED ERROR: java_class == null, in call to GetStaticMethodID)。
# 3. qjnienvironment.cpp: NULL javaVM 守卫。
set -eo pipefail

export ANDROID_NDK=/opt/android-sdk/ndk/27.0.12077973
export QT_INSTALL=/opt/qt6-custom
export TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=${JAVA_HOME}/bin:${TOOLCHAIN}/bin:${PATH}
HOST_QT=$(cat /tmp/qt_host_path)

echo "===== 下载 qtbase 6.6.3 源码 ====="
cd /build
if [ ! -d qtbase-everywhere-src-6.6.3 ]; then
    curl -L --retry 3 -o /tmp/qtbase6.tar.xz \
        "https://download.qt.io/archive/qt/6.6/6.6.3/submodules/qtbase-everywhere-src-6.6.3.tar.xz"
    tar xf /tmp/qtbase6.tar.xz -C /build/
fi
cd /build/qtbase-everywhere-src-6.6.3

echo "===== 补丁 1: qjnihelpers.cpp JNI_OnLoad 最小化 + 缓存 app ClassLoader ====="
python3 - << 'PYEOF'
path = '/build/qtbase-everywhere-src-6.6.3/src/corelib/kernel/qjnihelpers.cpp'
with open(path) as f:
    c = f.read()

assert 'static jobject g_jClassLoader' in c, "g_jClassLoader declaration not found"
if '#include <android/log.h>' not in c:
    c = '#include <android/log.h>\n' + c

start = c.index('JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved)')
end = c.index('}', c.rindex('return JNI_VERSION_1_6;', start)) + 1
# 保留原版里唯一安全的动作 (设置 JavaVM), 丢掉依赖 Activity 的 RegisterNatives;
# 另外把 app 的 ClassLoader 缓存进 g_jClassLoader —— QJniObject::loadClass() 解析
# 任何按类名的查找都只经过 QtAndroidPrivate::classLoader() (即 g_jClassLoader),
# 它原本只在原版 JNI_OnLoad 里从 org.qtproject.qt.android.QtNative 取值, 而本 APK
# 不含那个 Java 类。这里改从加载本库的 app 类取 (JNI_OnLoad 在 Java 线程里被
# System.loadLibrary 触发, FindClass 用的就是 app 的 ClassLoader)。
minimal = '''JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved)
{
    Q_UNUSED(reserved);
    g_javaVM = vm;

    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) == JNI_OK) {
        jclass appClass = env->FindClass("com/qbittorrent/android/QBittorrentService");
        if (env->ExceptionCheck())
            env->ExceptionClear();
        jclass classClass = env->FindClass("java/lang/Class");
        if (env->ExceptionCheck())
            env->ExceptionClear();
        if (appClass && classClass) {
            const jmethodID getClassLoader = env->GetMethodID(classClass, "getClassLoader",
                                                             "()Ljava/lang/ClassLoader;");
            if (env->ExceptionCheck())
                env->ExceptionClear();
            if (getClassLoader) {
                const jobject classLoader = env->CallObjectMethod(appClass, getClassLoader);
                if (env->ExceptionCheck())
                    env->ExceptionClear();
                if (classLoader)
                    g_jClassLoader = env->NewGlobalRef(classLoader);
            }
        }
        if (!g_jClassLoader) {
            jclass clClass = env->FindClass("java/lang/ClassLoader");
            if (env->ExceptionCheck())
                env->ExceptionClear();
            if (clClass) {
                const jmethodID getSystemClassLoader = env->GetStaticMethodID(
                        clClass, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
                if (env->ExceptionCheck())
                    env->ExceptionClear();
                if (getSystemClassLoader) {
                    const jobject classLoader = env->CallStaticObjectMethod(clClass, getSystemClassLoader);
                    if (env->ExceptionCheck())
                        env->ExceptionClear();
                    if (classLoader)
                        g_jClassLoader = env->NewGlobalRef(classLoader);
                }
            }
        }
        __android_log_print(ANDROID_LOG_INFO, "QtJNI",
                            "JNI_OnLoad: classLoader=%s", g_jClassLoader ? "ok" : "NULL");
    }

    return JNI_VERSION_1_6;
}'''
c = c[:start] + minimal + c[end:]
with open(path, 'w') as f:
    f.write(c)
print("qjnihelpers.cpp JNI_OnLoad minimized + classLoader cached")
PYEOF
grep -n "classLoader=%s\|g_jClassLoader = env->NewGlobalRef" src/corelib/kernel/qjnihelpers.cpp

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

echo "===== 补丁 3: qjniobject.cpp NULL jclass 守卫 (getMethodID/getFieldID) ====="
python3 - << 'PYEOF'
path = '/build/qtbase-everywhere-src-6.6.3/src/corelib/kernel/qjniobject.cpp'
with open(path) as f:
    c = f.read()

# clazz 为 null 表示按类名解析失败 (本进程没有 Qt 的 Java 类, ClassLoader 也可能缺失)。
# 把 null jclass 交给 JNI 会被 ART 判为致命错误 (java_class == null) 并 abort, 无法
# catch; 这里退化为"没有这个成员", 即 Qt5 老 varargs API 的容错语义。
guard = ('    // A null clazz means the class could not be resolved; passing it to JNI\n'
         '    // is a fatal error on ART, so degrade to "no such member".\n'
         '    if (!clazz)\n'
         '        return nullptr;\n\n')

for anchor in ('    jmethodID id = isStatic ? env->GetStaticMethodID(clazz, name, signature)',
               '    jfieldID id = isStatic ? env->GetStaticFieldID(clazz, name, signature)'):
    assert c.count(anchor) == 1, f"anchor not unique/found: {anchor}"
    c = c.replace(anchor, guard + anchor)

with open(path, 'w') as f:
    f.write(c)
print("qjniobject.cpp getMethodID/getFieldID guarded")
PYEOF
grep -n -B1 -A2 "if (!clazz)" src/corelib/kernel/qjniobject.cpp | head -12
grep -c "return nullptr;" src/corelib/kernel/qjniobject.cpp

echo "===== 配置 Qt6 ====="
mkdir -p /build/qt6-build && cd /build/qt6-build
../qtbase-everywhere-src-6.6.3/configure \
    -prefix ${QT_INSTALL} \
    -android-ndk ${ANDROID_NDK} \
    -android-sdk /opt/android-sdk \
    -android-abis arm64-v8a \
    -qt-host-path ${HOST_QT} \
    -nomake examples -nomake tests \
    -no-gui -no-widgets -no-dbus -no-opengl -no-vulkan \
    -openssl-linked \
    -shared \
    -- -DOPENSSL_ROOT_DIR=${PREFIX} 2>&1 | tail -60

echo "===== 编译 Qt6 (约 40-60 分钟) ====="
if ! cmake --build . -j$(nproc) > /tmp/qt6-make.log 2>&1; then
    echo "===== Qt6 编译失败, 错误摘要 ====="
    grep -E "error:|ninja: build stopped" /tmp/qt6-make.log | head -30 || true
    echo "===== 最后 80 行 ====="
    tail -80 /tmp/qt6-make.log
    exit 1
fi
cmake --install .

echo "===== 产物 ====="
ls -la ${QT_INSTALL}/lib/libQt6*.so
