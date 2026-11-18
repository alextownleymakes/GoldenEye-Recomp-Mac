// Tells the runtime where the recompiled functions live.
//
// GoldenEye runs most of its code from TLB-mapped addresses: the engine and
// libultra at 0x70000450 and the game at 0x7F000000. The runtime only knows
// directly mapped (0x80000000) code, and it would place every section that's
// in the first megabyte of the ROM at the 0x80000000 address matching its
// ROM offset. So only the 0x80000400 boot section goes in its table; the
// mapped sections' functions are added at their own addresses, which is
// where the game calls them (function pointers, threads) at run time.

#include <cstdint>
#include "recomp.h"
#include "funcs.h"
#include "librecomp/overlays.hpp"
#include "recomp_overlays.inl"
#include "ge64.hpp"

void ge64::register_sections() {
    static SectionTableEntry direct[ARRLEN(section_table)];
    size_t n = 0;
    for (const SectionTableEntry& s : section_table) {
        if (s.ram_addr >= 0x80000000u) {
            direct[n++] = s;
        }
    }
    recomp::overlays::register_overlays(
        { .code_sections = direct, .num_code_sections = n, .total_num_sections = num_sections },
        { .table = overlay_sections_by_index, .len = ARRLEN(overlay_sections_by_index) });
}

namespace {
    // rmonMain (0x7000CEA0), the debugger thread's entry: empty in the
    // retail game. The recompiler skips it as an OS function, but the game
    // still starts a thread there.
    void rmon_main(uint8_t* rdram, recomp_context* ctx) {}
}

void ge64::add_mapped_functions() {
    recomp::overlays::add_loaded_function((int32_t)0x7000CEA0u, rmon_main);

    for (const SectionTableEntry& s : section_table) {
        // 0x70000000 and 0x7F000000: TLB-mapped engine and game code.
        // (0x04000040 is the console's boot code, which isn't run.)
        if (s.ram_addr < 0x70000000u || s.ram_addr >= 0x80000000u) {
            continue;
        }
        for (size_t i = 0; i < s.num_funcs; i++) {
            recomp::overlays::add_loaded_function((int32_t)(s.ram_addr + s.funcs[i].offset), s.funcs[i].func);
        }
    }
}
