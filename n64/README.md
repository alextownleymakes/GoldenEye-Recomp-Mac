# GoldenEye 007 (Nintendo 64): native Mac build

This folder holds the N64 side of the project. Like the Xbox build, it
recompiles **your own ROM** into native code when you build; no game code or
data is stored here.

Only the US (NTSC-U) ROM is supported: `GoldenEye 007 (USA).z64`,
sha1 `abe01e4aeb033b6c0836819f549c791b26cfde83` (.z64, .v64 and .n64 byte
orders are all accepted).

## Building

Use the **Nintendo 64 version** section of the GoldenEye app, or run
`bash macos/build-n64.sh` (ROM in `assets/n64/`, or pass its path).

## How it works

1. **Prepare the ROM** (`tools/prepare_rom.py`): checks it's the US version
   and writes a working copy with the game's compressed data segment unpacked,
   so the recompiler can read the jump tables in it.
2. **Recompile** with [N64Recomp](https://github.com/N64Recomp/N64Recomp)
   (pinned to `598ce2080004a5672d604dceadbda436045307b7`, plus
   `patches/n64recomp-goldeneye.patch`), using `recomp/goldeneye64.toml`. The
   game's MIPS code becomes C.
3. **Recompile the audio microcode** (aspMain, which mixes the game's sound
   on the console's RSP) to C++ with RSPRecomp, using `recomp/aspMain.toml`.
4. **Build the app** (`app/`) with
   [N64ModernRuntime](https://github.com/N64Recomp/N64ModernRuntime) (the
   console's OS: threads, messages, timers, cartridge and controller access),
   [RT64](https://github.com/rt64/rt64) (graphics, drawn with Metal; patched
   by `patches/rt64-goldeneye.patch` to compile its Metal shaders at run time,
   so Xcode isn't needed) and SDL2 (window, sound, controllers).

### What the app does differently from the console

* **TLB mapping** (`app/src/memory.cpp`): GoldenEye runs its engine from
  0x70000000 through one TLB entry onto the first 4 MB of RAM, and reads and
  writes some data through both addresses. The app maps those 4 MB at both
  places in the runtime's address space, so they're the same memory. The
  game's 0x7F000000 segment is code only, which needs no mapping.
* **Boot** (`app/src/main.cpp`): the entrypoint does what `_start` does (clear
  .bss, set the stack) and calls `init()` directly, skipping `boot`, which only
  writes that TLB entry.
* **Sections** (`app/src/sections.cpp`): functions in the TLB-mapped segments
  are registered at their own addresses, for threads and function pointers.
* **Static functions** (`tools/find_static_funcs.py`): the decompilation's ELF
  has no symbols for file-local functions (about 16 KB, mostly libultra audio
  internals reached through function pointers), so they were found from jal
  targets and address constants and added to the symbol file as
  `static_<address>`.
* **Busy-waits**: the music code spins until the sequence player stops, which
  on the console the audio thread interrupts. Here game threads only switch
  when one waits, so `recomp/goldeneye64.toml` hooks those loops to let the
  other threads run.

### The symbol file

`recomp/ge007.u.syms.toml` lists each function's name, address and size. The
recompiler needs that to split the ROM's code into functions. It was exported
once from a build of the [GoldenEye 007 decompilation](https://github.com/n64decomp/007),
so a normal build only needs your ROM. To regenerate it (needs the decomp
building, MIPS binutils and the ROM): build the decomp, run
`tools/gen_func_sizes.py build/u/ge007.u.elf` for the hand-written assembly
functions' sizes, add them to the config with `elf_path`, and run
`N64Recomp goldeneye64.toml --dump-context`.

### The recompiler patch

N64Recomp assumes a jump table sits in the same section as the function using
it. GoldenEye's game code runs from TLB-mapped addresses (0x7F000000) while
its jump tables are in the directly mapped data segment (0x80020D90 up), so
the patch looks the table up in the section that actually contains it.

## Status

- [x] ROM check and preparation
- [x] Whole game recompiles to C (about 3,000 functions)
- [x] TLB mapping
- [x] Boot, through the intro and attract sequence
- [x] Graphics (RT64), sound (recompiled aspMain), controller and keyboard
- [x] macOS build script (`macos/build-n64.sh`) and its own section in the GoldenEye app
- [ ] Saves (EEPROM is set up; not checked yet)
- [ ] Settings (resolution, aspect ratio, control remapping)
