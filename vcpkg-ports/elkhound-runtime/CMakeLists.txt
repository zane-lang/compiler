cmake_minimum_required(VERSION 3.20)

project(elkhound_runtime LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(CMakePackageConfigHelpers)

set(ELKHOUND_RUNTIME_SOURCES
    src/elkhound/cyctimer.cc
    src/elkhound/emitcode.cc
    src/elkhound/glr.cc
    src/elkhound/parsetables.cc
    src/elkhound/ptreeact.cc
    src/elkhound/ptreenode.cc
    src/elkhound/useract.cc
    src/smbase/autofile.cc
    src/smbase/bflatten.cc
    src/smbase/bit2d.cc
    src/smbase/bitarray.cc
    src/smbase/breaker.cpp
    src/smbase/crc.cpp
    src/smbase/cycles.c
    src/smbase/datablok.cpp
    src/smbase/exc.cpp
    src/smbase/flatten.cc
    src/smbase/gprintf.c
    src/smbase/growbuf.cc
    src/smbase/hashline.cc
    src/smbase/hashtbl.cc
    src/smbase/malloc_stub.c
    src/smbase/mysig.cc
    src/smbase/nonport.cpp
    src/smbase/point.cc
    src/smbase/srcloc.cc
    src/smbase/str.cpp
    src/smbase/strdict.cc
    src/smbase/strhash.cc
    src/smbase/stringset.cc
    src/smbase/strtokp.cpp
    src/smbase/strutil.cc
    src/smbase/svdict.cc
    src/smbase/syserr.cpp
    src/smbase/trace.cc
    src/smbase/trdelete.cc
    src/smbase/vdtllist.cc
    src/smbase/voidlist.cc
    src/smbase/vptrmap.cc
)

file(GLOB ELKHOUND_RUNTIME_HEADERS CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/elkhound/*.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/smbase/*.h"
)

add_library(elkhound_runtime STATIC ${ELKHOUND_RUNTIME_SOURCES})
add_library(elkhound_runtime::elkhound_runtime ALIAS elkhound_runtime)

target_compile_definitions(elkhound_runtime PRIVATE __UNIX__)
target_include_directories(elkhound_runtime
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src/elkhound>
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src/smbase>
        $<INSTALL_INTERFACE:include/elkhound_runtime>
)

install(TARGETS elkhound_runtime EXPORT elkhound_runtimeTargets ARCHIVE DESTINATION lib LIBRARY DESTINATION lib RUNTIME DESTINATION bin)
install(FILES ${ELKHOUND_RUNTIME_HEADERS} DESTINATION include/elkhound_runtime)

write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/elkhound_runtimeConfigVersion.cmake"
    VERSION 1.0.0
    COMPATIBILITY SameMajorVersion
)

configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/elkhound_runtimeConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/elkhound_runtimeConfig.cmake"
    INSTALL_DESTINATION share/elkhound_runtime
)

install(EXPORT elkhound_runtimeTargets NAMESPACE elkhound_runtime:: DESTINATION share/elkhound_runtime)
install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/elkhound_runtimeConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/elkhound_runtimeConfigVersion.cmake"
    DESTINATION share/elkhound_runtime
)
