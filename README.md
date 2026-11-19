# GoldenEye 007 Recomp: macOS Port

A native **macOS** build of [SunJaycy's GoldenEye 007 PC Recompilation](https://github.com/SunJaycy/GoldenEye-Recomp). That project statically recompiles the Xbox 360 (XBLA) version of GoldenEye 007 into a native program. This fork makes the same tool produce a real Mac app, `GoldenEye.app`, that runs natively on Apple Silicon and Intel Macs. It's not an emulator and doesn't use Wine.

The original's features carry over: keyboard and mouse, online multiplayer, graphics settings (including every Post-FX slider) and higher frame rates. This fork adds:

* **A one-command Mac build.** Drop in your game file and run one script.
* **One app to build and play.** The GoldenEye app builds the game from your files, keeps it inside itself, and plays it with one click.
* **Controller support.** Xbox, PlayStation (DualSense/DualShock) and other controllers work over Bluetooth or USB.
* **Modern controls (mod, on by default).** One switch under **Controls → Modern controls** in the pause menu turns on sprint, jump and mantling, and the modern button layout in gameplay: **A / Cross** jumps, **X / Square** opens doors and uses things, **B / Circle** reloads, **Y / Triangle** swaps weapons. Menus keep the original buttons. Off = the original game's controls.
* **No auto-centering view (mod).** Moving no longer eases the view back to level; it stays where you last aimed. Turn the original behaviour back on under **Controls → Auto-center view when moving** (`ge_auto_center_view = true`).
* **Unlimited sprint (mod).** Press **L3** (or **Shift**) to sprint; it stays on until you press it again or stop moving. **R3** still crouches. Switch to hold-to-sprint under **Controls → Sprint Mode** in the pause menu.
* **Jump (mod).** Press **A** (Cross on PlayStation, Space on the keyboard) to jump; jump at a ledge, barrier or object to mantle onto it, or at a railing to vault it. Free movement (on by default) uses real collision instead of the floor map, so you can walk across barriers, crates and desks (see [Movement and collision](#movement-and-collision-mod)). Doors and other actions are on **X / Square**. Set `ge_jump_height` in `ge.toml` to change the jump.
* **Minimap (mod).** A circular map in the bottom-right corner, built from the level's own floor map: Bond in the middle facing up, walls, floors and objects (crates, desks, vehicles, doors) around him on his floor, guards as red dots, items on the ground as grey X's, ammo as yellow squares, and the next objective's target in green (pinned to the edge when it's off the map). Toggle it and set its range under **Video → Minimap** in the pause menu (`ge_minimap`, `ge_minimap_range` in `ge.toml`).
* **Quicksave / quickload (mod).** Emulator-style save states: click the left half of a PS4/PS5 touchpad (or press F5) to save, the right half (or F9) to load. See [Quicksave](#quicksave).
* **A Windows build script (untested).** See [Building for Windows](#building-for-windows-untested).

No game files are included or linked. You must supply the GoldenEye 007 Xbox 360 (XBLA) game files yourself.

---

## Requirements

* A Mac with Apple Silicon (M1 or later) or Intel, running **macOS 14 Sonoma or newer**
* About **6 GB of free disk space** while building (the finished app is about 780 MB)
* An internet connection for the first build (the build tools are downloaded)
* Your own copy of the game, for either version (or both):
  * **Xbox 360 version:** the GoldenEye 007 XBLA package, a single large file with no extension (about 740 MB), usually found at
    `0000000000000000/584108A9/000D0000/<long hex name>`. A folder with the already-unpacked files (`default.xex` plus its data) also works.
  * **Nintendo 64 version:** a GoldenEye 007 **(USA)** ROM (`.z64`, `.v64` or `.n64`). The N64 version is new: it's the original game recompiled to run natively, with graphics through [RT64](https://github.com/rt64/rt64). Expect rough edges.

Everything else (Apple's developer tools, CMake, Ninja) is installed for you the first time.

## Build (no Terminal needed)

1. **Download this project** with the green **Code → Download ZIP** button on GitHub, and unzip it (double-click the ZIP).

2. **Open the `GoldenEye` app** in the project folder (double-click it). The first time, macOS blocks it because it isn't from the App Store or an identified developer. To allow it (once):

   **macOS 15 Sequoia and newer**
   1. Double-click **GoldenEye**. A message says Apple couldn't verify it. Click **Done** (not Move to Trash).
   2. Open **System Settings → Privacy & Security** and scroll to the bottom.
   3. Next to *"GoldenEye" was blocked to protect your Mac*, click **Open Anyway**.
   4. Confirm with **Open Anyway** again and your password or Touch ID.

   **macOS 14 Sonoma**
   1. **Right-click** (or Control-click) **GoldenEye** and choose **Open**.
   2. Click **Open** in the message that appears.

   After that it opens normally with a double-click.

   The first time it opens, it offers to **move itself into Applications** and the rest of the project into `~/Library/Application Support/GoldenEye`. Click **Move**, and the downloaded folder (and the ZIP) can be deleted. From then on, open GoldenEye from Applications or Launchpad. (Click **Keep It Here** instead if you want to keep working in the downloaded folder, for example to change the code.)

3. **If asked, install Apple's developer tools.** The first time, the app asks macOS to install the free *command line developer tools*. Click **Install**, wait for it to finish (usually 5–15 minutes), then open GoldenEye again.

4. **Choose your game files.** The builder has a section for each version:
   * **Xbox 360 version:** click **Choose…** and select the XBLA package file (or a folder containing `default.xex`).
   * **Nintendo 64 version:** click **Choose…** and select your ROM. A ROM already in the project's `assets/n64` folder is used automatically.

   The builder remembers each choice for next time.

5. **Click Build** in that version's section (**Build GoldenEye** or **Build GoldenEye 64**). The progress bar shows each step. The first Xbox build takes a while (often 30–60 minutes), most of it building the recompiler once; later builds take a few minutes. When it's done, click **Play** in the same section.

**Updates.** Each time it opens, the app checks GitHub for a newer version of this project. When there is one, click **Update**, then build again to get the changes.

If a build fails, the app shows what went wrong. The full log is in your user folder under **Library/Logs/GoldenEye** (`builder.log` for the Xbox version, `builder-n64.log` for the N64 version).

## Play

The same app is where you play. Click **Play GoldenEye** or **Play GoldenEye 64**: its window steps aside while the game runs and comes back when you quit it, so you can switch versions or rebuild.

The built games are kept in `~/Library/Application Support/GoldenEye/Games`, and the project in `~/Library/Application Support/GoldenEye/Project` (unless you chose to keep it where you downloaded it). To keep GoldenEye in the Dock, open it, then right-click its Dock icon and choose **Options → Keep in Dock**.

Once the games are built they don't need the project folder. **Free Up Space** (bottom right) deletes the build leftovers, several GB; the games stay playable and the next build just takes longer. If the project folder is gone altogether, the app still plays the built games, and offers to download the project again (or locate it) when you want to rebuild or update.

### N64 version controls

| N64 | Controller | Keyboard |
| --- | --- | --- |
| Stick (move, turn) | Left stick | W / S, Left / Right arrows |
| C buttons (look, strafe) | Right stick | Up / Down arrows, A / D |
| Z (fire) | Right trigger | Space |
| R (aim) | Left trigger or right bumper | Left Shift |
| A (next weapon) | Cross / A or Triangle / Y | Q |
| B (use, reload) | Circle / B or Square / X | E |
| L | Left bumper | |
| Start | Start / Options | Return |
| Full screen | | F11 or Cmd+F |

### Building from Terminal (optional)

The builder runs `macos/build-macos.sh` (Xbox) or `macos/build-n64.sh` (N64), which you can also run yourself:
```sh
cd path/to/GoldenEye-Recomp-Mac
bash macos/build-macos.sh /path/to/your/game/package   # or with the game files already in assets/
bash macos/build-n64.sh "/path/to/GoldenEye 007 (USA).z64"   # or with the ROM in assets/n64/
```

Run from Terminal, the scripts put the games in the same place, `~/Library/Application Support/GoldenEye/Games` (set `GE_APP_DIR` to put them elsewhere).

To free up space after building, you can delete `out/` and `macos/.deps/`; the next build just takes longer.

### Controls

| Action | Controller | Keyboard / mouse |
| --- | --- | --- |
| Move | Left stick | W A S D |
| Look / aim | Right stick | Mouse |
| Fire | RT / R2 | Left click |
| Aim | LT / L2 | Right click |
| **Sprint (unlimited)** | **L3** (click left stick) | **Shift** |
| **Jump** | **A** / **Cross** | **Space** |
| **Action** (doors, computers) | **X** / **Square** (Modern controls; A when off) | **R** |
| **Reload** | **B** / **Circle** (Modern controls; X when off) | **Control** |
| Swap weapon | Y / Triangle | E |
| **Quicksave / quickload** | **Touchpad** left half / right half (PS4/PS5) | **F5** / **F9** |
| Crouch | R3 | C / V |
| Pause | Start | Return |
| Recomp settings menu | — | Esc |

Pair a PS5 or Xbox controller under **System Settings → Bluetooth**; it's detected automatically. While a controller is connected the mouse is ignored completely (no mouse-look, no cursor capture, mouse buttons do nothing), so it can't interfere with the controller or auto-aim. Keyboard keys can be rebound in the Esc menu.

### Quicksave

One quick slot, like an emulator's save states. Click the **left half** of the PS4/PS5 touchpad (or press **F5**) to save, the **right half** (or **F9**) to load. A message at the top of the screen confirms it. The save is kept on disk (`~/Library/Application Support/GoldenEye/quicksave.gestate`), so it survives quitting.

Unlike an emulator, a recompiled game can only be frozen at a quiet moment, so:

* Saving and loading happen at the next safe frame (usually instantly; it retries for a few seconds and tells you if it can't).
* A quicksave can only be loaded in the same part of the game it was made in (e.g. during gameplay, not from the title menu), and it may refuse after a level change or after restarting the app.
* Expect a brief audio blip on load. Off during online play. Turn it off in **Esc → Input → Quicksave**.

This is new; if a load misbehaves, the log (see below) has `GESTATE` lines explaining why.

### Settings and logs

* Settings are saved in `~/Library/Application Support/GoldenEye/ge.toml`. You can change most of them from the in-game menu.
* Logs are written to `~/Library/Logs/GoldenEye/` and can also be read in Console.app.

These `ge.toml` options control sprint:

```toml
ge_sprint_speed = 2.0      # 1.0 = normal run; the game's own "full speed" is 1.25
ge_sprint_toggle = true    # false = hold to sprint (also in Controls → Sprint Mode)
ge_modern_controls = false # original controls: no sprint, jump or mantle; A opens doors
```

And these control jump and mantling:

```toml
ge_jump_height = 85.0      # how high Bond jumps (game units; he's about 170 tall)
ge_mantle_reach = 100.0    # highest thing he can climb, % of Bond's height
ge_free_move = false       # original movement (also in Controls → Free movement)
```

## Movement and collision (mod)

This build replaces how GoldenEye decides where Bond can go. **Free movement** is on by default; turning it off (**Controls → Free movement** in the pause menu, or `ge_free_move = false` in `ge.toml`) gives back the original system exactly.

### What the original game does

Everything about Bond's movement comes from the level's **floor map** (the "stan" data): a flat mesh of walkable floor tiles, each with a height.

* **Walls** aren't solid geometry to the game. A wall is just an edge of the floor map with no tile on the other side. Bond can't cross it, whatever is (or isn't) drawn there, which is also where every invisible wall comes from.
* **Height** comes from the tile he's on. Stairs are sloped tiles and ladders are almost-vertical tiles. Bond can't stand on anything that isn't a floor tile, so barriers, bunkers, crates and desks are only obstacles, never things to stand on.
* **Objects** (crates, desks, doors, guards, glass) block him using each object's own collision shape: a footprint plus a top and bottom height, measured against the floor tile under him.
* **Rooms**, meaning what gets drawn and which objectives trigger, follow the tile he's on. Guards find and chase him through the same floor map.

### What free movement does instead

**On the floor map, Bond moves exactly as in the original.** While he's standing inside the floor tile he's on, the game's own movement runs: it walks him from tile to tile across shared edges, his height is the tile's surface, and objects block him as before. Stairs are smooth ramps again and ladders climb the original way. Free movement only takes over where the original would stop him (an edge of the floor map, or an object) and whenever he's off the floor map: on a crate, a barrier, a ledge, or in the air.

When free movement takes over:

* **Walls come from the real level geometry:** the collision mesh the Xbox 360 version uses for bullets. Bond is stopped by what's actually there: rays at knee and chest height along each move, fanned out to the sides of his body. Upward-facing surfaces don't count as walls, and he slides along walls he's pressed against.
* **Objects** still block him with their own collision shapes, now tested against his actual height rather than the floor tile's.
* **Ground** is the highest flat surface under him within a step (30 units) of his feet. That can be a floor tile, a flat part of the level mesh (barrier tops, bunker roofs, wall tops) or an object's top (crates, desks, drums). Where the spot is still reachable across the floor map from his tile, that tile's surface is used, as in the original. Anything higher is a wall; anything lower, he drops onto with the game's own falling and landing.
* **Edges:** he won't step into a drop deeper than 800 units (about 4½ times his height) or into nothing at all. Walking off something sets him down a body-width clear of it. The floor map's invisible walls no longer stop him where the real geometry is open.
* **The floor map is still followed in the background** for what it does besides walls. The tile under Bond is kept up to date, so rooms, objectives and guards keep working.
* **It steps aside** in the tank, in cutscenes and while a scripted tile swap is in progress.

### Jumping and mantling

Jump and mantle are part of the same mod. Jump at anything with a flat top up to Bond's height and he climbs onto it: a hop for things up to half his height, a pull-up with a dip of the view above that. Jump at something too thin to stand on, like a railing, and he vaults it and lands on the other side. In the air after a jump (or holding A), he grabs any ledge that comes within about three-quarters of his height above his feet, so he can jump across gaps onto things. With free movement off, mantling still works, and this mod moves him while he's on a top that isn't a floor tile, handing him back to the game when he steps onto real floor.

### Known issues

* Free movement can take Bond places the levels were never built for, such as the "secret island" on the Dam. The game can freeze shortly after he lands somewhere with no floor map at all, because it loses track of which room he's in.
* Wall sliding and corners are this mod's, not Rare's, so they won't feel identical to the original.

The code is in `src/ge_hooks.cpp` (search for `JUMP / MANTLE / FREE MOVEMENT`). Every collision step that blocks Bond is logged as `GEMANTLE blocked (...)` with the reason, the surface that was hit and which way it faces.

## Online

To play online, someone needs to run a server.

1. Open `ESC → ONLINE`.
2. Enter your username, the server address and the port.
3. Enable online play.
4. Save and restart.
5. Host or join a match.

## Troubleshooting

* **"No game files found"**: put the package file (or `default.xex`) inside `assets/`. It can be in subfolders.
* **"Need Apple clang 16 or newer"**: update the Command Line Tools from **System Settings → Software Update**, or reinstall them with `xcode-select --install`.
* **The level is black but sound plays**: make sure `ge.toml` doesn't set `async_shader_compilation` or `vulkan_async_skip_incomplete_frames` to `true`. The Mac build turns both off by default.
* **Free disk space drops by a few GB after building**: that's macOS swap from the compile, not files the build keeps. Restarting the Mac frees it. The script already compiles fewer files at once on Macs with 16 GB of memory or less; `JOBS=2 ./macos/build-macos.sh` lowers it further.
* **Anything else**: check the newest log in `~/Library/Logs/GoldenEye/` and include it when you report the issue.

## Known differences from Windows

* Graphics run on Metal through MoltenVK. The Mac support in the recompilation SDK is new, so rendering bugs that Windows doesn't have are possible.
* Mouse sensitivity may feel different from Windows; adjust it in the pause menu.

Technical details about the port (the SDK patch, what changed and why) are in [`macos/README.md`](macos/README.md).

## Building for Windows (untested)

> **Untested.** The Windows build script was written alongside the Mac one but has never been run, because I don't own a PC. It follows the same steps as the Mac build, but expect it may need further work. If you try it, please open an issue with what happened (and the error output if it failed).

This fork builds against a newer ReXGlue SDK with the GoldenEye changes applied as a patch, so the original project's Windows instructions no longer apply as-is. Use `windows\build-windows.bat` instead. It builds the same game, including the sprint mod and its settings.

**Requirements**

* 64-bit Windows 10 or 11 on an x64 PC
* **Build Tools for Visual Studio 2022** with the **Desktop development with C++** workload
* **LLVM (clang) 19+**, **CMake 3.25+**, **Ninja** and **Git**

If `winget` is available (it is on current Windows 10/11), the script installs any of these that are missing. Otherwise install them yourself and re-run.

**Build**

1. Copy your GoldenEye XBLA package file into the `assets\` folder (anywhere inside it, like on Mac).
2. Open a terminal in the project folder and run:
   ```bat
   windows\build-windows.bat
   ```
   or pass the package path directly: `windows\build-windows.bat C:\path\to\<long hex name>`.

The first run downloads and builds the SDK (about 15–40 minutes). It keeps the SDK in `%LOCALAPPDATA%\GoldenEye-Recomp\rexglue-sdk`, a short path because Windows has trouble with very long ones. Later runs reuse it.

The result is a `GoldenEye-Windows\` folder containing `GoldenEye.exe`, its DLLs and the game files. It's self-contained, so you can move it anywhere. Run `GoldenEye.exe`. Settings (`ge.toml`) and `logs\` are written next to it, and rebuilding keeps your `ge.toml`.

Options (PowerShell): `-Config RelWithDebInfo`, `-SdkDir <path>`, `-Clean`, for example
`powershell -ExecutionPolicy Bypass -File windows\build-windows.ps1 -Clean`.

## Credits

* **SunJaycy**: the original GoldenEye 007 PC recompilation and its modified ReXGlue SDK
* **[ReXGlue SDK](https://github.com/rexglue/rexglue-sdk)**: the Xbox 360 recompilation toolkit (with macOS support)
* **BeanTools Community Edition**: GoldenEye XBLA bug fixes included in the original
* **[n64decomp/007](https://github.com/n64decomp/007)**: the N64 decompilation, used as a reference for the sprint mod

## Legal

This repository does not contain any game assets, game code, ROMs, XEX files, textures, audio, or other copyrighted material. You must supply the game files yourself; none are included or linked here. Don't share the GoldenEye app after building with it, built copies of `GoldenEye.app`, or the `GoldenEye-Windows` folder, because the game files are inside them.

## License

Released under The Unlicense (same as the original project).
