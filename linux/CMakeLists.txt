# linux/CMakeLists.txt

# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES C CXX)

# The name of the executable created for the application.
set(BINARY_NAME "mlt_player")

# The unique GTK application identifier.
set(APPLICATION_ID "com.example.mlt_player")

# Explicitly opt in to modern CMake behaviors.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(
    CMAKE_BUILD_TYPE
    "Debug"
    CACHE STRING "Flutter build mode"
    FORCE
  )

  set_property(
    CACHE CMAKE_BUILD_TYPE
    PROPERTY STRINGS
    "Debug"
    "Profile"
    "Release"
  )
endif()

# Compilation settings applied to Flutter/runner targets.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(
    ${TARGET}
    PUBLIC
    cxx_std_14
  )

  target_compile_options(
    ${TARGET}
    PRIVATE
    -Wall
    -Werror
  )

  target_compile_options(
    ${TARGET}
    PRIVATE
    "$<$<NOT:$<CONFIG:Debug>>:-O3>"
  )

  target_compile_definitions(
    ${TARGET}
    PRIVATE
    "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>"
  )
endfunction()

# ---------------------------------------------------------------------------
# Flutter
# ---------------------------------------------------------------------------

set(
  FLUTTER_MANAGED_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/flutter"
)

add_subdirectory(
  ${FLUTTER_MANAGED_DIR}
)

# Flutter's generated Linux headers are placed here.
set(
  FLUTTER_EPHEMERAL_DIR
  "${FLUTTER_MANAGED_DIR}/ephemeral"
)

# ---------------------------------------------------------------------------
# System dependencies
# ---------------------------------------------------------------------------

find_package(PkgConfig REQUIRED)

pkg_check_modules(
  GTK
  REQUIRED
  IMPORTED_TARGET
  gtk+-3.0
)

pkg_check_modules(
  MLT
  REQUIRED
  IMPORTED_TARGET
  mlt-framework-7
)

pkg_check_modules(
  EPOXY
  REQUIRED
  IMPORTED_TARGET
  epoxy
)

# ---------------------------------------------------------------------------
# MLT native bridge
# ---------------------------------------------------------------------------

add_library(
  mlt_bridge
  SHARED
  "../native/mlt_bridge.c"
  "../native/mlt_composition.c"
  "../native/mlt_export.c"
)

target_include_directories(
  mlt_bridge
  PRIVATE

  # Our own bridge header.
  "${CMAKE_CURRENT_SOURCE_DIR}/../native"

  # Gives us:
  #   <flutter_linux/flutter_linux.h>
  "${FLUTTER_EPHEMERAL_DIR}"
)

# The runner is built with -Wall -Werror by APPLY_STANDARD_SETTINGS, but that
# function is Flutter's and only reaches Flutter's targets. The bridge is the
# file where a warning would actually mean something, so it opts in here.
target_compile_options(
  mlt_bridge
  PRIVATE
  -Wall
  -Wextra
  -Wshadow
  -Werror
)

target_compile_options(
  mlt_bridge
  PRIVATE
  "$<$<NOT:$<CONFIG:Debug>>:-O3>"
)

set_target_properties(
  mlt_bridge
  PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
  C_VISIBILITY_PRESET hidden
)

target_link_libraries(
  mlt_bridge
  PRIVATE

  PkgConfig::MLT
  PkgConfig::GTK
  PkgConfig::EPOXY

  # Also propagates Flutter Linux build requirements.
  flutter
)

# libmlt_bridge.so is installed alongside libflutter_linux_gtk.so.
set_target_properties(
  mlt_bridge
  PROPERTIES
  INSTALL_RPATH "$ORIGIN"
)

# ---------------------------------------------------------------------------
# Headless smoke test
#
# Exercises the bridge with no Flutter and no window, which is what tells
# you whether a playback bug belongs to MLT or to the integration.
#
#   cmake -DMLT_PLAYER_BUILD_SMOKE=ON ...
#   SDL_AUDIODRIVER=dummy ./mlt_smoke /path/to/clip.mp4
# ---------------------------------------------------------------------------

option(
  MLT_PLAYER_BUILD_SMOKE
  "Build the headless bridge smoke test"
  OFF
)

if(MLT_PLAYER_BUILD_SMOKE)
  add_executable(
    mlt_smoke
    "../native/mlt_smoke.c"
  )

  target_include_directories(
    mlt_smoke
    PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../native"
  )

  target_link_libraries(
    mlt_smoke
    PRIVATE
    mlt_bridge
    PkgConfig::GTK
  )
endif()

# ---------------------------------------------------------------------------
# Flutter application runner
# ---------------------------------------------------------------------------

add_subdirectory(
  "runner"
)

# my_application.cc includes native/mlt_bridge.h.
target_include_directories(
  ${BINARY_NAME}
  PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../native"
)

# The Linux runner calls our texture-registration functions directly.
target_link_libraries(
  ${BINARY_NAME}
  PRIVATE
  mlt_bridge
)

# Run the Flutter tool portions of the build.
add_dependencies(
  ${BINARY_NAME}
  flutter_assemble
)

# Only the install-generated bundle's copy of the executable will launch
# correctly, because its resources need the proper relative layout.
set_target_properties(
  ${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY
  "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)

# Generated plugin build rules.
include(
  flutter/generated_plugins.cmake
)

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

set(
  BUILD_BUNDLE_DIR
  "${PROJECT_BINARY_DIR}/bundle"
)

if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(
    CMAKE_INSTALL_PREFIX
    "${BUILD_BUNDLE_DIR}"
    CACHE PATH "..."
    FORCE
  )
endif()

# Start with a clean bundle every build.
install(
  CODE "
    file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  "
  COMPONENT Runtime
)

set(
  INSTALL_BUNDLE_DATA_DIR
  "${CMAKE_INSTALL_PREFIX}/data"
)

set(
  INSTALL_BUNDLE_LIB_DIR
  "${CMAKE_INSTALL_PREFIX}/lib"
)

# Our native bridge.
install(
  TARGETS
  mlt_bridge
  LIBRARY DESTINATION
  "${INSTALL_BUNDLE_LIB_DIR}"
)

# Application executable.
install(
  TARGETS
  ${BINARY_NAME}
  RUNTIME DESTINATION
  "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime
)

# Flutter ICU data.
install(
  FILES
  "${FLUTTER_ICU_DATA_FILE}"
  DESTINATION
  "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime
)

# Flutter Linux engine.
install(
  FILES
  "${FLUTTER_LIBRARY}"
  DESTINATION
  "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime
)

# Plugin libraries.
foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(
    FILES
    "${bundled_library}"
    DESTINATION
    "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime
  )
endforeach()

# Native assets supplied by Dart packages.
set(
  NATIVE_ASSETS_DIR
  "${PROJECT_BUILD_DIR}native_assets/linux/"
)

install(
  DIRECTORY
  "${NATIVE_ASSETS_DIR}"
  DESTINATION
  "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime
)

# Flutter assets.
set(
  FLUTTER_ASSET_DIR_NAME
  "flutter_assets"
)

install(
  CODE "
    file(
      REMOVE_RECURSE
      \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\"
    )
  "
  COMPONENT Runtime
)

install(
  DIRECTORY
  "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION
  "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime
)

# AOT library for profile/release builds.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(
    FILES
    "${AOT_LIBRARY}"
    DESTINATION
    "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime
  )
endif()