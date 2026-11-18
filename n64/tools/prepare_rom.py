#!/usr/bin/env python3
"""Prepare a GoldenEye 007 (NTSC-U) ROM for recompilation.

The game keeps its data segment (read-only data, jump tables, RSP microcode)
compressed in the ROM. The recompiler reads jump tables from it, so this
writes a copy of the ROM with that segment decompressed and appended at
0xC00000, where the symbol file expects it. The player's ROM is not changed.

usage: prepare_rom.py <rom.z64> <out.z64>
"""
import hashlib, sys, zlib

US_SHA1 = "abe01e4aeb033b6c0836819f549c791b26cfde83"
CSEG_ROM = 0x21990       # compressed data segment ("1172" header + raw deflate)
CSEG_SIZE = 0x3C550      # decompressed size
APPEND_AT = 0xC00000

def main():
    src, dst = sys.argv[1], sys.argv[2]
    rom = bytearray(open(src, "rb").read())
    if rom[:4] == b"\x37\x80\x40\x12":    # .v64: byte-swapped
        rom[0::2], rom[1::2] = rom[1::2], rom[0::2]
    elif rom[:4] == b"\x40\x12\x37\x80":  # .n64: little-endian words
        for i in range(0, len(rom) - 3, 4):
            rom[i:i + 4] = rom[i:i + 4][::-1]
    digest = hashlib.sha1(rom).hexdigest()
    if digest != US_SHA1:
        sys.exit(f"This isn't the US (NTSC-U) GoldenEye 007 ROM (sha1 {digest}).\n"
                 f"Only the US version is supported.")
    if rom[CSEG_ROM:CSEG_ROM + 2] != b"\x11\x72":
        sys.exit("Unexpected ROM layout (no compressed data segment).")
    cseg = zlib.decompressobj(-15).decompress(bytes(rom[CSEG_ROM + 2:]))[:CSEG_SIZE]
    if len(cseg) != CSEG_SIZE:
        sys.exit("Couldn't decompress the data segment.")
    out = bytes(rom[:APPEND_AT]).ljust(APPEND_AT, b"\0") + cseg
    open(dst, "wb").write(out)

if __name__ == "__main__":
    main()
