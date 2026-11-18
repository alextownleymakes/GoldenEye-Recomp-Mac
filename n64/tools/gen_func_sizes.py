#!/usr/bin/env python3
"""Emit N64Recomp [[input.function_sizes]] entries for code symbols the ELF
lists without a size (hand-written assembly). Size = distance to the next
symbol in the same section."""
import subprocess, sys, collections
elf = sys.argv[1]
out = subprocess.run(["mips-linux-gnu-readelf", "-sW", elf], capture_output=True, text=True).stdout
by_sec = collections.defaultdict(set)
zero = []
for line in out.splitlines():
    p = line.split()
    if len(p) < 8 or not p[0].endswith(":") or p[1] == "Value":
        continue
    addr = int(p[1], 16)
    size = int(p[2], 16) if p[2].startswith("0x") else int(p[2])
    typ, ndx, name = p[3], p[6], p[7]
    if not ndx.isdigit():
        continue
    by_sec[ndx].add(addr)
    if typ == "FUNC" and size == 0:
        zero.append((name, addr, ndx))
seen = set()
for name, addr, ndx in sorted(zero, key=lambda z: z[1]):
    if name in seen:
        continue
    later = sorted(a for a in by_sec[ndx] if a > addr)
    if not later:
        continue
    size = (later[0] - addr) & ~3
    if size == 0:
        continue
    seen.add(name)
    print(f'[[input.function_sizes]]\nname = "{name}"\nsize = 0x{size:X}\n')
