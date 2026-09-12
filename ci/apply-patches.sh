#!/bin/bash
# Apply Android port patches to a vanilla qBittorrent source tree.
#
# The vanilla release tarball builds an executable (qbittorrent-nox); this
# project needs a shared library (libqbt.so) loaded in-process through JNI.
# The patches also make the optional Qt LinguistTools a soft dependency so the
# translations can be pre-compiled by the Dockerfile (host lrelease).
#
# Usage: apply-patches.sh <qb-version> <qbittorrent-source-dir>
set -euo pipefail

VER="$1"
SRC="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/patches/$VER"

if [ ! -d "$PATCH_DIR" ]; then
    echo "ERROR: no patch set for version $VER ($PATCH_DIR)" >&2
    exit 1
fi

shopt -s nullglob
for p in "$PATCH_DIR"/*.patch; do
    echo "Applying $(basename "$p")"
    patch -d "$SRC" -p1 --silent < "$p"
done
shopt -u nullglob

cp "$SCRIPT_DIR/patches/common/android_jni_bridge.cpp" "$SRC/src/app/"
echo "Patches for $VER applied to $SRC"
