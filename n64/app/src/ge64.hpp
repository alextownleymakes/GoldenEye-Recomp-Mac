#pragma once
#include <cstdint>
#include <cstddef>
#include <memory>
#include "recomp.h"
#include "ultramodern/renderer_context.hpp"

namespace ge64 {
    // sections.cpp
    void register_sections();
    void add_mapped_functions();

    // memory.cpp
    bool map_tlb_regions(uint8_t* rdram);

    // main.cpp: true while a mission is being played (not in the menus).
    bool in_mission();

    // main.cpp: counters for the test mode
    void count_display_list();
    void count_frame();

    // gfx_rt64.cpp
    std::unique_ptr<ultramodern::renderer::RendererContext> create_rt64_renderer(
        uint8_t* rdram, ultramodern::renderer::WindowHandle window, bool developer);

    // platform.cpp (SDL)
    ultramodern::renderer::WindowHandle create_window(void*);
    void pump_events();
    void poll_input();
    bool get_input(int controller, uint16_t* buttons, float* x, float* y);
    void set_rumble(int controller, bool on);
    void show_error(const char* msg);

    // audio.cpp (SDL)
    void audio_set_frequency(uint32_t freq);
    void audio_queue_samples(int16_t* samples, size_t count);
    size_t audio_frames_remaining();

    // GoldenEye's memory layout (NTSC-U)
    constexpr uint32_t kEntrypoint   = 0x80000400u;
    constexpr uint32_t kBssStart     = 0x8005D2E0u;
    constexpr uint32_t kBssSize      = 0x00031080u;
    constexpr uint32_t kBootStackTop = 0x803AB410u;  // end of sp_rmon, set by _start
}
