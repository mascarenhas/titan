cmake_minimum_required(VERSION 3.25)
project(TitanWindowsNative LANGUAGES C)
if(NOT WIN32 OR NOT MINGW OR NOT CMAKE_C_COMPILER_ID STREQUAL "Clang" OR
   NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "Use native x64 MSYS2 CLANG64/UCRT for this build")
endif()
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(LIBUV_BUILD_SHARED ON CACHE BOOL "" FORCE)
set(LLHTTP_BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(LLHTTP_BUILD_STATIC_LIBS OFF CACHE BOOL "" FORCE)
add_subdirectory("${TITAN_SOURCE_ROOT}/libuv-v1.52.1" libuv EXCLUDE_FROM_ALL)
add_subdirectory("${TITAN_SOURCE_ROOT}/llhttp-release-v9.4.3" llhttp EXCLUDE_FROM_ALL)
set_target_properties(uv PROPERTIES RUNTIME_OUTPUT_NAME uv-1 ARCHIVE_OUTPUT_NAME uv)
set_target_properties(llhttp_shared PROPERTIES RUNTIME_OUTPUT_NAME llhttp-9.4 ARCHIVE_OUTPUT_NAME llhttp)
target_compile_definitions(llhttp_shared PRIVATE TITAN_LLHTTP_BUILD_DLL)

add_library(sqlite3 SHARED "${TITAN_SOURCE_ROOT}/sqlite-autoconf-3530400/sqlite3.c")
target_include_directories(sqlite3 PUBLIC "${TITAN_SOURCE_ROOT}/sqlite-autoconf-3530400")
target_compile_definitions(sqlite3 PRIVATE TITAN_SQLITE_BUILD_DLL SQLITE_THREADSAFE=1)
set_target_properties(sqlite3 PROPERTIES RUNTIME_OUTPUT_NAME sqlite3-0 ARCHIVE_OUTPUT_NAME sqlite3)

# Version the runtime basename before linking; preserve ordinary import-library
# names. No post-link DLL rename can leave an import library naming an old DLL.
foreach(target uv llhttp_shared sqlite3)
  set_target_properties(${target} PROPERTIES
    PREFIX lib IMPORT_PREFIX lib IMPORT_SUFFIX .dll.a)
  target_link_options(${target} PRIVATE -Wl,--exclude-all-symbols -Wl,--no-insert-timestamp)
endforeach()
add_custom_target(titan-native-libraries DEPENDS uv llhttp_shared sqlite3)

# Upstream static-library/install rules are not this SDK's payload. The named
# component installs only the three selected DLLs and matching import libraries.
install(TARGETS uv llhttp_shared sqlite3
  RUNTIME DESTINATION bin COMPONENT TitanNativeSDK
  ARCHIVE DESTINATION lib COMPONENT TitanNativeSDK)
install(FILES "${TITAN_SOURCE_ROOT}/libuv-v1.52.1/include/uv.h"
  "${TITAN_SOURCE_ROOT}/llhttp-release-v9.4.3/include/llhttp.h"
  "${TITAN_SOURCE_ROOT}/sqlite-autoconf-3530400/sqlite3.h"
  DESTINATION include COMPONENT TitanNativeSDK)
install(DIRECTORY "${TITAN_SOURCE_ROOT}/libuv-v1.52.1/include/uv"
  DESTINATION include COMPONENT TitanNativeSDK FILES_MATCHING PATTERN "*.h")
