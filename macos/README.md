# GoldenEye 007 Recomp — macOS build

This folder turns the project into a native macOS app (`GoldenEye.app`) for Apple Silicon (M1/M2/M3/M4) or Intel Macs. Graphics run on Metal through MoltenVK (the SDK's Vulkan backend), so there's no emulator and no Wine.

## What you need

* macOS 14 or newer, with the **Xcode 16+ Command Line Tools** (`xcode-select --install`). The full Xcode app isn't required.
* CMake and Ninja: used from Homebrew if installed, otherwise downloaded once into `macos/.deps/tools` (no Homebrew needed).
* The GoldenEye 007 (XBLA) game files, which you supply yourself. Either copy the packed download (the single extensionless file, e.g. `30BA9271…`) into `assets/`, or pass its path to the script; it gets unpacked automatically. Already-unpacked files (`assets/default.xex` + data) work too.
* About **4–6 GB of free disk space** while building, plus an internet connection on the first run (the SDK and its dependencies are downloaded). Afterwards you can delete `macos/.deps/` and `out/` to get that space back; only `GoldenEye.app` is needed to play.

## Build

The easy way: double-click the **GoldenEye** app. On first launch it offers to move itself to Applications and the project to `~/Library/Application Support/GoldenEye/Project` (choose **Keep It Here** to work on the code in place). It installs what's missing, asks for your game files (and remembers them), builds with a progress bar, and checks GitHub for updates. See the main README for the one-time macOS security step.

From Terminal:

```sh
cd ~/Downloads/GoldenEye-Recomp-main
bash macos/build-macos.sh
# or point it at the packed game file directly:
bash macos/build-macos.sh ~/Downloads/GoldenEye_007_XBLA_Retail/0000000000000000/584108A9/000D0000/30BA92710985645EF623D4A6BA9E8EFFAEC62617
```

The first run takes a while. The SDK build alone is roughly 15–40 minutes on an M-series Mac, and later runs reuse it. When the script finishes, the game is in `~/Library/Application Support/GoldenEye/Games/GoldenEye.app`; open the GoldenEye app and click **Play GoldenEye**. Set `GE_APP_DIR=/some/folder` to put the built game somewhere else.

Options:

| Variable | Effect |
| --- | --- |
| `CONFIG=RelWithDebInfo` | Build with debug symbols. `Release` is the default. |
| `ARCH=x86_64` | Force an Intel build. By default the script builds for this Mac's architecture. |
| `CLEAN=1` | Wipe the previous game build first. |
| `REXSDK_DIR=/some/path` | Keep the SDK checkout somewhere other than `macos/.deps/`. |

## Run

The build produces a self-contained game app (in `~/Library/Application Support/GoldenEye/Games`, or in `GE_APP_DIR`). Your game files are copied inside it (`Contents/Resources/assets`), as APFS clones, so they take no extra disk space. Play it from the GoldenEye app, or open the game app directly.

* Settings: `~/Library/Application Support/GoldenEye/ge.toml`
* Logs: `~/Library/Logs/GoldenEye/`, also viewable in Console.app
* The project's `assets/` folder is only needed for rebuilding. If no files are bundled in the app, it falls back to an `assets` folder next to the game app.

If macOS says the app "can't be opened", right-click it, choose **Open**, then confirm. The app is signed ad hoc because it was built on your Mac.

## Sprint (mod)

Press **L3** (click the left stick) to sprint while moving forward. By default it toggles: it stays on until you press L3 again or stop moving. It's unlimited, with no stamina. R3 still crouches. On keyboard, sprint is **Shift**, rebindable in the pause menu's key bindings, and **C** (L3) still crouches.

* `ge_sprint_speed` in `ge.toml` sets how fast (default `2.0`; normal running is 1.0 and the game's own "full speed" after 3 seconds is 1.25).
* **Sprint Mode** (pause menu → Controls), or `ge_sprint_toggle` in `ge.toml`: Toggle (default, `true`) or Hold (`false`).
* Sprint is part of **Modern controls** (pause menu → Controls), or `ge_modern_controls = false`; turning that off gives L3 back to crouching.

## Jump (mod)

Press **A** (Cross on PlayStation, **Space** on the keyboard) to jump. With Modern controls on, A only jumps in gameplay: doors and other actions move to **X / Square**, reload to **B / Circle**, and **Y / Triangle** swaps weapons. Menus keep the original buttons. Bond jumps and falls with the game's own falling physics, including the small dip on landing.

* `ge_jump_height` in `ge.toml` sets how high (default `85`; Bond is about 170 units tall).
* **Modern controls** (pause menu → Controls), or `ge_modern_controls = false` in `ge.toml`, turns jump, mantling and sprint off together and restores the original buttons.

**Mantling.** Jump while facing something with a flat top within reach and Bond climbs onto it. In the air after a jump (or holding A) he also grabs any ledge that comes within about three-quarters of his height above his feet, so you can jump across a gap onto something. That covers raised floor and ledges, solid level pieces like the Dam's concrete barriers, bunkers and low walls, and objects like desks, crates and drums. The top has to be higher than a step and no taller than Bond himself by default, wide enough to stand on, with nothing in the way over the edge and room above it. Up to half his height he hops up with the game's own physics; anything taller he pulls himself up onto in a steady climb, with the view dipping toward the ledge and coming back up as he gets over.

Railings and anything else too thin to stand on get vaulted instead: jump at one and he goes over and lands on the other side (on stair landings, ship decks, watchtowers). Walking off the edge of anything he's standing on sets him down a body-width clear of it.

Once he's on a barrier or an object he can walk around on it, jump, and drop off the edge back onto the floor. Shoot the desk he's standing on until it blows up and he falls. Those tops aren't part of the game's walkable floor, so while he's up there this mod moves him: walls come from the same collision bullets use, and objects from their own collision shapes. He goes back to the game's movement as soon as he steps onto real floor. He can't step off a top onto ground the normal game doesn't let you walk on; that edge acts like a wall.

* `ge_mantle_reach` in `ge.toml` sets the highest top he can climb, in percent of his height (default `100`).

**Free movement (on by default).** **Free movement** (pause menu → Controls), or `ge_free_move = false` to turn it off, keeps the game's own movement while Bond is on the floor map (so stairs, ramps and ladders work as in the original) and switches to real collision wherever the original would stop him or he's off the floor map. Walls, doors, glass, guards and objects block him exactly where they are; he can walk, jump and drop between floor, barriers, crates and desks with no transitions; and he only stops at a drop deeper than about four times his height or into nothing. The floor map is still followed in the background so the right rooms are drawn and guards know where he is. Because the movement code is this mod's rather than Rare's, sliding along walls won't feel exactly like the original, and it may let you reach places the levels weren't built for. Turn it off for the original movement (mantling then works with a hand-off at the edges of what you climb).

If anything misbehaves, the log has `GEMANTLE` lines.

## Quicksave (mod)

Touchpad left half / F5 saves, right half / F9 loads (one slot, `quicksave.gestate` in Application Support). How it works, since a recompiled game can't simply be frozen like an emulator:

* Part of a recompiled game's state is the host call stack of each thread, which can't be copied. So snapshots are only taken, and only restored, at a safe point: the game thread at its per-frame input poll (`ge_inject_keyboard`), with every other guest thread parked inside a kernel wait.
* The SDK (`src/system/ge_savestate.cpp`) counts threads running guest code: every host-to-guest entry and every blocking kernel wait reports in, and while a snapshot runs, a gate holds anything trying to re-enter guest code.
* A snapshot holds all guest memory (page tables and contents, zero pages skipped, LZ4-compressed on macOS), every running guest thread's registers, kernel event/semaphore state and file positions, the GPU ring position, XMA decoder bookkeeping, and guest time.
* A load is only applied if every thread is parked exactly where it was saved (same stack pointer and return address) and the game thread got to the poll through the same call chain; otherwise it retries for a few seconds and gives up with a message. After a restore, GPU caches of guest memory are dropped, XMA decoders restart, and guest time is set back to the saved moment.
* The PS4/PS5 touchpad click is taken in the SDK's SDL input driver (it was mapped to Guide before and ignored); which half was pressed comes from the finger position.

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

## Minimap (mod)

A circular minimap sits in the bottom-right corner. It's drawn from the level's own floor map, so it shows the walkable floor and walls of the floor Bond is on, plus the footprints of objects at his level (crates, desks, vehicles, doors), turning and sliding around him (he's the white arrow in the middle, always facing up).

* **Red dots:** guards (only living ones).
* **Grey X:** things on the ground: weapons, keys, body armour.
* **Yellow squares:** ammo boxes and magazines.
* **Green diamond:** the next objective (the first one not yet done on your difficulty): the thing to destroy, collect or photograph, or the place to go. It sticks to the edge of the map when it's further away. Objectives that complete from a scripted event with no place in the level (e.g. "minimize civilian casualties") have nothing to point at.

Turn it off or change how far it shows under **Video → Minimap** in the pause menu, or `ge_minimap = false` / `ge_minimap_range = 1200` in `ge.toml`. It's hidden while the watch is up.
