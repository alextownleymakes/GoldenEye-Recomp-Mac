#!/usr/bin/env bash
#
# Build the Nintendo 64 version: "GoldenEye 64.app", from your own ROM of
# GoldenEye 007 (USA). The GoldenEye app runs this for you; you can also run:
#
#   bash macos/build-n64.sh                         # ROM already in assets/n64/
#   bash macos/build-n64.sh "/path/to/GoldenEye 007 (USA).z64"
#
# .z64, .v64 and .n64 ROMs all work. Your ROM is never changed.
#
# What it does:
#   1. Checks the toolchain (CMake and Ninja are downloaded once into
#      macos/.deps/tools if this Mac doesn't have them).
#   2. Checks the ROM and writes a working copy with the game's compressed
#      data segment unpacked (n64/tools/prepare_rom.py).
#   3. Downloads N64Recomp at a fixed revision, applies
#      n64/patches/n64recomp-goldeneye.patch and builds it (once).
#   4. Recompiles the game's MIPS code into C, and its audio microcode into
#      C++ (out/n64/RecompiledFuncs).
#   5. Downloads N64ModernRuntime (the console's OS, threads and memory),
#      RT64 (graphics, drawn with Metal) and SDL2 (window, sound, controllers)
#      at fixed revisions, once.
#   6. Builds GoldenEye 64.app into ~/Library/Application Support/GoldenEye/Games
#      (or GE_APP_DIR), where the GoldenEye app plays it.
#
# Options: JOBS=n (parallel compiles), CLEAN=1 (redo the recompile step).
#
set -euo pipefail

N64RECOMP_REPO="https://github.com/N64Recomp/N64Recomp.git"
N64RECOMP_COMMIT="598ce2080004a5672d604dceadbda436045307b7"
RUNTIME_REPO="https://github.com/N64Recomp/N64ModernRuntime.git"
RUNTIME_COMMIT="e4342ae030a9d94aa97a81aafd3368ed7daa74df"
RT64_REPO="https://github.com/rt64/rt64.git"
RT64_COMMIT="23cab603c4f9f4a8b369b38e036f1aa484603878"
# RT64's libraries that are used on macOS (the Windows-only ones are skipped).
# (dxc, its shader compiler, is fetched separately: only this Mac's files.)
RT64_SUBMODULES="implot hlslpp xxHash volk Vulkan-Headers VulkanMemoryAllocator imgui im3d stb
  nativefiledialog-extended spirv-cross ddspp zstd re-spirv mupen64plus-core"
SDL_VERSION="2.30.9"
SDL_SHA256="24b574f71c87a763f50704bbb630cbe38298d544a1f890f099a4696b1d6beba4"
US_SHA1="abe01e4aeb033b6c0836819f549c791b26cfde83"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_DIR="$ROOT/macos"
N64_DIR="$ROOT/n64"
DEPS="$MAC_DIR/.deps"
RECOMP_DIR="$DEPS/N64Recomp"
PATCH_FILE="$N64_DIR/patches/n64recomp-goldeneye.patch"
OUT="$ROOT/out/n64"
APP_NAME="GoldenEye 64.app"

bold() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
# A CMake build folder remembers where its sources were. After the project
# folder moves, start that build folder over.
drop_stale_build() {  # <build dir> <source dir>
  local cache="$1/CMakeCache.txt" src
  [[ -f "$cache" ]] || return 0
  src="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache" | head -1)"
  if [[ -n "$src" && "$src" != "$2" && "$src" != "$(cd "$2" && pwd -P)" ]]; then
    note "Project folder moved (was $src); starting a fresh build there"
    rm -rf "$1"
    return 1
  fi
  return 0
}

[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS."

# The GoldenEye app can run under Rosetta (its launcher is a script), and then
# everything it starts builds for Intel. On Apple Silicon, build natively.
if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == "1" ]]; then
  exec /usr/bin/arch -arm64 /bin/bash "${BASH_SOURCE[0]}" "$@"
fi
# A build left from the other architecture (e.g. an Intel one made under
# Rosetta) can't be reused: start the compiled parts over.
built_arch="$(lipo -archs "$ROOT/out/build/n64/GoldenEye64" 2>/dev/null || true)"
if [[ -n "$built_arch" && "$built_arch" != "$(uname -m)" ]]; then
  note "Removing the $built_arch build to rebuild for $(uname -m)"
  rm -rf "$ROOT/out/build/n64" "$DEPS/sdl2" "$DEPS/SDL2-$SDL_VERSION/build" "$RECOMP_DIR/build" \
         "$RECOMP_DIR/.goldeneye-stamp"
fi

if [[ -z "${JOBS:-}" ]]; then JOBS="$(sysctl -n hw.ncpu)"; fi

# --- 1. Toolchain ------------------------------------------------------------
bold "Checking build tools"
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools are missing. Run: xcode-select --install"
note "Compiler: $(clang --version 2>/dev/null | head -n1 || echo 'not found')"
command -v git >/dev/null 2>&1 || die "git is missing (comes with the Xcode Command Line Tools)."
command -v python3 >/dev/null 2>&1 || die "python3 is missing (comes with the Xcode Command Line Tools)."

TOOLS_DIR="$DEPS/tools"
CMAKE_VER_DL="3.31.6"
NINJA_VER_DL="1.12.1"

# SHA-256 of each download above; a mismatch stops the build before anything runs.
CMAKE_SHA256="330b9514f5112e5ed4fb08b8b05803b776fd9b539a6ae12927d14dcc0ee2ba8d"
NINJA_SHA256="89a287444b5b3e98f88a945afa50ce937b8ffd1dcc59c555ad9b1baf855298c9"
check_sha256() {  # file expected-hash label
  local got; got="$(shasum -a 256 "$1" | awk '{print $1}')"
  if [[ "$got" != "$2" ]]; then
    rm -f "$1"
    die "The $3 download didn't match its expected checksum, so it wasn't used. Try again later."
  fi
}
for d in "$TOOLS_DIR/cmake/CMake.app/Contents/bin" "$TOOLS_DIR/ninja"; do
  [[ -d "$d" ]] && PATH="$d:$PATH"
done
export PATH
cmake_ok() {
  command -v cmake >/dev/null 2>&1 || return 1
  local v; v="$(cmake --version | head -n1 | awk '{print $3}')"
  [[ "$(printf '%s\n3.25\n' "$v" | sort -V | head -n1)" == "3.25" ]]
}
if ! cmake_ok || ! command -v ninja >/dev/null 2>&1; then
  bold "Getting build tools (CMake, Ninja; once)"
  mkdir -p "$TOOLS_DIR"
  if ! cmake_ok; then
    note "Downloading CMake $CMAKE_VER_DL..."
    rm -rf "$TOOLS_DIR/cmake" "$TOOLS_DIR/cmake.tar.gz"
    curl -fL --retry 3 -o "$TOOLS_DIR/cmake.tar.gz" \
      "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VER_DL/cmake-$CMAKE_VER_DL-macos-universal.tar.gz" \
      || die "Couldn't download CMake. Check your internet connection and try again."
    check_sha256 "$TOOLS_DIR/cmake.tar.gz" "$CMAKE_SHA256" CMake
    mkdir -p "$TOOLS_DIR/cmake"
    tar -xzf "$TOOLS_DIR/cmake.tar.gz" -C "$TOOLS_DIR/cmake" --strip-components 1 || die "Couldn't unpack CMake."
    rm -f "$TOOLS_DIR/cmake.tar.gz"
    xattr -dr com.apple.quarantine "$TOOLS_DIR/cmake" 2>/dev/null || true
    PATH="$TOOLS_DIR/cmake/CMake.app/Contents/bin:$PATH"
  fi
  if ! command -v ninja >/dev/null 2>&1; then
    note "Downloading Ninja $NINJA_VER_DL..."
    rm -rf "$TOOLS_DIR/ninja" "$TOOLS_DIR/ninja.zip"
    curl -fL --retry 3 -o "$TOOLS_DIR/ninja.zip" \
      "https://github.com/ninja-build/ninja/releases/download/v$NINJA_VER_DL/ninja-mac.zip" \
      || die "Couldn't download Ninja. Check your internet connection and try again."
    check_sha256 "$TOOLS_DIR/ninja.zip" "$NINJA_SHA256" Ninja
    mkdir -p "$TOOLS_DIR/ninja"
    unzip -q -o "$TOOLS_DIR/ninja.zip" -d "$TOOLS_DIR/ninja" || die "Couldn't unpack Ninja."
    rm -f "$TOOLS_DIR/ninja.zip"
    chmod +x "$TOOLS_DIR/ninja/ninja"
    xattr -dr com.apple.quarantine "$TOOLS_DIR/ninja" 2>/dev/null || true
    PATH="$TOOLS_DIR/ninja:$PATH"
  fi
  export PATH
fi
cmake_ok || die "CMake 3.25 or newer is needed and couldn't be set up."
note "CMake $(cmake --version | head -n1 | awk '{print $3}'), Ninja $(ninja --version)"

# --- 2. ROM ------------------------------------------------------------------
bold "Checking your ROM"
is_rom() {  # first 4 bytes: .z64 80371240, .v64 37804012, .n64 40123780
  [[ -f "$1" ]] || return 1
  case "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" in
    80371240|37804012|40123780) return 0 ;;
  esac
  return 1
}
find_rom() {  # <folder>: the first N64 ROM in it (or one level down)
  local f
  while IFS= read -r -d '' f; do
    if is_rom "$f"; then printf '%s' "$f"; return 0; fi
  done < <(find "$1" -maxdepth 2 -type f -size +4M -print0 2>/dev/null)
  return 1
}
SRC="${1:-}"
if [[ -z "$SRC" ]]; then
  [[ -d "$ROOT/assets/n64" ]] && SRC="$(find_rom "$ROOT/assets/n64" || true)"
  [[ -n "$SRC" ]] || die "No N64 ROM found. Choose your GoldenEye 007 (USA) ROM in the GoldenEye app,
       or put it in the assets/n64 folder."
elif [[ -d "$SRC" ]]; then
  ROMDIR="$SRC"
  SRC="$(find_rom "$ROMDIR" || true)"
  [[ -n "$SRC" ]] || die "No N64 ROM in $ROMDIR."
fi
[[ -e "$SRC" ]] || die "Not found: $SRC"
is_rom "$SRC" || die "$(basename "$SRC") isn't an N64 ROM (.z64, .v64 or .n64)."
note "ROM: $SRC"
mkdir -p "$OUT"
python3 "$N64_DIR/tools/prepare_rom.py" "$SRC" "$OUT/ge007.recomp.z64" \
  || die "$(basename "$SRC") can't be used. GoldenEye 64 needs the US (NTSC-U) GoldenEye 007 ROM."
note "ROM is GoldenEye 007 (USA)."

# get_repo <dir> <url> <commit> [submodule paths...]: a checkout of exactly
# <commit> (and its submodules) with no history, the smallest download.
get_repo() {
  local dir="$1" url="$2" commit="$3"; shift 3
  if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$commit" ]]; then
    if [[ ! -d "$dir/.git" ]]; then
      rm -rf "$dir"
      mkdir -p "$dir"
      git -C "$dir" init --quiet || return 1
      git -C "$dir" remote add origin "$url" || return 1
    fi
    git -C "$dir" fetch --quiet --depth 1 origin "$commit" || return 1
    git -C "$dir" checkout --quiet --force FETCH_HEAD || return 1
  fi
  git -C "$dir" submodule update --quiet --init --recursive --depth 1 -- "$@" || return 1
}

# --- 3. N64Recomp ---------------------------------------------------------------
PATCH_SUM="$(shasum -a 256 "$PATCH_FILE" | awk '{print $1}')"
STAMP="$RECOMP_DIR/.goldeneye-stamp"
WANT_STAMP="$N64RECOMP_COMMIT $PATCH_SUM"
if [[ ! -f "$STAMP" || "$(cat "$STAMP")" != "$WANT_STAMP" || ! -x "$RECOMP_DIR/build/N64Recomp" || ! -x "$RECOMP_DIR/build/RSPRecomp" ]]; then
  bold "Getting N64Recomp (${N64RECOMP_COMMIT:0:10})"
  mkdir -p "$DEPS"
  get_repo "$RECOMP_DIR" "$N64RECOMP_REPO" "$N64RECOMP_COMMIT" \
    || die "Couldn't download N64Recomp. Check your internet connection and try again."
  git -C "$RECOMP_DIR" checkout --quiet -- .
  git -C "$RECOMP_DIR" clean -fdq -e build
  git -C "$RECOMP_DIR" apply "$PATCH_FILE" || die "Couldn't apply $PATCH_FILE to N64Recomp."
  rm -f "$STAMP"

  bold "Building N64Recomp"
  drop_stale_build "$RECOMP_DIR/build" "$RECOMP_DIR" || true
  cmake -S "$RECOMP_DIR" -B "$RECOMP_DIR/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null \
    || die "Couldn't configure N64Recomp."
  cmake --build "$RECOMP_DIR/build" --target N64Recomp RSPRecomp -j "$JOBS" || die "N64Recomp didn't build."
  printf '%s' "$WANT_STAMP" > "$STAMP"
else
  bold "N64Recomp already built"
fi

# --- 4. Recompile ----------------------------------------------------------------
bold "Recompiling the game into C (out/n64/RecompiledFuncs)"
cp "$N64_DIR/recomp/goldeneye64.toml" "$N64_DIR/recomp/ge007.u.syms.toml" "$N64_DIR/recomp/aspMain.toml" "$OUT/"
rm -rf "$OUT/RecompiledFuncs"
mkdir -p "$OUT/RecompiledFuncs"
( cd "$OUT" && "$RECOMP_DIR/build/N64Recomp" goldeneye64.toml ) > "$OUT/recompile.log" 2>&1 \
  || { tail -n 20 "$OUT/recompile.log"; die "Recompiling the game failed (details in out/n64/recompile.log)."; }
nfiles="$(find "$OUT/RecompiledFuncs" -name '*.c' | wc -l | tr -d ' ')"
(( nfiles > 0 )) || die "The recompiler produced no code (details in out/n64/recompile.log)."
( cd "$OUT" && "$RECOMP_DIR/build/RSPRecomp" aspMain.toml ) >> "$OUT/recompile.log" 2>&1 \
  && [[ -f "$OUT/RecompiledFuncs/aspMain.cpp" ]] \
  || { tail -n 20 "$OUT/recompile.log"; die "Recompiling the audio microcode failed (details in out/n64/recompile.log)."; }
note "$nfiles C files written, plus the audio microcode."

# --- 5. Runtime, graphics, SDL ------------------------------------------------

RUNTIME_DIR="$DEPS/N64ModernRuntime"
RT64_DIR="$DEPS/rt64"
SDL_DIR="$DEPS/sdl2"
RT64_PATCH="$N64_DIR/patches/rt64-goldeneye.patch"
RT64_STAMP="$RT64_DIR/.goldeneye-stamp"
RT64_WANT="$RT64_COMMIT $(shasum -a 256 "$RT64_PATCH" | awk '{print $1}')"

if [[ "$(git -C "$RUNTIME_DIR" rev-parse HEAD 2>/dev/null)" != "$RUNTIME_COMMIT" \
   || ! -f "$RT64_STAMP" || "$(cat "$RT64_STAMP")" != "$RT64_WANT" ]]; then
  bold "Getting the N64 runtime, RT64 and SDL (once)"
  # The runtime's N64Recomp is the same revision as the one built above, so
  # link to that instead of downloading it again.
  get_repo "$RUNTIME_DIR" "$RUNTIME_REPO" "$RUNTIME_COMMIT" thirdparty/miniz thirdparty/o1heap thirdparty/xxHash \
    || die "Couldn't download N64ModernRuntime. Check your internet connection and try again."
  rm -rf "$RUNTIME_DIR/N64Recomp"
  ln -s ../N64Recomp "$RUNTIME_DIR/N64Recomp"
  rt64_subs=()
  for m in $RT64_SUBMODULES; do rt64_subs+=("src/contrib/$m"); done
  get_repo "$RT64_DIR" "$RT64_REPO" "$RT64_COMMIT" "${rt64_subs[@]}" \
    || die "Couldn't download RT64. Check your internet connection and try again."
  # dxc ships prebuilt binaries for every platform; take only this Mac's.
  dxc_dir="$RT64_DIR/src/contrib/dxc"
  case "$(uname -m)" in arm64) dxc_arch=arm64 ;; *) dxc_arch=x64 ;; esac
  dxc_commit="$(git -C "$RT64_DIR" ls-tree HEAD src/contrib/dxc | awk '{print $3}')"
  dxc_url="$(git -C "$RT64_DIR" config -f .gitmodules submodule.src/contrib/dxc.url)"
  if [[ "$(git -C "$dxc_dir" rev-parse HEAD 2>/dev/null)" != "$dxc_commit" || ! -e "$dxc_dir/bin/$dxc_arch/dxc-macos" ]]; then
    rm -rf "$dxc_dir"
    mkdir -p "$dxc_dir"
    git -C "$dxc_dir" init --quiet \
      && git -C "$dxc_dir" remote add origin "$dxc_url" \
      && git -C "$dxc_dir" sparse-checkout set --no-cone "/inc/" "/bin/$dxc_arch/dxc-macos" "/lib/$dxc_arch/libdxcompiler.dylib" \
      && git -C "$dxc_dir" fetch --quiet --depth 1 --filter=blob:none origin "$dxc_commit" \
      && git -C "$dxc_dir" checkout --quiet FETCH_HEAD \
      || die "Couldn't download RT64's shader compiler. Check your internet connection and try again."
  fi
  git -C "$RT64_DIR" checkout --quiet -- CMakeLists.txt src
  git -C "$RT64_DIR" apply "$RT64_PATCH" || die "Couldn't apply $RT64_PATCH to RT64."
  printf '%s' "$RT64_WANT" > "$RT64_STAMP"
fi

if [[ ! -f "$SDL_DIR/lib/cmake/SDL2/SDL2Config.cmake" ]]; then
  bold "Building SDL $SDL_VERSION (once)"
  sdl_src="$DEPS/SDL2-$SDL_VERSION"
  if [[ ! -d "$sdl_src" ]]; then
    curl -fL --retry 3 -o "$DEPS/sdl2.tar.gz" \
      "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VERSION/SDL2-$SDL_VERSION.tar.gz" \
      || die "Couldn't download SDL. Check your internet connection and try again."
    check_sha256 "$DEPS/sdl2.tar.gz" "$SDL_SHA256" SDL
    tar -xzf "$DEPS/sdl2.tar.gz" -C "$DEPS" || die "Couldn't unpack SDL."
    rm -f "$DEPS/sdl2.tar.gz"
  fi
  drop_stale_build "$sdl_src/build" "$sdl_src" || true
  cmake -S "$sdl_src" -B "$sdl_src/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SDL_DIR" -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null \
    || die "Couldn't configure SDL."
  cmake --build "$sdl_src/build" -j "$JOBS" || die "SDL didn't build."
  cmake --install "$sdl_src/build" >/dev/null || die "Couldn't install SDL."
fi

# RT64's Intel build of dxc looks for zlib at @rpath/zlib.net/v1/lib/libz.dylib,
# which no Mac has. Point it at macOS's own zlib (the Apple Silicon build
# already uses that), then re-sign it since the file changed.
for f in "$RT64_DIR/src/contrib/dxc/bin/x64/dxc-macos" "$RT64_DIR/src/contrib/dxc/lib/x64/libdxcompiler.dylib"; do
  if [[ -f "$f" ]] && otool -L "$f" | grep -q "@rpath/zlib.net/v1/lib/libz.dylib"; then
    install_name_tool -change @rpath/zlib.net/v1/lib/libz.dylib /usr/lib/libz.1.dylib "$f" 2>/dev/null \
      || die "Couldn't fix RT64's shader compiler ($f)."
    codesign --force --sign - "$f" >/dev/null 2>&1 || true
  fi
done

# --- 6. App ---------------------------------------------------------------------
bold "Building GoldenEye 64.app (this is the long part the first time)"
APP_BUILD="$ROOT/out/build/n64"
drop_stale_build "$APP_BUILD" "$N64_DIR/app" || true
cmake -S "$N64_DIR/app" -B "$APP_BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DGE64_RECOMPILED_DIR="$OUT" -DGE64_RUNTIME_DIR="$RUNTIME_DIR" -DGE64_RT64_DIR="$RT64_DIR" \
  -DSDL2_DIR="$SDL_DIR/lib/cmake/SDL2" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null \
  || die "Couldn't configure $APP_NAME."
cmake --build "$APP_BUILD" --target GoldenEye64 -j "$JOBS" || die "$APP_NAME didn't build."
[[ -x "$APP_BUILD/GoldenEye64" ]] || die "Build finished but the GoldenEye64 program is missing."

bold "Packaging GoldenEye 64.app"
APP_DIR="${GE_APP_DIR:-$HOME/Library/Application Support/GoldenEye/Games}"  # the GoldenEye app plays it from there
mkdir -p "$APP_DIR"
APP="$APP_DIR/$APP_NAME"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$APP_BUILD/GoldenEye64" "$APP/Contents/MacOS/GoldenEye64"
# SDL goes inside the app; the program looks for it in Frameworks.
sdl_lib="$(cd "$SDL_DIR/lib" && ls libSDL2-2.0*.dylib 2>/dev/null | head -1 || true)"
[[ -n "$sdl_lib" ]] || die "SDL's library is missing from $SDL_DIR/lib. Delete that folder and build again."
cp -L "$SDL_DIR/lib/$sdl_lib" "$APP/Contents/Frameworks/$sdl_lib"
sdl_ref="$(otool -L "$APP/Contents/MacOS/GoldenEye64" | awk '/libSDL2/ {print $1; exit}')"
if [[ -n "$sdl_ref" ]]; then
  install_name_tool -change "$sdl_ref" "@executable_path/../Frameworks/$sdl_lib" "$APP/Contents/MacOS/GoldenEye64"
fi
# Your ROM, which the game reads its data from as it runs.
python3 - "$SRC" "$APP/Contents/Resources/ge007.z64" <<'PY' || die "Couldn't copy the ROM into the app."
import sys
rom = bytearray(open(sys.argv[1], "rb").read())
if rom[:4] == b"\x37\x80\x40\x12":
    rom[0::2], rom[1::2] = rom[1::2], rom[0::2]
elif rom[:4] == b"\x40\x12\x37\x80":
    for i in range(0, len(rom) - 3, 4):
        rom[i:i + 4] = rom[i:i + 4][::-1]
open(sys.argv[2], "wb").write(rom)
PY
cp "$MAC_DIR/GoldenEye.icns" "$APP/Contents/Resources/GoldenEye64.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>GoldenEye 64</string>
  <key>CFBundleDisplayName</key>
  <string>GoldenEye 64</string>
  <key>CFBundleIdentifier</key>
  <string>com.alextownleymakes.goldeneye64</string>
  <key>CFBundleExecutable</key>
  <string>GoldenEye64</string>
  <key>CFBundleIconFile</key>
  <string>GoldenEye64</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.games</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

bold "Done"
note "$APP"
