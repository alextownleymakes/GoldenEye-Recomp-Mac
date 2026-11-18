// GoldenEye's TLB mapping.
//
// boot.s maps virtual 0x70000000-0x703FFFFF onto physical RAM 0-0x3FFFFF
// with one TLB entry, so the engine (0x70000450) and the inflate code and
// tables (0x70200000) are the same memory as 0x80000000-0x803FFFFF. The game
// writes data through one address and reads it through the other (init()
// copies the compressed data and inflate tables to 0x701xxxxx-0x702xxxxx).
//
// The runtime turns guest address A into rdram + (A - 0x80000000), so a
// 0x70xxxxxx address lands at rdram + 0xF0000000. Mapping the first 4 MB of
// RDRAM there as well makes both addresses reach the same bytes, like the TLB
// entry does.
//
// (The game's 0x7F000000 segment is code only; its TLB-miss handler pages it
// in for instruction fetches, which recompiled code doesn't need.)

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include "ge64.hpp"

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_vm.h>
#elif defined(__linux__)
#include <sys/mman.h>
#include <unistd.h>
#endif

namespace {
    constexpr size_t kMappedSize = 0x400000;             // one TLB entry: 4 MB
    constexpr size_t kMappedOffset = 0xF0000000;          // 0x70000000 - 0x80000000 (mod 2^32)
}

bool ge64::map_tlb_regions(uint8_t* rdram) {
    uint8_t* alias = rdram + kMappedOffset;
#if defined(__APPLE__)
    // Share the first 4 MB of RDRAM at the alias address.
    mach_vm_address_t target = reinterpret_cast<mach_vm_address_t>(alias);
    vm_prot_t cur = 0, max = 0;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &target, kMappedSize, 0,
        VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
        reinterpret_cast<mach_vm_address_t>(rdram), FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[GE64] mach_vm_remap failed (%d)\n", kr);
        return false;
    }
    return true;
#elif defined(__linux__)
    // Anonymous private memory can't be mapped twice, so move the first 4 MB
    // into a shared memory file and map that at both addresses.
    int fd = memfd_create("ge64-rdram", 0);
    if (fd < 0 || ftruncate(fd, kMappedSize) != 0) {
        perror("[GE64] memfd");
        return false;
    }
    std::vector<uint8_t> saved(rdram, rdram + kMappedSize);
    void* a = mmap(rdram, kMappedSize, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
    void* b = mmap(alias, kMappedSize, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
    close(fd);
    if (a == MAP_FAILED || b == MAP_FAILED) {
        perror("[GE64] mmap");
        return false;
    }
    memcpy(rdram, saved.data(), kMappedSize);
    return true;
#else
#error "Unsupported platform"
#endif
}
