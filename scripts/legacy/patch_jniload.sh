#!/bin/bash
set -e

FILE=/build/qt-everywhere-src-5.15.2/qtbase/src/corelib/kernel/qjnihelpers.cpp

# Add JNI_OnLoad before javaVM() function
sed -i '/^JavaVM \*QtAndroidPrivate::javaVM()/i\
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void * /*reserved*/)\
{\
    g_javaVM = vm;\
    return JNI_VERSION_1_6;\
}\
' "$FILE"

echo "JNI_OnLoad added to qjnihelpers.cpp"
grep -n "JNI_OnLoad\|g_javaVM" "$FILE"
