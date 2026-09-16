#!/bin/bash
set -e

SRC=/build/qbittorrent-src
BUILD=/build/qbittorrent-src/build
TOOLCHAIN=/opt/android-sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64
QT_INSTALL=/opt/qt5-custom

echo "=== 1. Compile app translations (.ts -> .qm) ==="
mkdir -p ${BUILD}/src/lang
for ts in ${SRC}/src/lang/*.ts; do
    base=$(basename "$ts" .ts)
    /usr/bin/lrelease "$ts" -qm "${BUILD}/src/lang/${base}.qm" 2>/dev/null
done
ls ${BUILD}/src/lang/*.qm | wc -l
echo " app .qm files compiled"

echo "=== 2. Compile WebUI translations (.ts -> .qm) ==="
mkdir -p ${BUILD}/src/webui/www/translations
for ts in ${SRC}/src/webui/www/translations/*.ts; do
    base=$(basename "$ts" .ts)
    /usr/bin/lrelease "$ts" -qm "${BUILD}/src/webui/www/translations/${base}.qm" 2>/dev/null
done
ls ${BUILD}/src/webui/www/translations/*.qm | wc -l
echo " webui .qm files compiled"

echo "=== 3. Generate QRC files ==="
# lang.qrc
echo '<RCC><qresource prefix="/lang">' > ${BUILD}/src/lang/lang.qrc
for qm in ${BUILD}/src/lang/*.qm; do
    echo "    <file>$(basename $qm)</file>" >> ${BUILD}/src/lang/lang.qrc
done
echo '</qresource></RCC>' >> ${BUILD}/src/lang/lang.qrc

# webui_translations.qrc
echo '<RCC><qresource prefix="/www/translations">' > ${BUILD}/src/webui/www/translations/webui_translations.qrc
for qm in ${BUILD}/src/webui/www/translations/*.qm; do
    echo "    <file>$(basename $qm)</file>" >> ${BUILD}/src/webui/www/translations/webui_translations.qrc
done
echo '</qresource></RCC>' >> ${BUILD}/src/webui/www/translations/webui_translations.qrc

echo "=== 4. Rebuild qBittorrent ==="
cd ${BUILD}
ninja -j4 2>&1 | tail -15

echo "=== 5. Collect ==="
QBT_LIB=$(find ${BUILD} -name "libqbt*.so" -not -path "*_autogen*" | head -1)
cp "$QBT_LIB" /output/libqbt.so
${TOOLCHAIN}/bin/llvm-strip /output/libqbt.so
ls -lh /output/libqbt.so

echo "=== 6. Verify zh_CN qm in binary ==="
${TOOLCHAIN}/bin/llvm-strings /output/libqbt.so | grep -i "zh_CN" | head -5 || echo "zh_CN not found in strings"

echo "=== DONE ==="
