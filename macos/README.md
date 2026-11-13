# GoldenEye 007 Recomp — macOS build

This folder turns the project into a native macOS app (`GoldenEye.app`) for Apple Silicon (M1/M2/M3/M4) or Intel Macs. Graphics run on Metal through MoltenVK (the SDK's Vulkan backend), so there's no emulator and no Wine.

## What you need

* macOS 14 or newer, with the **Xcode 16+ Command Line Tools** (`xcode-select --install`). The full Xcode app isn't required.
* **Homebrew**, used for `cmake` and `ninja`. The script installs them if they're missing.
* Your own GoldenEye 007 (XBLA) game. Either copy the packed download (the single extensionless file, e.g. `30BA9271…`) into `assets/`, or pass its path to the script; it gets unpacked automatically. Already-unpacked files (`assets/default.xex` + data) work too.
* About **4–6 GB of free disk space** while building, plus an internet connection on the first run (the SDK and its dependencies are downloaded). Afterwards you can delete `macos/.deps/` and `out/` to get that space back; only `GoldenEye.app` is needed to play.

## Build

```sh
cd ~/Downloads/GoldenEye-Recomp-main
bash macos/build-macos.sh
# or point it at the packed game file directly:
bash macos/build-macos.sh ~/Downloads/GoldenEye_007_XBLA_Retail/0000000000000000/584108A9/000D0000/30BA92710985645EF623D4A6BA9E8EFFAEC62617
```

The first run takes a while. The SDK build alone is roughly 15–40 minutes on an M-series Mac, and later runs reuse it. When the script finishes, `GoldenEye.app` is in the project folder next to `assets/`.

Options:

| Variable | Effect |
| --- | --- |
| `CONFIG=RelWithDebInfo` | Build with debug symbols. `Release` is the default. |
| `ARCH=x86_64` | Force an Intel build. By default the script builds for this Mac's architecture. |
| `CLEAN=1` | Wipe the previous game build first. |
| `REXSDK_DIR=/some/path` | Keep the SDK checkout somewhere other than `macos/.deps/`. |

## Run

The build produces a self-contained `GoldenEye.app` in the project folder. Your game files are copied inside it (`Contents/Resources/assets`), as APFS clones, so they take no extra disk space. Move it anywhere, such as `/Applications`, and double-click it or run `open GoldenEye.app`.

* Settings: `~/Library/Application Support/GoldenEye/ge.toml`
* Logs: `~/Library/Logs/GoldenEye/`, also viewable in Console.app
* The project's `assets/` folder is only needed for rebuilding. If no files are bundled in the app, it falls back to an `assets` folder next to `GoldenEye.app`.

If macOS says the app "can't be opened", right-click it, choose **Open**, then confirm. The app is signed ad hoc because it was built on your Mac.

## Sprint (mod)

Press **L3** (click the left stick) to sprint while moving forward. By default it toggles: it stays on until you press L3 again or stop moving. It's unlimited, with no stamina. R3 still crouches. On keyboard, sprint is **Shift**, rebindable in the pause menu's key bindings, and **C** (L3) still crouches.

* `ge_sprint_speed` in `ge.toml` sets how fast (default `1.75`; normal running is 1.0 and the game's own "full speed" after 3 seconds is 1.25).
* **Sprint Mode** (pause menu → Controls), or `ge_sprint_toggle` in `ge.toml`: Toggle (default, `true`) or Hold (`false`).
* `ge_sprint_enable = false` turns it off and gives L3 back to crouching.

This is part of the source (`src/ge_hooks.cpp` + `ge_config.toml`), so every build, on any platform, gets it. It works by raising the game's own forward-speed multiplier while sprint is on, so movement still goes through the game's normal collision.

## What changed for macOS


**SDK.** The original Windows build uses SunJaycy's modified ReXGlue SDK, which is based on v0.8.0, a version without macOS support. `rexglue-sdk-goldeneye.patch` carries all of that fork's GoldenEye changes over to ReXGlue main ("Release v0.10.1", which supports macOS). Those changes cover:

* online play
* master volume and the frame limiter
* GPU freeze fixes
* render-target and bloom fixes
* codegen fixes

Three additions were made during the port:

* The online client now uses BSD sockets on macOS and Linux. It was Windows-only before.
* `rexglue codegen` accepts `REXGLUE_CODEGEN_ARGS`, so the build always uses `--max_jump_table_entries 2048`.
* Pieces that upstream already had were dropped: the sync fences, the fullscreen default and the window-size cvars. The fork's Windows-only Direct3D 12/Vulkan auto-switch was also left out, so for Windows builds keep using the original fork.

**Game code.**

* `ge_hooks.cpp`: on macOS, Win32 raw input and `GetAsyncKeyState` are replaced by the SDK's SDL3 window events. Mouse look uses SDL relative-mouse mode, which hides and locks the cursor during play and releases it in menus or when the window loses focus. The "Save & Restart" relaunch uses `posix_spawn`, and the diagnostic watchdog uses the SDK's `QueryProtect` instead of `VirtualQuery`. The Windows code paths are unchanged.
* `ge_app.h`: inside the app bundle, the game loads its files from `Contents/Resources/assets` (or `assets/` next to the app), keeps settings in Application Support, and writes logs to `~/Library/Logs`.
* `ge_menu.cpp`: the "Graphics API" picker is hidden on macOS because Vulkan/Metal is the only backend.
* SDK defaults on macOS: `async_shader_compilation` and `vulkan_async_skip_incomplete_frames` are off. With them on, MoltenVK dropped every in-level frame (black screen with sound). MoltenVK's harmless "primitive restart" warning is also no longer logged.
* Post-FX colour grade on Vulkan: the fork's D3D12-only grade shader (brightness, contrast, saturation, vibrance, temperature, gamma, tint) is ported to a GLSL compute pass in the Vulkan presenter. With FXAA on it is folded into the FXAA pass; with FXAA off, gamma writes to the intermediate image and one extra compute pass writes the graded result. At neutral slider values (or with Post-FX off) the pass is skipped entirely.
* `CMakeLists.txt` and `CMakePresets.json`: macOS presets (`mac-arm64-*`, `mac-amd64-*`) and the `.app` bundle setup (icon and `Info.plist`).

## Known differences from the Windows build

* Mouse sensitivity may feel different from Windows because macOS reports motion differently. Adjust it in the pause menu.
* Graphics on macOS go through MoltenVK. ReXGlue's macOS support is new, so expect some rendering bugs that don't happen on Windows.
