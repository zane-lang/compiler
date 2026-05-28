# Source: WeiDUorg/elkhound (https://github.com/WeiDUorg/elkhound)
# The REF below must match the rev in nix/elkhound/flake.nix.
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO WeiDUorg/elkhound
    REF b8f5589de119c89b36b1fc21d2f51c4a942ee3a8
    SHA512 f284e6750adda2a9795503cc2dff21cabba89e65d3c2e0e638f5393b09f84d16f8ef005c9ca937f93b50456a6f197b8bfaec8ce40863d59c77108d34bb74c54c
    HEAD_REF master
)

file(COPY "${CMAKE_CURRENT_LIST_DIR}/CMakeLists.txt" DESTINATION "${SOURCE_PATH}")
file(COPY "${CMAKE_CURRENT_LIST_DIR}/elkhound_runtimeConfig.cmake.in" DESTINATION "${SOURCE_PATH}")

vcpkg_configure_cmake(
    SOURCE_PATH "${SOURCE_PATH}"
)

vcpkg_install_cmake()
vcpkg_fixup_cmake_targets(CONFIG_PATH share/elkhound_runtime)

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
file(INSTALL "${SOURCE_PATH}/license.txt" DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}" RENAME copyright)
