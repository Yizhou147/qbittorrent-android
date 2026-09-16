#!/bin/bash
set -e

CC=/opt/android-sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang
CXX=/opt/android-sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang++
QT5=/opt/qt5-prebuilt/5.15.2/android
NDK_SYSROOT=/opt/android-sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/24

echo '#include <stdio.h>
int main() { printf("Hello ARM64!\n"); return 0; }' > /tmp/test.c
${CC} -o /out/libtest_hello.so /tmp/test.c -pie

echo '#include <iostream>
int main() { std::cout << "Hello C++ ARM64!" << std::endl; return 0; }' > /tmp/test.cpp
${CXX} -o /out/libtest_cpp.so /tmp/test.cpp -pie

cat > /tmp/test_qt.cpp << 'QTCEOF'
#include <QCoreApplication>
#include <QDebug>
int main(int argc, char *argv[]) {
    QCoreApplication app(argc, argv);
    qDebug() << "Qt5 works on Android!";
    return 0;
}
QTCEOF
${CXX} -o /out/libtest_qt.so /tmp/test_qt.cpp -pie \
    -I${QT5}/include -I${QT5}/include/QtCore \
    -L${QT5}/lib -lQt5Core_arm64-v8a \
    -L${NDK_SYSROOT} -lc++_shared

echo "=== Test binaries ==="
ls -la /out/libtest_*
echo "DONE"
