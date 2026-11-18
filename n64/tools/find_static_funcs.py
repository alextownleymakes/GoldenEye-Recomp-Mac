#!/usr/bin/env python3
"""Add GoldenEye's static (file-local) functions to the symbol file.

The decompilation's ELF has no symbols for static functions (IDO doesn't emit
them), so the symbol file exported from it leaves holes in the code: about
16 KB, mostly libultra's audio player and synthesizer internals, which the game
reaches through function pointers. This finds the functions in those holes and
adds them as static_<address> entries.

A function start is:
  * the target of a jal anywhere in the code,
  * an address built with lui/addiu (a function pointer) that follows the
    end of another function (jr ra + delay slot) or the start of a hole,
  * the start of a hole that isn't padding.
Each one runs to the next start or the end of the hole.

usage: find_static_funcs.py <ge007.u.syms.toml> <rom.z64> [--write]
"""
import re, struct, sys

# (.inflate is left out: the end of that segment is its data tables.)
CODE_SECTIONS = (".code", ".game")

def load_syms(path):
    secs = []
    cur = None
    for line in open(path):
        if line.startswith("[[section]]"):
            cur = {"funcs": []}
            secs.append(cur)
            continue
        m = re.match(r'(name|rom|vram|size) = (.*)', line.strip())
        if m and cur is not None and m.group(1) not in cur:
            v = m.group(2).strip('"')
            cur[m.group(1)] = int(v, 16) if v.startswith("0x") else v
        m = re.search(r'name = "([^"]+)", vram = (0x[0-9A-Fa-f]+), size = (0x[0-9A-Fa-f]+)', line)
        if m and cur is not None:
            cur["funcs"].append((int(m.group(2), 16), int(m.group(3), 16), m.group(1)))
    return secs

def main():
    syms_path, rom_path = sys.argv[1], sys.argv[2]
    write = "--write" in sys.argv
    rom = open(rom_path, "rb").read()
    secs = [s for s in load_syms(syms_path) if s["name"] in CODE_SECTIONS]

    def word(vram):
        for s in secs:
            if s["vram"] <= vram < s["vram"] + s["size"]:
                off = s["rom"] + vram - s["vram"]
                return struct.unpack(">I", rom[off:off + 4])[0]
        return None

    # Holes: [start, end) ranges inside code sections with no function.
    holes = []
    for s in secs:
        pos = s["vram"]
        end = s["vram"] + s["size"]
        for v, sz, _ in sorted(s["funcs"]) + [(end, 0, None)]:
            if v > pos:
                holes.append((pos, v))
            pos = max(pos, v + sz)
    def in_hole(a):
        return any(h0 <= a < h1 for h0, h1 in holes)

    starts = set()
    # Scan all code for jal targets and lui/addiu address pairs.
    for s in secs:
        base = s["vram"]
        n = s["size"] // 4
        words = [word(base + i * 4) for i in range(n)]
        for i, w in enumerate(words):
            op = w >> 26
            if op == 3:  # jal
                t = (base & 0xF0000000) | ((w & 0x3FFFFFF) << 2)
                if in_hole(t):
                    starts.add(t)
            elif op == 0x0F:  # lui rt, hi
                rt = (w >> 16) & 31
                hi = (w & 0xFFFF) << 16
                for w2 in words[i + 1:i + 10]:
                    op2 = w2 >> 26
                    rs2 = (w2 >> 21) & 31
                    if op2 == 9 and rs2 == rt:  # addiu x, rt, lo
                        lo = w2 & 0xFFFF
                        a = (hi + (lo - 0x10000 if lo & 0x8000 else lo)) & 0xFFFFFFFF
                        if in_hole(a) and a % 4 == 0:
                            prev2 = word(a - 8)
                            if any(a == h0 for h0, _ in holes) or prev2 == 0x03E00008 or word(a - 4) == 0:
                                starts.add(a)
                        break
                    if (w2 >> 16) & 31 == rt and op2 not in (9,):  # rt overwritten
                        if op2 in (0x0F, 0x08, 0x0D, 0x23):
                            break

    new_funcs = {}
    for h0, h1 in holes:
        # Skip pure padding.
        if all((word(a) or 0) == 0 for a in range(h0, h1, 4)):
            continue
        hs = sorted(a for a in starts if h0 <= a < h1)
        first = h0
        while first < h1 and word(first) == 0:
            first += 4
        if not hs or hs[0] > first:
            hs.insert(0, first)
        for i, a in enumerate(hs):
            e = hs[i + 1] if i + 1 < len(hs) else h1
            while e > a + 4 and word(e - 4) == 0 and word(e - 8) != 0x03E00008:
                e -= 4
            sec = next(s for s in secs if s["vram"] <= a < s["vram"] + s["size"])
            new_funcs.setdefault(sec["name"], []).append((a, e - a))

    total = sum(sz for fl in new_funcs.values() for _, sz in fl)
    print(f"{sum(len(v) for v in new_funcs.values())} static functions, {total:#x} bytes")
    for name, fl in new_funcs.items():
        for a, sz in fl:
            print(f"  {name} static_{a:08X} size {sz:#x}")
    if not write:
        return

    # Insert into the symbol file, keeping each section's list sorted.
    lines = open(syms_path).read().split("\n")
    out = []
    section = None
    pending = []
    def flush():
        nonlocal pending
        out.extend(pending)
        pending = []
    for line in lines:
        if line.startswith("[[section]]"):
            section = None
        m = re.match(r'name = "(.*)"', line.strip())
        if m and section is None and line.startswith("name"):
            section = m.group(1)
        m = re.search(r'\{ name = "([^"]+)", vram = (0x[0-9A-Fa-f]+), size = (0x[0-9A-Fa-f]+) \},?', line)
        if m and section in new_funcs:
            v = int(m.group(2), 16)
            while new_funcs[section] and new_funcs[section][0][0] < v:
                a, sz = new_funcs[section].pop(0)
                out.append(f'    {{ name = "static_{a:08X}", vram = 0x{a:08X}, size = 0x{sz:X} }},')
        if line.strip() == "]" and section in new_funcs:
            for a, sz in new_funcs.pop(section):
                out.append(f'    {{ name = "static_{a:08X}", vram = 0x{a:08X}, size = 0x{sz:X} }},')
        out.append(line)
    for name in new_funcs:
        new_funcs[name].sort()
    open(syms_path, "w").write("\n".join(out))

if __name__ == "__main__":
    main()
