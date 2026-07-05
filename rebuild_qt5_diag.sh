#!/bin/bash
set -e

NDK=/opt/android-sdk/ndk/27.0.12077973
TOOLCHAIN=${NDK}/toolchains/llvm/prebuilt/linux-x86_64
PREFIX=/opt/qbt-output
QT_INSTALL=/opt/qt5-custom
export PATH=${TOOLCHAIN}/bin:$PATH
export CC=${TOOLCHAIN}/bin/aarch64-linux-android24-clang
export CXX=${TOOLCHAIN}/bin/aarch64-linux-android24-clang++

QT_SRC="/build/qt-everywhere-src-5.15.2"

echo "=== 1. Fix JNI_OnLoad: selective re-enable ==="
for f in $(find ${QT_SRC} -name "androidjnimain.cpp" -o -name "qjnihelpers.cpp" -o -name "qjni*.cpp" 2>/dev/null); do
    sed -i 's/JNI_OnLoad_Disabled/JNI_OnLoad/g' "$f" 2>/dev/null || true
done
for f in $(find ${QT_SRC} -name "androidjnimain.cpp" 2>/dev/null); do
    sed -i 's/JNI_OnLoad/JNI_OnLoad_Disabled/g' "$f" 2>/dev/null || true
done

QJNI_HELPERS=$(find ${QT_SRC} -name "qjnihelpers.cpp" -path "*/android/*" | head -1)
if [ -n "$QJNI_HELPERS" ]; then
    if grep -q 'JNI_OnLoad_Disabled' "$QJNI_HELPERS"; then
        echo "ERROR: qjnihelpers.cpp still has JNI_OnLoad_Disabled!"
        exit 1
    fi
fi

JNI_FILE="${QT_SRC}/qtbase/src/corelib/kernel/qjni.cpp"
python3 -c "
with open('${JNI_FILE}', 'r') as f:
    c = f.read()
c = c.replace(
    'QtAndroidPrivate::javaVM()->DetachCurrentThread();',
    'if (QtAndroidPrivate::javaVM()) QtAndroidPrivate::javaVM()->DetachCurrentThread();'
)
if 'if (!vm) return;' not in c:
    c = c.replace(
        'JavaVM *vm = QtAndroidPrivate::javaVM();\n    const jint ret = vm->GetEnv',
        'JavaVM *vm = QtAndroidPrivate::javaVM();\n    if (!vm) return;\n    const jint ret = vm->GetEnv'
    )
with open('${JNI_FILE}', 'w') as f:
    f.write(c)
print('qjni.cpp NULL checks verified')
"

echo "=== 2. Rebuild OpenSSL as shared ==="
cd /build
rm -rf openssl-3.3.2
tar xzf /build/docker-sources/openssl-3.3.2.tar.gz
cd openssl-3.3.2
./Configure android-arm64 -D__ANDROID_API__=24 \
    --prefix=${PREFIX} --openssldir=${PREFIX}/ssl \
    shared \
    2>&1 | tail -5
make -j4 2>&1 | tail -5
make install_sw 2>&1 | tail -5

echo "=== 3. Rebuild Qt5 ==="
QT_BUILD="/build/qt5-build"
rm -rf ${QT_BUILD} && mkdir -p ${QT_BUILD} && cd ${QT_BUILD}

OPENSSL_LIBS="-lssl -lcrypto -L${PREFIX}/lib" \
OPENSSL_CFLAGS="-I${PREFIX}/include" \
CFLAGS="-I${PREFIX}/include ${CFLAGS:-}" \
CXXFLAGS="-I${PREFIX}/include ${CXXFLAGS:-}" \
../qt-everywhere-src-5.15.2/configure \
    -prefix ${QT_INSTALL} \
    -platform linux-clang \
    -xplatform android-clang \
    -android-ndk ${NDK} \
    -android-sdk /opt/android-sdk \
    -android-arch arm64-v8a \
    -android-ndk-host linux-x86_64 \
    -no-gui -no-widgets -no-dbus -no-accessibility \
    -no-opengl -no-vulkan \
    -openssl-runtime \
    -I ${PREFIX}/include \
    -no-libjpeg -no-libpng -no-harfbuzz -no-freetype \
    -no-glib -no-mtdev -no-evdev -no-tslib -no-icu -no-cups -no-pch \
    -nomake tests -nomake examples \
    -skip qt3d -skip qtactiveqt -skip qtandroidextras \
    -skip qtcharts -skip qtconnectivity -skip qtdatavis3d \
    -skip qtdeclarative -skip qtdoc -skip qtgamepad \
    -skip qtgraphicaleffects -skip qtimageformats -skip qtlocation \
    -skip qtlottie -skip qtmacextras -skip qtmultimedia \
    -skip qtnetworkauth -skip qtpurchasing -skip qtquick3d \
    -skip qtquickcontrols -skip qtquickcontrols2 -skip qtquicktimeline \
    -skip qtremoteobjects -skip qtscript -skip qtscxml \
    -skip qtsensors -skip qtserialbus -skip qtserialport \
    -skip qtspeech -skip qtsvg -skip qttools \
    -skip qttranslations -skip qtvirtualkeyboard -skip qtwayland \
    -skip qtwebchannel -skip qtwebengine -skip qtwebglplugin \
    -skip qtwebsockets -skip qtwebview -skip qtwinextras \
    -skip qtx11extras -skip qtxmlpatterns \
    -opensource -confirm-license \
    -c++std c++17 \
    -shared \
    2>&1 | tail -40

make -j4 2>&1 | tail -10
make install 2>&1 | tail -5

echo "=== 4. Build Qt5 diagnostic program ==="
DIAG_SRC="/build/qt5-diag"
rm -rf ${DIAG_SRC}
mkdir -p ${DIAG_SRC}
cat > ${DIAG_SRC}/qt5_diag.cpp << 'EOF'
#include <QCoreApplication>
#include <QStandardPaths>
#include <QDebug>
#include <cstdlib>

int main(int argc, char *argv[]) {
    QCoreApplication app(argc, argv);
    const char *env = std::getenv("LD_LIBRARY_PATH");
    qDebug() << "LD_LIBRARY_PATH" << (env ? env : "(null)");
    qDebug() << "writableLocation(GenericDataLocation)" << QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    qDebug() << "writableLocation(AppDataLocation)" << QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    qDebug() << "writableLocation(TempLocation)" << QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    qDebug() << "Qt5 diagnostic passed";
    return 0;
}
EOF

${TOOLCHAIN}/bin/aarch64-linux-android24-clang++ \
    --sysroot=${TOOLCHAIN}/sysroot \
    -std=c++17 -DQT_CORE_LIB -I${QT_INSTALL}/include -I${QT_INSTALL}/include/QtCore \
    ${DIAG_SRC}/qt5_diag.cpp \
    -L${QT_INSTALL}/lib \
    -L${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android \
    -L${PREFIX}/lib \
    -lQt5Core_arm64-v8a -lQt5Network_arm64-v8a -lQt5Xml_arm64-v8a \
    -lssl -lcrypto -lz -llog \
    -lc++_shared \
    -o /output/qt5_diag

${TOOLCHAIN}/bin/llvm-strip /output/qt5_diag 2>/dev/null || true
cp ${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /output/lib/

echo "=== Output ==="
ls -lh /output/ /output/lib/
echo "=== DONE ==="
