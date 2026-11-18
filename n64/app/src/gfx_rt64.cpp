// Graphics: hands the game's display lists to RT64, which draws them with
// Metal on macOS (Vulkan elsewhere).

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>

#include "hle/rt64_application.h"
#include "ultramodern/renderer_context.hpp"
#include "ultramodern/ultramodern.hpp"
#include "librecomp/game.hpp"
#include "ge64.hpp"

namespace {
    // RSP memory and RDP registers RT64 reads and writes while it runs a
    // display list. Nothing else in the program uses them.
    uint8_t g_dmem[0x1000];
    uint8_t g_imem[0x1000];
    uint32_t g_mi_intr, g_dpc_start, g_dpc_end, g_dpc_current, g_dpc_status,
             g_dpc_clock, g_dpc_bufbusy, g_dpc_pipebusy, g_dpc_tmem;
    uint8_t g_rom_header[0x40];

    // Task completion is reported by the runtime, not through RT64.
    void no_interrupts() {}

    ultramodern::renderer::SetupResult map_result(RT64::Application::SetupResult r) {
        using S = ultramodern::renderer::SetupResult;
        switch (r) {
            case RT64::Application::SetupResult::Success: return S::Success;
            case RT64::Application::SetupResult::DynamicLibrariesNotFound: return S::DynamicLibrariesNotFound;
            case RT64::Application::SetupResult::InvalidGraphicsAPI: return S::InvalidGraphicsAPI;
            case RT64::Application::SetupResult::GraphicsAPINotFound: return S::GraphicsAPINotFound;
            case RT64::Application::SetupResult::GraphicsDeviceNotFound: return S::GraphicsDeviceNotFound;
        }
        return S::GraphicsDeviceNotFound;
    }

    class RT64Renderer : public ultramodern::renderer::RendererContext {
    public:
        RT64Renderer(uint8_t* rdram, ultramodern::renderer::WindowHandle window, bool developer) {
            // The ROM header lets RT64 recognize the game.
            std::span<const uint8_t> rom = recomp::get_rom();
            if (rom.size() >= sizeof(g_rom_header)) {
                memcpy(g_rom_header, rom.data(), sizeof(g_rom_header));
            }

            RT64::Application::Core core{};
#if defined(__APPLE__)
            core.window.window = window.window;
            core.window.view = window.view;
#else
            core.window = window;
#endif
            core.checkInterrupts = no_interrupts;
            core.HEADER = g_rom_header;
            core.RDRAM = rdram;
            core.DMEM = g_dmem;
            core.IMEM = g_imem;
            core.MI_INTR_REG = &g_mi_intr;
            core.DPC_START_REG = &g_dpc_start;
            core.DPC_END_REG = &g_dpc_end;
            core.DPC_CURRENT_REG = &g_dpc_current;
            core.DPC_STATUS_REG = &g_dpc_status;
            core.DPC_CLOCK_REG = &g_dpc_clock;
            core.DPC_BUFBUSY_REG = &g_dpc_bufbusy;
            core.DPC_PIPEBUSY_REG = &g_dpc_pipebusy;
            core.DPC_TMEM_REG = &g_dpc_tmem;

            ultramodern::renderer::ViRegs* vi = ultramodern::renderer::get_vi_regs();
            core.VI_STATUS_REG = &vi->VI_STATUS_REG;
            core.VI_ORIGIN_REG = &vi->VI_ORIGIN_REG;
            core.VI_WIDTH_REG = &vi->VI_WIDTH_REG;
            core.VI_INTR_REG = &vi->VI_INTR_REG;
            core.VI_V_CURRENT_LINE_REG = &vi->VI_V_CURRENT_LINE_REG;
            core.VI_TIMING_REG = &vi->VI_TIMING_REG;
            core.VI_V_SYNC_REG = &vi->VI_V_SYNC_REG;
            core.VI_H_SYNC_REG = &vi->VI_H_SYNC_REG;
            core.VI_LEAP_REG = &vi->VI_LEAP_REG;
            core.VI_H_START_REG = &vi->VI_H_START_REG;
            core.VI_V_START_REG = &vi->VI_V_START_REG;
            core.VI_V_BURST_REG = &vi->VI_V_BURST_REG;
            core.VI_X_SCALE_REG = &vi->VI_X_SCALE_REG;
            core.VI_Y_SCALE_REG = &vi->VI_Y_SCALE_REG;

            RT64::ApplicationConfiguration config;
            config.useConfigurationFile = false;
            app = std::make_unique<RT64::Application>(core, config);

            app->userConfig.developerMode = developer;
            app->userConfig.graphicsAPI = RT64::UserConfiguration::GraphicsAPI::Automatic;
            // Draw at the window's resolution, keeping the game's 4:3 picture.
            app->userConfig.resolution = RT64::UserConfiguration::Resolution::WindowIntegerScale;
            app->userConfig.aspectRatio = RT64::UserConfiguration::AspectRatio::Original;

            setup_result = map_result(app->setup(0));
            switch (app->chosenGraphicsAPI) {
                case RT64::UserConfiguration::GraphicsAPI::Metal: chosen_api = ultramodern::renderer::GraphicsApi::Metal; break;
                case RT64::UserConfiguration::GraphicsAPI::Vulkan: chosen_api = ultramodern::renderer::GraphicsApi::Vulkan; break;
                default: chosen_api = ultramodern::renderer::GraphicsApi::Auto; break;
            }
            if (setup_result != ultramodern::renderer::SetupResult::Success) {
                app = nullptr;
            }
        }

        ~RT64Renderer() override = default;

        bool valid() override { return app != nullptr; }

        bool update_config(const ultramodern::renderer::GraphicsConfig&, const ultramodern::renderer::GraphicsConfig&) override {
            return false;
        }

        void enable_instant_present() override {
            app->enhancementConfig.presentation.mode = RT64::EnhancementConfiguration::Presentation::Mode::PresentEarly;
            app->updateEnhancementConfig();
        }

        void send_dl(const OSTask* task) override {
            app->state->rsp->reset();
            app->interpreter->loadUCodeGBI(task->t.ucode & 0x3FFFFFF, task->t.ucode_data & 0x3FFFFFF, true);
            static bool logged = false;
            if (!logged && getenv("GE64_TEST_SECONDS")) {
                logged = true;
                fprintf(stderr, "[GE64 test] first display list: ucode 0x%08X data 0x%08X dl 0x%08X, GBI %d\n",
                    task->t.ucode, task->t.ucode_data, task->t.data_ptr,
                    app->interpreter->hleGBI ? int(app->interpreter->hleGBI->ucode) : -1);
            }
            app->processDisplayLists(app->core.RDRAM, task->t.data_ptr & 0x3FFFFFF, 0, true);
            ge64::count_display_list();
        }

        // Sent while no game is running; there's nothing to draw then.
        void send_dummy_workload(uint32_t) override {}

        void update_screen() override {
            app->updateScreen();
            ge64::count_frame();
        }

        void shutdown() override {
            if (app) app->end();
        }

        uint32_t get_display_framerate() const override {
            return app->presentQueue->ext.sharedResources->swapChainRate;
        }

        float get_resolution_scale() const override {
            return 1.0f;
        }

    private:
        std::unique_ptr<RT64::Application> app;
    };
}

std::unique_ptr<ultramodern::renderer::RendererContext> ge64::create_rt64_renderer(
        uint8_t* rdram, ultramodern::renderer::WindowHandle window, bool developer) {
    return std::make_unique<RT64Renderer>(rdram, window, developer);
}
