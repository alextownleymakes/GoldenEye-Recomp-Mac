#!/usr/bin/env bash
#
# Build GoldenEye.app for macOS (Apple Silicon or Intel).
#
#   cd /path/to/GoldenEye-Recomp-main
#   bash macos/build-macos.sh                      # game files already in assets/
#   bash macos/build-macos.sh /path/to/30BA9271... # or: the packed XBLA file
#
# The XBLA download is a single extensionless "LIVE" package. Pass its path,
# or just copy it into assets/; the script unpacks it there automatically.
#
# What it does:
#   1. Checks the toolchain (Xcode 16+ command line tools, CMake, Ninja).
#   2. Downloads ReXGlue SDK (the macOS-capable version) and applies the
#      GoldenEye changes from macos/rexglue-sdk-goldeneye.patch.
#   3. Builds and installs the SDK (once; later runs reuse it).
#   4. Recompiles YOUR copy of the game (assets/default.xex) into C++.
#   5. Builds GoldenEye.app and puts it next to the assets folder.
#
# Options (environment variables):
#   CONFIG=RelWithDebInfo bash macos/build-macos.sh   # Release (default) / RelWithDebInfo / Debug
#   ARCH=x86_64 bash macos/build-macos.sh             # force Intel build (default: this Mac's arch)
#   REXSDK_DIR=/path/to/sdk bash macos/build-macos.sh # use/keep the SDK checkout somewhere else
#   CLEAN=1 bash macos/build-macos.sh                 # wipe previous game build first
#   JOBS=2 bash macos/build-macos.sh                  # fewer parallel compiles (less memory/swap)
#
set -euo pipefail

# ReXGlue SDK revision the GoldenEye patch was ported to (main, "Release v0.10.1").
SDK_REPO="https://github.com/rexglue/rexglue-sdk.git"
SDK_COMMIT="546a082a4356173635f6c40510a41ff53e518b5a"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_DIR="$ROOT/macos"
PATCH_FILE="$MAC_DIR/rexglue-sdk-goldeneye.patch"
SDK_DIR="${REXSDK_DIR:-$MAC_DIR/.deps/rexglue-sdk}"

bold() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS."

# --- Architecture / configuration --------------------------------------------
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64)  PARCH="arm64" ;;
  x86_64) PARCH="amd64" ;;
  *) die "Unsupported architecture '$ARCH' (use arm64 or x86_64)." ;;
esac
CONFIG="${CONFIG:-Release}"
case "$CONFIG" in
  Release) CFG="release" ;;
  RelWithDebInfo) CFG="relwithdebinfo" ;;
  Debug) CFG="debug" ;;
  *) die "CONFIG must be Release, RelWithDebInfo or Debug." ;;
esac
SDK_PRESET="mac-$PARCH"
SDK_BUILD="$SDK_DIR/out/build/$SDK_PRESET"
SDK_INSTALL="$SDK_DIR/out/install/$SDK_PRESET"
GAME_PRESET="mac-$PARCH-$CFG"
GAME_BUILD="$ROOT/out/build/$GAME_PRESET"
# Parallel compile jobs. The recompiled game is ~60 very large C++ files that
# each need a lot of memory; on Macs with 16 GB or less, running one per core
# pushes macOS into gigabytes of swap. Use half the cores there.
if [[ -z "${JOBS:-}" ]]; then
  ncpu="$(sysctl -n hw.ncpu)"
  mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  if (( mem_gb <= 16 )); then JOBS=$(( ncpu / 2 > 2 ? ncpu / 2 : 2 )); else JOBS="$ncpu"; fi
fi

# --- 1. Toolchain ------------------------------------------------------------
bold "Checking build tools"
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools are missing. Run: xcode-select --install"

clang_line="$(clang --version 2>/dev/null | head -n1 || true)"
clang_major="$(sed -nE 's/.*clang version ([0-9]+).*/\1/p' <<<"$clang_line")"
note "Compiler: ${clang_line:-not found}"
if [[ -z "$clang_major" || "$clang_major" -lt 16 ]]; then
  die "Need Apple clang 16 or newer (Xcode 16+ / its Command Line Tools) for C++23.
       Update via System Settings > Software Update, or: softwareupdate --list"
fi

need_brew=()
command -v cmake >/dev/null 2>&1 || need_brew+=(cmake)
command -v ninja >/dev/null 2>&1 || need_brew+=(ninja)
if ((${#need_brew[@]})); then
  if command -v brew >/dev/null 2>&1; then
    note "Installing with Homebrew: ${need_brew[*]}"
    brew install "${need_brew[@]}"
  else
    die "Missing: ${need_brew[*]}. Install Homebrew (https://brew.sh) then: brew install ${need_brew[*]}"
  fi
fi
cmake_ver="$(cmake --version | head -n1 | awk '{print $3}')"
note "CMake $cmake_ver, Ninja $(ninja --version)"
if [[ "$(printf '%s\n3.25\n' "$cmake_ver" | sort -V | head -n1)" != "3.25" ]]; then
  die "CMake 3.25+ required (found $cmake_ver). Run: brew upgrade cmake"
fi
command -v git >/dev/null 2>&1 || die "git is missing (comes with the Xcode Command Line Tools)."
command -v python3 >/dev/null 2>&1 || die "python3 is missing (comes with the Xcode Command Line Tools)."

free_gb="$(df -g "$ROOT" | awk 'NR==2 {print $4}')"
note "Free disk space: ${free_gb} GB"
note "Parallel compile jobs: $JOBS (set JOBS=n to change)"
if [[ "${free_gb:-0}" -lt 8 ]]; then
  printf '\n    \033[33mWarning:\033[0m the SDK + recompiled game need roughly 4-6 GB while building.\n'
  printf '    You have %s GB free. The build may fail part-way if the disk fills up.\n' "$free_gb"
  read -r -p "    Continue anyway? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

# --- Game files ------------------------------------------------------------------
bold "Checking game files"
is_stfs() {  # Xbox 360 package: starts with "LIVE", "PIRS" or "CON "
  [[ -f "$1" ]] || return 1
  local magic
  magic="$(head -c 4 "$1" 2>/dev/null || true)"
  [[ "$magic" == "LIVE" || "$magic" == "PIRS" || "$magic" == "CON " ]]
}
PACKAGE=""
if [[ -f "$ROOT/assets/default.xex" ]]; then
  note "Found assets/default.xex"
elif [[ -n "${1:-}" ]]; then
  [[ -f "$1" ]] || die "File not found: $1"
  is_stfs "$1" || die "$1 is not an Xbox 360 package (LIVE/PIRS/CON)."
  PACKAGE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  note "Will unpack $PACKAGE into assets/"
else
  mkdir -p "$ROOT/assets"
  # Look anywhere under assets/ (e.g. the whole download folder copied in).
  while IFS= read -r f; do
    if is_stfs "$f"; then PACKAGE="$f"; break; fi
  done < <(find "$ROOT/assets" -type f -size +1M 2>/dev/null)
  [[ -n "$PACKAGE" ]] || die "No game files found.
       Copy your GoldenEye XBLA package (the extensionless file) or the
       unpacked game files (default.xex + data) into: $ROOT/assets/"
  note "Will unpack $(basename "$PACKAGE") into assets/"
fi

# --- 2. SDK checkout + GoldenEye patch -------------------------------------------
bold "Getting ReXGlue SDK ($SDK_COMMIT)"
if [[ ! -d "$SDK_DIR/.git" ]]; then
  mkdir -p "$SDK_DIR"
  git -C "$SDK_DIR" init -q
  git -C "$SDK_DIR" remote add origin "$SDK_REPO"
  git -C "$SDK_DIR" fetch --depth 1 origin "$SDK_COMMIT"
  git -C "$SDK_DIR" checkout -q FETCH_HEAD
fi
note "Fetching SDK submodules (first run downloads a few hundred MB)..."
git -C "$SDK_DIR" submodule update --init --depth 1 --jobs 8

if git -C "$SDK_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  note "GoldenEye SDK patch already applied"
else
  if ! git -C "$SDK_DIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
    # An older version of the patch is applied: restore the pristine SDK sources
    # (build output under out/ is kept, so the rebuild is incremental).
    note "Updating GoldenEye SDK patch"
    git -C "$SDK_DIR" checkout -q -- .
    awk '/^diff --git/ {f=$4} /^new file mode/ {sub(/^b\//, "", f); print f}' "$PATCH_FILE" |
      while IFS= read -r f; do rm -f "$SDK_DIR/$f"; done
  fi
  git -C "$SDK_DIR" apply --whitespace=nowarn "$PATCH_FILE" \
    || die "Could not apply $PATCH_FILE to $SDK_DIR (is it a different SDK revision?)"
  note "Applied GoldenEye SDK patch"
  rm -f "$SDK_INSTALL/.ge-installed"
fi

# --- 3. Build + install the SDK --------------------------------------------------
if [[ -f "$SDK_INSTALL/.ge-installed" && -x "$SDK_INSTALL/bin/rexglue" ]]; then
  bold "ReXGlue SDK already built ($SDK_INSTALL)"
else
  bold "Building ReXGlue SDK (this is the long part, ~15-40 min)"
  (cd "$SDK_DIR" && cmake --preset "$SDK_PRESET")
  (cd "$SDK_DIR" && cmake --build --preset "$SDK_PRESET-release" -j "$JOBS")
  cmake --install "$SDK_BUILD" --config Release --prefix "$SDK_INSTALL"
  touch "$SDK_INSTALL/.ge-installed"
fi

# --- Unpack the XBLA package (needs the SDK's rexglue tool) ------------------------
if [[ -n "$PACKAGE" ]]; then
  bold "Unpacking game package into assets/"
  "$SDK_INSTALL/bin/rexglue" extract "$PACKAGE" "$ROOT/assets"
  [[ -f "$ROOT/assets/default.xex" ]] || die "Unpacked the package but found no default.xex in it."
  note "Unpacked. The original package file can be deleted from assets/ if you copied it there."
fi

# --- 4. Recompile the game -------------------------------------------------------
bold "Recompiling default.xex into C++ (generated/)"
(cd "$ROOT" && "$SDK_INSTALL/bin/rexglue" codegen --max_jump_table_entries 2048 ge_manifest.toml)

# --- 5. Build GoldenEye.app ------------------------------------------------------
bold "Building GoldenEye.app ($CONFIG, $ARCH)"
if [[ "${CLEAN:-0}" == "1" ]]; then rm -rf "$GAME_BUILD"; fi
(cd "$ROOT" && cmake --preset "$GAME_PRESET" -DCMAKE_PREFIX_PATH="$SDK_INSTALL")
(cd "$ROOT" && cmake --build --preset "$GAME_PRESET" -j "$JOBS")

APP_SRC="$GAME_BUILD/GoldenEye.app"
[[ -d "$APP_SRC" ]] || die "Build finished but $APP_SRC is missing."

# Assemble the final, self-contained GoldenEye.app in the project folder:
# program + the game files inside it (Contents/Resources/assets). Settings go to
# ~/Library/Application Support/GoldenEye, logs to ~/Library/Logs/GoldenEye.
bold "Packaging GoldenEye.app (with game files inside)"
APP="$ROOT/GoldenEye.app"
rm -rf "$APP"
ditto "$APP_SRC" "$APP"

# Copy the unpacked game files in. "cp -c" makes APFS clones, so the bundled
# copy takes no extra disk space. Then drop Finder clutter and the original
# packed download (e.g. the 30BA9271... file), which the game doesn't use.
mkdir -p "$APP/Contents/Resources/assets"
cp -Rc "$ROOT/assets/." "$APP/Contents/Resources/assets/" 2>/dev/null ||
  cp -R "$ROOT/assets/." "$APP/Contents/Resources/assets/"
while IFS= read -r f; do
  if is_stfs "$f"; then rm -f "$APP/Contents/Resources/assets/${f#"$ROOT/assets/"}"; fi
done < <(find "$ROOT/assets" -type f -size +1M 2>/dev/null)
find "$APP/Contents/Resources/assets" -name .DS_Store -delete
assets_mb="$(du -sm "$APP/Contents/Resources/assets" | awk '{print $1}')"
note "Bundled ${assets_mb} MB of game files"

# Ad-hoc sign the finished bundle (the SDK copies dylibs in after linking).
if ! sign_err="$(codesign --force --deep --sign - "$APP" 2>&1)"; then
  note "codesign failed (the app should still run when built locally): $sign_err"
fi

prog_mb="$(du -sm "$APP/Contents/MacOS" | awk '{print $1}')"
bold "Done"
note "App:    $APP  (self-contained; move it anywhere, e.g. /Applications)"
note "Size:   ${prog_mb} MB program + ${assets_mb} MB game files"
note "Launch: open \"$APP\"   (or double-click it in Finder)"
note "The assets/ folder is only needed to rebuild. Settings live in"
note "$HOME/Library/Application Support/GoldenEye, logs in $HOME/Library/Logs/GoldenEye."
