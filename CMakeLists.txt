
# ge - ReXGlue Recompiled Project
#
# This file is yours to edit. 'rexglue migrate' will NOT overwrite it.
# SDK boilerplate lives in generated/rexglue.cmake.

cmake_minimum_required(VERSION 3.25)
project(ge LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# GoldenEye needs larger jump tables than the codegen default (512). Passed to
# every 'rexglue codegen' run the build triggers (matches the original
# 'rexglue codegen --max_jump_table_entries 2048' step).
set(REXGLUE_CODEGEN_ARGS --max_jump_table_entries 2048)

include(generated/rexglue.cmake)

# Sources
set(GE_SOURCES
    src/main.cpp
    src/ge_hooks.cpp
    src/ge_menu.cpp
    src/ge_postfx.cpp
    src/ge_username.cpp
    src/ge_ce_patches.cpp
)

if(WIN32)
    # Embed the application icon (GoldenEye.rc -> "MAINICON"). Use LLVM's resource
    # compiler since the toolchain is clang/lld (MSVC rc.exe may not be on PATH).
    if(NOT CMAKE_RC_COMPILER)
        set(CMAKE_RC_COMPILER "llvm-rc")
    endif()
    enable_language(RC)
    add_executable(ge WIN32 ${GE_SOURCES} GoldenEye.rc)
elseif(APPLE)
    # macOS: build a double-clickable GoldenEye.app. The SDK stages its runtime
    # dylibs and the Vulkan loader + MoltenVK next to the executable
    # (GoldenEye.app/Contents/MacOS), and the app looks for the "assets" folder
    # and ge.toml next to GoldenEye.app (see GeApp::OnConfigurePaths).
    set(GE_MAC_ICON "${CMAKE_CURRENT_SOURCE_DIR}/macos/GoldenEye.icns")
    set_source_files_properties("${GE_MAC_ICON}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    add_executable(ge MACOSX_BUNDLE ${GE_SOURCES} "${GE_MAC_ICON}")
    set_target_properties(ge PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/macos/Info.plist.in"
        MACOSX_BUNDLE_BUNDLE_NAME "GoldenEye"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.goldeneye-recomp.goldeneye"
        MACOSX_BUNDLE_ICON_FILE "GoldenEye.icns"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
        MACOSX_BUNDLE_BUNDLE_VERSION "1.0"
    )
else()
    add_executable(ge ${GE_SOURCES})
endif()

# Output a GoldenEye.exe (the in-Explorer/process name), independent of the
# internal target/app name "ge" (which still drives ge.toml / the user data dir).
# On macOS this names the bundle GoldenEye.app.
set_target_properties(ge PROPERTIES OUTPUT_NAME "GoldenEye")

# ReXGlue 0.10+: the Xenos GPU emulation is a runtime plugin
# (librexgpu-xenos.dylib / .so / .dll) staged next to the executable.
rexglue_setup_target(ge GPU_PLUGINS xenos)
