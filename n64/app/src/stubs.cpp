// Stand-ins for the console functions GoldenEye calls that the runtime
// doesn't provide (and that the recompiler was told to skip).

#include <cstdint>
#include <cstdio>
#include "recomp.h"
#include "librecomp/game.hpp"

extern "C" {

// init(): sets up the TLB context register for the miss handler. Mapping is
// done in memory.cpp instead.
void initTLBPrepareContext(uint8_t* rdram, recomp_context* ctx) {}

// init() frees TLB entries 2-31; nothing is mapped through them here.
void osUnmapTLB_recomp(uint8_t* rdram, recomp_context* ctx) {}

// Only the debug/crash code reads TLB registers.
void __osGetTLBHi_recomp(uint8_t* rdram, recomp_context* ctx) {
    ctx->r2 = 0;
}

// The crash handler asks which thread faulted; none does here.
void __osGetCurrFaultedThread(uint8_t* rdram, recomp_context* ctx) {
    ctx->r2 = 0;
}

// Timer interrupts are handled by the runtime's own timer thread.
void __osTimerInterrupt_recomp(uint8_t* rdram, recomp_context* ctx) {}

// Used by the remote debugger (rmon) thread only.
void __osEnqueueThread_recomp(uint8_t* rdram, recomp_context* ctx) {}

// long long -> double (IDO helper). The value arrives split across a0/a1.
void __ll_to_d_recomp(uint8_t* rdram, recomp_context* ctx) {
    int64_t a = (int64_t)(((uint64_t)ctx->r4 << 32) | ((uint64_t)ctx->r5 & 0xFFFFFFFFu));
    ctx->f0.d = (double)a;
}

// osDpGetCounters(u32 counters[4]): the profiler's RDP counters.
void osDpGetCounters_recomp(uint8_t* rdram, recomp_context* ctx) {
    for (int i = 0; i < 4; i++) {
        MEM_W(i * 4, ctx->r4) = 0;
    }
}

// osPfsInit: no Controller Pak (GoldenEye saves to the cartridge EEPROM).
void osPfsInit_recomp(uint8_t* rdram, recomp_context* ctx) {
    ctx->r2 = 1;  // PFS_ERR_NOPACK
}

// osPiReadIo(devAddr, &data): one word from the cartridge.
void osPiReadIo_recomp(uint8_t* rdram, recomp_context* ctx) {
    uint32_t physical = (uint32_t)ctx->r4 & 0x1FFFFFFFu;
    recomp::do_rom_pio(rdram, ctx->r5, physical);
    ctx->r2 = 0;
}

// OS internals called only from libultra's own static helpers (the VI
// manager thread, thread switching, Controller Pak addressing), which the
// runtime replaces. Logged in case anything reaches them.
#define GE64_UNUSED_OS_FUNC(name) \
    void name(uint8_t* rdram, recomp_context* ctx) { \
        fprintf(stderr, "[GE64] unexpected call to " #name "\n"); \
        ctx->r2 = 0; \
    }
GE64_UNUSED_OS_FUNC(__osViSwapContext_recomp)
GE64_UNUSED_OS_FUNC(__osViGetCurrentContext_recomp)
GE64_UNUSED_OS_FUNC(__osPopThread_recomp)
GE64_UNUSED_OS_FUNC(__osContAddressCrc_recomp)

}
