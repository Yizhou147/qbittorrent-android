#!/usr/bin/env python3
"""Patch CMakeLists.txt to support pre-compiled translation files."""
import sys

f = '/build/qbittorrent-src/src/app/CMakeLists.txt'
t = open(f).read()

# Patch 1: app translations - add elseif branch for pre-compiled .qm + .qrc
old1 = '''if (QBT_QM_FILES)
    target_sources(qbt_app PRIVATE
        ${QBT_QM_FILES}
        "${qBittorrent_BINARY_DIR}/src/lang/lang.qrc"
    )
endif()'''
new1 = '''if (QBT_QM_FILES)
    target_sources(qbt_app PRIVATE
        ${QBT_QM_FILES}
        "${qBittorrent_BINARY_DIR}/src/lang/lang.qrc"
    )
elseif (EXISTS "${qBittorrent_BINARY_DIR}/src/lang/lang.qrc")
    file(GLOB _PRECOMPILED_QM "${qBittorrent_BINARY_DIR}/src/lang/*.qm")
    target_sources(qbt_app PRIVATE
        ${_PRECOMPILED_QM}
        "${qBittorrent_BINARY_DIR}/src/lang/lang.qrc"
    )
endif()'''

# Patch 2: webui translations - add elseif branch
old2 = '''if (QBT_WEBUI_QM_FILES)
        target_sources(qbt_app PRIVATE
            ${QBT_WEBUI_QM_FILES}
            ${qBittorrent_BINARY_DIR}/src/webui/www/translations/webui_translations.qrc
        )
    endif()'''
new2 = '''if (QBT_WEBUI_QM_FILES)
        target_sources(qbt_app PRIVATE
            ${QBT_WEBUI_QM_FILES}
            ${qBittorrent_BINARY_DIR}/src/webui/www/translations/webui_translations.qrc
        )
    elseif (EXISTS "${qBittorrent_BINARY_DIR}/src/webui/www/translations/webui_translations.qrc")
        file(GLOB _PRECOMPILED_WEBUI_QM "${qBittorrent_BINARY_DIR}/src/webui/www/translations/*.qm")
        target_sources(qbt_app PRIVATE
            ${_PRECOMPILED_WEBUI_QM}
            ${qBittorrent_BINARY_DIR}/src/webui/www/translations/webui_translations.qrc
        )
    endif()'''

if old1 in t:
    t = t.replace(old1, new1)
    print('Patched app translations')
else:
    print('WARNING: app translations pattern not found', file=sys.stderr)

if old2 in t:
    t = t.replace(old2, new2)
    print('Patched webui translations')
else:
    print('WARNING: webui translations pattern not found', file=sys.stderr)

open(f, 'w').write(t)
print('Done')
