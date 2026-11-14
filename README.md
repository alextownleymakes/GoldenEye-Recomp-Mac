# GoldenEye 007 Recomp: macOS Port

A native **macOS** build of [SunJaycy's GoldenEye 007 PC Recompilation](https://github.com/SunJaycy/GoldenEye-Recomp). That project statically recompiles the Xbox 360 (XBLA) version of GoldenEye 007 into a native program. This fork makes the same tool produce a real Mac app, `GoldenEye.app`, that runs natively on Apple Silicon and Intel Macs. It's not an emulator and doesn't use Wine.

The original's features carry over: keyboard and mouse, online multiplayer, graphics settings (including every Post-FX slider) and higher frame rates. This fork adds:

* **A one-command Mac build.** Drop in your game file and run one script.
* **A self-contained app.** The game files are packed inside `GoldenEye.app`; drag it to Applications.
* **Controller support.** Xbox, PlayStation (DualSense/DualShock) and other controllers work over Bluetooth or USB.
* **Unlimited sprint (mod).** Press **L3** (or **Shift**) to sprint; it stays on until you press it again or stop moving. **R3** still crouches. Switch to hold-to-sprint under **Controls → Sprint Mode** in the pause menu.
* **Jump (mod).** Press **A** (Cross on PlayStation, Space on the keyboard) to jump; jump at a ledge or a barrier to mantle onto it (experimental). A still opens doors and confirms menus as before. Turn it off under **Controls → Jump** in the pause menu, or set `ge_jump_height` in `ge.toml`.
* **Quicksave / quickload (mod).** Emulator-style save states: click the left half of a PS4/PS5 touchpad (or press F5) to save, the right half (or F9) to load. See [Quicksave](#quicksave).
* **A Windows build script (untested).** See [Building for Windows](#building-for-windows-untested).

No game files are included or linked. You must supply the GoldenEye 007 Xbox 360 (XBLA) game files yourself.

---

## Requirements

* A Mac with Apple Silicon (M1 or later) or Intel, running **macOS 14 Sonoma or newer**
* **Xcode Command Line Tools 16+.** Install them with:
  ```sh
  xcode-select --install
  ```
* **[Homebrew](https://brew.sh).** The build script uses it to install `cmake` and `ninja` if they're missing.
* About **6 GB of free disk space** while building (the finished app is about 780 MB)
* An internet connection for the first build (the build tools are downloaded)
* **Your GoldenEye 007 XBLA package file.** It's a single large file with no extension, usually found at
  `0000000000000000/584108A9/000D0000/<long hex name>` (about 740 MB).

## Build

1. **Download this repository** with the green **Code → Download ZIP** button (or `git clone`), then unzip it.

2. **Add your game file.** Copy the large package file (the `<long hex name>` one, *not* the folders around it) into the `assets` folder:
   ```
   GoldenEye-Recomp/
   └── assets/
       └── 30BA92710985645EF623D4A6BA9E8EFFAEC62617   <- your package file
   ```
   Already-unpacked game files (`default.xex` plus its data) also work.

3. **Run the build** in Terminal:
   ```sh
   cd path/to/GoldenEye-Recomp
   bash macos/build-macos.sh
   ```
   The first build takes roughly 20–45 minutes; most of that is building the recompilation toolkit once. The script:
   1. checks your tools (and installs `cmake`/`ninja` with Homebrew if needed),
   2. downloads and builds the ReXGlue SDK with the GoldenEye changes,
   3. unpacks your game package into `assets/`,
   4. recompiles the game into native code,
   5. builds `GoldenEye.app` with your game files inside it.

   Later builds reuse the toolkit and finish in a few minutes.

## Install & play

1. Drag the finished **`GoldenEye.app`** from the project folder into **Applications**. It's self-contained, so the project folder isn't needed to play.
2. Open it. If macOS says it "can't be opened", **right-click → Open** once and confirm. The app is signed only by your own Mac, not Apple.

Once the app is built you can delete the project folder (or just `out/` and `macos/.deps/`) to free up space. Keep the folder if you want to rebuild later; it's faster.

### Controls

| Action | Controller | Keyboard / mouse |
| --- | --- | --- |
| Move | Left stick | W A S D |
| Look / aim | Right stick | Mouse |
| Fire | RT / R2 | Left click |
| Aim | LT / L2 | Right click |
| **Sprint (unlimited)** | **L3** (click left stick) | **Shift** |
| **Jump** | **A** / **Cross** | **Space** |
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
ge_sprint_speed = 1.75     # 1.0 = normal run; the game's own "full speed" is 1.25
ge_sprint_toggle = true    # false = hold to sprint (also in Controls → Sprint Mode)
ge_sprint_enable = false   # turn sprint off; L3 crouches again
```

And these control jump and mantling:

```toml
ge_jump_height = 50.0      # how high Bond jumps (game units; he's about 170 tall)
ge_jump_enable = false     # turn jump off (also in Controls → Jump)
ge_mantle_reach = 110.0    # highest ledge a jump can climb onto
ge_mantle_enable = false   # plain jumps only (also in Controls → Mantle onto ledges)
```

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

This repository does not contain any game assets, game code, ROMs, XEX files, textures, audio, or other copyrighted material. You must supply the game files yourself; none are included or linked here. Don't share built copies of `GoldenEye.app` or the `GoldenEye-Windows` folder, because the game files are inside them.

## License

Released under The Unlicense (same as the original project).
