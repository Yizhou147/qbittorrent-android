#!/bin/bash
cd /build/qt5-build
make install 2>&1 | tail -5
echo "=== Qt5 Libraries ==="
ls -la /opt/qt5-custom/lib/libQt5*.so
echo "=== JNI check ==="
readelf -s /opt/qt5-custom/lib/libQt5Core_arm64-v8a.so | grep -ci jni || echo "0"
echo "=== Platform plugins ==="
find /opt/qt5-custom/plugins/platforms -name "*.so" 2>/dev/null || echo "no platform plugins"
echo "=== SQL plugins ==="
find /opt/qt5-custom/plugins/sqldrivers -name "*.so" 2>/dev/null || echo "no sql plugins"
echo "=== Bearer plugins ==="
find /opt/qt5-custom/plugins/bearer -name "*.so" 2>/dev/null || echo "no bearer plugins"
echo "DONE"
