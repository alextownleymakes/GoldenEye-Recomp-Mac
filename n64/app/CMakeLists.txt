# GoldenEye 64: the N64 version, recompiled from your ROM by N64Recomp and run
# on N64ModernRuntime. macos/build-n64.sh configures this with:
#   GE64_RECOMPILED_DIR  folder holding RecompiledFuncs/ (from the recompile step)
#   GE64_RUNTIME_DIR     N64ModernRuntime checkout
#   GE64_RT64_DIR        RT64 checkout (graphics)
cmake_minimum_required(VERSION 3.20)
project(GoldenEye64 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)

set(GE64_RECOMPILED_DIR "" CACHE PATH "Folder containing RecompiledFuncs/")
set(GE64_RUNTIME_DIR "" CACHE PATH "N64ModernRuntime checkout")
set(GE64_RT64_DIR "" CACHE PATH "RT64 checkout")
if (NOT GE64_RECOMPILED_DIR OR NOT EXISTS "${GE64_RECOMPILED_DIR}/RecompiledFuncs/funcs.h")
  message(FATAL_ERROR "Set GE64_RECOMPILED_DIR to the folder holding RecompiledFuncs/")
endif()
if (NOT GE64_RUNTIME_DIR OR NOT EXISTS "${GE64_RUNTIME_DIR}/librecomp")
  message(FATAL_ERROR "Set GE64_RUNTIME_DIR to an N64ModernRuntime checkout")
endif()

if (NOT GE64_RT64_DIR OR NOT EXISTS "${GE64_RT64_DIR}/src/hle/rt64_application.h")
  message(FATAL_ERROR "Set GE64_RT64_DIR to an RT64 checkout")
endif()

find_package(SDL2 REQUIRED)

add_subdirectory("${GE64_RUNTIME_DIR}" "${CMAKE_BINARY_DIR}/N64ModernRuntime" EXCLUDE_FROM_ALL)

# RT64, built into the program.
set(RT64_STATIC ON CACHE BOOL "" FORCE)
if (CMAKE_SYSTEM_NAME MATCHES "Linux")
  set(RT64_SDL_WINDOW_VULKAN ON CACHE BOOL "" FORCE)
  set(NFD_PORTAL ON CACHE BOOL "" FORCE)
endif()
add_subdirectory("${GE64_RT64_DIR}" "${CMAKE_BINARY_DIR}/rt64" EXCLUDE_FROM_ALL)

# The recompiled game: plain C, one file per hundred functions.
file(GLOB GE64_FUNCS "${GE64_RECOMPILED_DIR}/RecompiledFuncs/funcs_*.c")
add_library(ge64_funcs STATIC ${GE64_FUNCS})
target_include_directories(ge64_funcs PRIVATE
  "${GE64_RUNTIME_DIR}/N64Recomp/include"
  "${GE64_RECOMPILED_DIR}/RecompiledFuncs")
target_compile_options(ge64_funcs PRIVATE
  -fno-strict-aliasing -w
  # Runtime-provided functions (osCreateThread_recomp, ...) aren't declared in funcs.h.
  -Wno-implicit-function-declaration
  $<$<C_COMPILER_ID:Clang,AppleClang>:-fbracket-depth=4096>)

add_executable(GoldenEye64
  src/main.cpp
  src/sections.cpp
  src/memory.cpp
  src/stubs.cpp
  src/gfx_rt64.cpp
  src/platform.cpp
  src/audio.cpp
  "${GE64_RECOMPILED_DIR}/RecompiledFuncs/aspMain.cpp")
target_include_directories(GoldenEye64 PRIVATE
  "${GE64_RUNTIME_DIR}/N64Recomp/include"
  "${GE64_RECOMPILED_DIR}/RecompiledFuncs"
  src
  ${SDL2_INCLUDE_DIRS}
  "${GE64_RT64_DIR}/src"
  "${GE64_RT64_DIR}/src/contrib"
  "${GE64_RT64_DIR}/src/contrib/hlslpp/include"
  "${GE64_RT64_DIR}/src/contrib/imgui"
  "${GE64_RT64_DIR}/src/contrib/Vulkan-Headers/include"
  "${GE64_RT64_DIR}/src/contrib/VulkanMemoryAllocator/include")
target_compile_definitions(GoldenEye64 PRIVATE HLSL_CPU)
# The RSP vector unit emulation uses SSE4.1 on Intel (sse2neon on Apple Silicon).
if (CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64" AND NOT CMAKE_OSX_ARCHITECTURES MATCHES "arm64")
  set_source_files_properties("${GE64_RECOMPILED_DIR}/RecompiledFuncs/aspMain.cpp" PROPERTIES COMPILE_OPTIONS "-msse4.1")
endif()
if (CMAKE_SYSTEM_NAME MATCHES "Linux")
  target_compile_definitions(GoldenEye64 PRIVATE RT64_SDL_WINDOW_VULKAN)
endif()
target_link_libraries(GoldenEye64 PRIVATE ge64_funcs librecomp ultramodern rt64 ${SDL2_LIBRARIES})
