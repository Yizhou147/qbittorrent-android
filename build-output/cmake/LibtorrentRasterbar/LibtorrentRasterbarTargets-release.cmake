#----------------------------------------------------------------
# Generated CMake target import file for configuration "Release".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "LibtorrentRasterbar::torrent-rasterbar" for configuration "Release"
set_property(TARGET LibtorrentRasterbar::torrent-rasterbar APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(LibtorrentRasterbar::torrent-rasterbar PROPERTIES
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libtorrent-rasterbar.so"
  IMPORTED_SONAME_RELEASE "libtorrent-rasterbar.so"
  )

list(APPEND _IMPORT_CHECK_TARGETS LibtorrentRasterbar::torrent-rasterbar )
list(APPEND _IMPORT_CHECK_FILES_FOR_LibtorrentRasterbar::torrent-rasterbar "${_IMPORT_PREFIX}/lib/libtorrent-rasterbar.so" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
