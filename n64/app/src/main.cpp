// GoldenEye 64: starts N64ModernRuntime with the recompiled game.
//
// usage: GoldenEye64 [rom]
//   The ROM defaults to ge007.z64 in the app bundle's Resources folder.
//   GE64_TEST_SECONDS=n quits after n seconds and prints what ran (testing).
//   GE64_HEADLESS=1 runs without a window, graphics or input (testing).

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <string>

#include "recomp.h"
#include "funcs.h"
#include "librecomp/game.hpp"
#include "librecomp/rsp.hpp"
#include "ultramodern/ultramodern.hpp"
#include "ultramodern/renderer_context.hpp"
#include "ultramodern/error_handling.hpp"
#include "ultramodern/events.hpp"
#include "ultramodern/input.hpp"
#include "ultramodern/threads.hpp"
#include "ge64.hpp"

namespace fs = std::filesystem;

// The game's audio microcode (RecompiledFuncs/aspMain.cpp, made by RSPRecomp).
RspExitReason aspMain(uint8_t* rdram, uint32_t ucode_addr);

namespace {
    constexpr uint64_t kRomHash = 0x639ECE0BC88C6E4AULL;  // XXH3-64 of the US ROM (.z64 order)
    const std::u8string kGameId = u8"ge007.u";

    std::atomic<uint64_t> g_dl_count{0};
    std::atomic<uint64_t> g_frame_count{0};
    std::atomic<uint64_t> g_audio_tasks{0};
    std::atomic<uint64_t> g_vi_count{0};
    double g_test_seconds = 0;
    bool g_headless = false;

    // ---- Boot -------------------------------------------------------------

    // _start (0x80000400): clear .bss, set the boot stack, then jump to the
    // engine's boot code. boot (0x70000450) only writes the TLB entry for
    // 0x70000000, which memory.cpp sets up instead, then calls init().
    void ge_entrypoint(uint8_t* rdram, recomp_context* ctx) {
        for (uint32_t a = ge64::kBssStart; a < ge64::kBssStart + ge64::kBssSize; a += 4) {
            MEM_W(0, (gpr)(int32_t)a) = 0;
        }
        ctx->r29 = (gpr)(int32_t)ge64::kBootStackTop;
        init(rdram, ctx);
    }

    // After the runtime has loaded the first megabyte of the ROM (as the
    // console's boot code would) and before the entrypoint runs.
    uint8_t* g_rdram = nullptr;

    void ge_on_init(uint8_t* rdram, recomp_context* ctx) {
        g_rdram = rdram;
        if (!ge64::map_tlb_regions(rdram)) {
            ultramodern::error_handling::message_box("GoldenEye 64 couldn't set up its memory.");
            std::exit(EXIT_FAILURE);
        }
        ge64::add_mapped_functions();
    }

    // ---- RSP --------------------------------------------------------------

    // Audio tasks run the game's audio microcode, recompiled from the ROM.
    RspExitReason audio_task(uint8_t* rdram, uint32_t ucode_addr) {
        g_audio_tasks++;
        return aspMain(rdram, ucode_addr);
    }

    RspUcodeFunc* get_rsp_microcode(const OSTask* task) {
        switch (task->t.type) {
            case M_AUDTASK:
                return audio_task;
            default:
                fprintf(stderr, "[GE64] Unknown RSP task type %u\n", task->t.type);
                return nullptr;
        }
    }

    // ---- Headless renderer (test builds) ------------------------------------

    class NullRenderer : public ultramodern::renderer::RendererContext {
    public:
        // Test mode (GE64_HEADLESS=1): runs the game without a window.
        NullRenderer() {
            setup_result = ultramodern::renderer::SetupResult::Success;
            chosen_api = ultramodern::renderer::GraphicsApi::Auto;
        }
        bool valid() override { return true; }
        bool update_config(const ultramodern::renderer::GraphicsConfig&, const ultramodern::renderer::GraphicsConfig&) override { return true; }
        void enable_instant_present() override {}
        void send_dl(const OSTask*) override { ge64::count_display_list(); }
        void send_dummy_workload(uint32_t) override {}
        void update_screen() override { ge64::count_frame(); }
        void shutdown() override {}
        uint32_t get_display_framerate() const override { return 60; }
        float get_resolution_scale() const override { return 1.0f; }
    };

    std::unique_ptr<ultramodern::renderer::RendererContext> create_renderer(uint8_t* rdram, ultramodern::renderer::WindowHandle window, bool developer) {
        if (g_headless) {
            return std::make_unique<NullRenderer>();
        }
        return ge64::create_rt64_renderer(rdram, window, developer);
    }

    ultramodern::renderer::WindowHandle create_window(ultramodern::gfx_callbacks_t::gfx_data_t data) {
        if (!g_headless) {
            return ge64::create_window(data);
        }
#if defined(__APPLE__)
        return { reinterpret_cast<void*>(1), reinterpret_cast<void*>(1) };
#else
        return reinterpret_cast<SDL_Window*>(uintptr_t{1});
#endif
    }

    // ---- Audio ----------------------------------------------------------------

    void queue_samples(int16_t* samples, size_t count) {
        if (!g_headless) ge64::audio_queue_samples(samples, count);
    }
    size_t get_frames_remaining() {
        return g_headless ? 0 : ge64::audio_frames_remaining();
    }
    void set_frequency(uint32_t freq) {
        if (!g_headless) ge64::audio_set_frequency(freq);
    }

    ultramodern::input::connected_device_info_t get_device_info(int controller) {
        if (controller == 0) {
            return { ultramodern::input::Device::Controller, ultramodern::input::Pak::None };
        }
        return { ultramodern::input::Device::None, ultramodern::input::Pak::None };
    }

    // ---- Misc callbacks -----------------------------------------------------

    void message_box(const char* msg) {
        if (g_headless) {
            fprintf(stderr, "[GE64] %s\n", msg);
        } else {
            ge64::show_error(msg);
        }
    }

    void on_vi() { g_vi_count++; }

    std::string thread_name(const OSThread* t) {
        switch (t->id) {
            case 0: return "GE64 idle";
            case 1: return "GE64 rmon";
            case 3: return "GE64 main";
            case 4: return "GE64 audio";
            case 5: return "GE64 scheduler";
            default: return "GE64 thread " + std::to_string(t->id);
        }
    }

    void update_gfx(void*) {
        if (!g_headless) {
            ge64::pump_events();
        }
        static bool started = false;
        static auto start_time = std::chrono::steady_clock::now();
        // Start once the VI thread has run a few times: it sets up its
        // default video mode only before the game starts, and the game
        // doesn't set its own mode until after it has received VI interrupts.
        if (!started && g_vi_count.load() >= 3) {
            started = true;
            recomp::start_game(kGameId, "");
        }
        if (g_test_seconds > 0) {
            double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start_time).count();
            if (elapsed >= g_test_seconds) {
                printf("[GE64 test] %.0fs: VI %llu, display lists %llu, frames %llu, audio tasks %llu\n",
                    elapsed, (unsigned long long)g_vi_count.load(), (unsigned long long)g_dl_count.load(),
                    (unsigned long long)g_frame_count.load(), (unsigned long long)g_audio_tasks.load());
                if (auto* vi = ultramodern::renderer::get_vi_regs()) {
                    printf("[GE64 test] VI origin 0x%08X width %u status 0x%X xscale 0x%X yscale 0x%X hstart 0x%X vstart 0x%X\n",
                        vi->VI_ORIGIN_REG, vi->VI_WIDTH_REG, vi->VI_STATUS_REG, vi->VI_X_SCALE_REG, vi->VI_Y_SCALE_REG,
                        vi->VI_H_START_REG, vi->VI_V_START_REG);
                }
                fflush(stdout);
                std::_Exit(g_dl_count.load() > 0 ? 0 : 2);
            }
        }
    }

    fs::path config_dir() {
        const char* home = getenv("HOME");
        fs::path base = home ? fs::path(home) : fs::temp_directory_path();
#if defined(__APPLE__)
        return base / "Library/Application Support/GoldenEye 64";
#else
        return base / ".config/GoldenEye64";
#endif
    }

    fs::path default_rom(const char* argv0) {
        // <App>.app/Contents/MacOS/GoldenEye64 -> <App>.app/Contents/Resources/ge007.z64
        std::error_code ec;
        fs::path exe = fs::weakly_canonical(fs::path(argv0), ec);
        return exe.parent_path().parent_path() / "Resources" / "ge007.z64";
    }
}

void ge64::count_display_list() { g_dl_count++; }
void ge64::count_frame() { g_frame_count++; }

bool ge64::in_mission() {
    // current_menu (0x8002A8C0 in NTSC-U) is MENU_RUN_STAGE (11) during a mission.
    return g_rdram && *reinterpret_cast<const int32_t*>(g_rdram + 0x2A8C0) == 11;
}

int main(int argc, char** argv) {
    if (const char* t = getenv("GE64_TEST_SECONDS")) {
        g_test_seconds = atof(t);
    }
    if (const char* h = getenv("GE64_HEADLESS")) {
        g_headless = atoi(h) != 0;
    }
    fs::path rom = argc > 1 ? fs::path(argv[1]) : default_rom(argv[0]);

    fs::path config = config_dir();
    std::error_code ec;
    fs::create_directories(config, ec);
    recomp::register_config_path(config);

    ge64::register_sections();

    recomp::GameEntry game{
        .rom_hash = kRomHash,
        .internal_name = "GOLDENEYE",
        .display_name = "GoldenEye 007",
        .game_id = kGameId,
        .mod_game_id = "",
        .save_type = recomp::SaveType::Eep4k,
        .is_enabled = true,
        .entrypoint_address = (gpr)(int32_t)ge64::kEntrypoint,
        .entrypoint = ge_entrypoint,
        .on_init_callback = ge_on_init,
    };
    recomp::register_game(game);

    switch (recomp::select_rom(rom, kGameId)) {
        case recomp::RomValidationError::Good:
            break;
        case recomp::RomValidationError::FailedToOpen:
            message_box(("Couldn't open the ROM: " + rom.string()).c_str());
            return 1;
        default:
            message_box("This isn't the US (NTSC-U) GoldenEye 007 ROM.");
            return 1;
    }

    static const ultramodern::threads::callbacks_t threads_callbacks{ .get_game_thread_name = thread_name };

    recomp::Configuration cfg{};
    cfg.argc = argc;
    cfg.argv = argv;
    cfg.project_version = recomp::Version{0, 1, 0};
    cfg.rsp_callbacks = { .get_rsp_microcode = get_rsp_microcode };
    cfg.renderer_callbacks = { .create_render_context = create_renderer };
    cfg.audio_callbacks = { .queue_samples = queue_samples, .get_frames_remaining = get_frames_remaining, .set_frequency = set_frequency };
    cfg.input_callbacks = { .poll_input = ge64::poll_input, .get_input = ge64::get_input, .set_rumble = ge64::set_rumble, .get_connected_device_info = get_device_info };
    cfg.gfx_callbacks = { .create_gfx = nullptr, .create_window = create_window, .update_gfx = update_gfx };
    cfg.events_callbacks = { .vi_callback = on_vi, .gfx_init_callback = nullptr };
    cfg.error_handling_callbacks = { .message_box = message_box };
    cfg.threads_callbacks = threads_callbacks;

    recomp::start(cfg);
    return 0;
}
