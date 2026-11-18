// Window, events and controls (SDL2).
//
// Controller (Xbox / PlayStation layout), with the N64 pad's GoldenEye roles:
//   Left stick              N64 stick (move forward/back, turn)
//   Right stick             C buttons (look up/down, strafe)
//   Right trigger           Z (fire)
//   Left trigger            R (aim)
//   Cross / A               A (next weapon)
//   Circle / B, Square / X  B (use, reload)
//   Triangle / Y            A (next weapon)
//   Left bumper             L
//   Right bumper            R (aim)
//   D-pad                   D-pad
//   Start / Options         Start (pause, watch)
//
// Keyboard:
//   W / S                   stick forward / back
//   Left / Right arrows     stick turn
//   A / D                   C-left / C-right (strafe)
//   Up / Down arrows        C-up / C-down (look)
//   Space                   Z (fire)
//   Left Shift              R (aim)
//   E                       B (use, reload)
//   Q                       A (next weapon)
//   Return                  Start
//   F11 or Cmd+F            full screen

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <mutex>

#include <SDL.h>
#if defined(__APPLE__)
#include <SDL_syswm.h>
#endif

#include "ultramodern/ultramodern.hpp"
#include "ultramodern/input.hpp"
#include "ultramodern/renderer_context.hpp"
#include "ge64.hpp"

namespace {
    enum : uint16_t {
        N64_A = 0x8000, N64_B = 0x4000, N64_Z = 0x2000, N64_START = 0x1000,
        N64_DU = 0x0800, N64_DD = 0x0400, N64_DL = 0x0200, N64_DR = 0x0100,
        N64_L = 0x0020, N64_R = 0x0010,
        N64_CU = 0x0008, N64_CD = 0x0004, N64_CL = 0x0002, N64_CR = 0x0001,
    };

    SDL_Window* g_window = nullptr;
    SDL_GameController* g_pad = nullptr;
    std::mutex g_pad_mutex;
    bool g_fullscreen = false;

    void open_first_controller() {
        std::lock_guard lock{g_pad_mutex};
        if (g_pad) return;
        for (int i = 0; i < SDL_NumJoysticks(); i++) {
            if (SDL_IsGameController(i)) {
                g_pad = SDL_GameControllerOpen(i);
                if (g_pad) {
                    fprintf(stderr, "[GE64] Controller: %s\n", SDL_GameControllerName(g_pad));
                    return;
                }
            }
        }
    }

    void close_controller(SDL_JoystickID id) {
        std::lock_guard lock{g_pad_mutex};
        if (g_pad && SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(g_pad)) == id) {
            SDL_GameControllerClose(g_pad);
            g_pad = nullptr;
        }
    }

    void toggle_fullscreen() {
        g_fullscreen = !g_fullscreen;
        SDL_SetWindowFullscreen(g_window, g_fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
        SDL_ShowCursor(g_fullscreen ? SDL_DISABLE : SDL_ENABLE);
    }

    float axis(SDL_GameController* pad, SDL_GameControllerAxis a) {
        return SDL_GameControllerGetAxis(pad, a) / 32767.0f;
    }

    // Deadzone, then rescale so the stick still reaches full tilt.
    void deadzone(float& x, float& y, float dz) {
        float m = std::sqrt(x * x + y * y);
        if (m < dz) { x = y = 0; return; }
        float s = std::min(1.0f, (m - dz) / (1.0f - dz)) / m;
        x *= s; y *= s;
    }
}

ultramodern::renderer::WindowHandle ge64::create_window(void*) {
    SDL_SetHint(SDL_HINT_GAMECONTROLLER_USE_BUTTON_LABELS, "0");
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER | SDL_INIT_AUDIO) != 0) {
        fprintf(stderr, "[GE64] SDL_Init failed: %s\n", SDL_GetError());
        std::exit(EXIT_FAILURE);
    }
#if defined(__APPLE__)
    const Uint32 api_flag = SDL_WINDOW_METAL;
#else
    const Uint32 api_flag = SDL_WINDOW_VULKAN;
#endif
    g_window = SDL_CreateWindow("GoldenEye 007", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        // No SDL_WINDOW_ALLOW_HIGHDPI: RT64 sizes its Metal drawable in window
        // points, so a Retina (2x) layer would show it at a quarter of the window.
        1280, 960, SDL_WINDOW_RESIZABLE | api_flag);
    if (!g_window) {
        fprintf(stderr, "[GE64] SDL_CreateWindow failed: %s\n", SDL_GetError());
        std::exit(EXIT_FAILURE);
    }
    SDL_SetWindowMinimumSize(g_window, 320, 240);
    open_first_controller();

#if defined(__APPLE__)
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    SDL_GetWindowWMInfo(g_window, &info);
    SDL_MetalView view = SDL_Metal_CreateView(g_window);
    // RT64 draws into the view's CAMetalLayer.
    return { reinterpret_cast<void*>(info.info.cocoa.window), SDL_Metal_GetLayer(view) };
#else
    return g_window;
#endif
}

// Called about once a millisecond on the main thread.
void ge64::pump_events() {
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        switch (e.type) {
            case SDL_QUIT:
                ultramodern::quit();
                break;
            case SDL_CONTROLLERDEVICEADDED:
                open_first_controller();
                break;
            case SDL_CONTROLLERDEVICEREMOVED:
                close_controller(e.cdevice.which);
                open_first_controller();
                break;
            case SDL_KEYDOWN: {
                const SDL_Keycode k = e.key.keysym.sym;
                const bool cmd = (e.key.keysym.mod & (KMOD_GUI | KMOD_ALT)) != 0;
                if (k == SDLK_F11 || (cmd && k == SDLK_f) || (cmd && k == SDLK_RETURN)) {
                    toggle_fullscreen();
                } else if (k == SDLK_ESCAPE && g_fullscreen) {
                    toggle_fullscreen();
                }
                break;
            }
            default:
                break;
        }
    }
}

void ge64::poll_input() {}

bool ge64::get_input(int controller, uint16_t* buttons, float* x, float* y) {
    if (controller != 0) {
        return false;
    }
    uint16_t b = 0;
    float sx = 0, sy = 0;

    {
        std::lock_guard lock{g_pad_mutex};
        if (SDL_GameController* p = g_pad) {
            auto btn = [p](SDL_GameControllerButton sb) { return SDL_GameControllerGetButton(p, sb) != 0; };
            if (btn(SDL_CONTROLLER_BUTTON_A)) b |= N64_A;
            if (btn(SDL_CONTROLLER_BUTTON_Y)) b |= N64_A;
            if (btn(SDL_CONTROLLER_BUTTON_B)) b |= N64_B;
            if (btn(SDL_CONTROLLER_BUTTON_X)) b |= N64_B;
            if (btn(SDL_CONTROLLER_BUTTON_START)) b |= N64_START;
            if (btn(SDL_CONTROLLER_BUTTON_LEFTSHOULDER)) b |= N64_L;
            if (btn(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)) b |= N64_R;
            if (btn(SDL_CONTROLLER_BUTTON_DPAD_UP)) b |= N64_DU;
            if (btn(SDL_CONTROLLER_BUTTON_DPAD_DOWN)) b |= N64_DD;
            if (btn(SDL_CONTROLLER_BUTTON_DPAD_LEFT)) b |= N64_DL;
            if (btn(SDL_CONTROLLER_BUTTON_DPAD_RIGHT)) b |= N64_DR;
            if (axis(p, SDL_CONTROLLER_AXIS_TRIGGERRIGHT) > 0.3f) b |= N64_Z;
            if (axis(p, SDL_CONTROLLER_AXIS_TRIGGERLEFT) > 0.3f) b |= N64_R;

            float lx = axis(p, SDL_CONTROLLER_AXIS_LEFTX), ly = -axis(p, SDL_CONTROLLER_AXIS_LEFTY);
            deadzone(lx, ly, 0.15f);
            sx = lx; sy = ly;

            float rx = axis(p, SDL_CONTROLLER_AXIS_RIGHTX), ry = -axis(p, SDL_CONTROLLER_AXIS_RIGHTY);
            if (rx > 0.5f) b |= N64_CR;
            if (rx < -0.5f) b |= N64_CL;
            if (ry > 0.5f) b |= N64_CU;
            if (ry < -0.5f) b |= N64_CD;
        }
    }

    const Uint8* k = SDL_GetKeyboardState(nullptr);
    if (k[SDL_SCANCODE_W]) sy = 1;
    if (k[SDL_SCANCODE_S]) sy = -1;
    if (k[SDL_SCANCODE_LEFT]) sx = -1;
    if (k[SDL_SCANCODE_RIGHT]) sx = 1;
    if (ge64::in_mission()) {
        if (k[SDL_SCANCODE_A]) b |= N64_CL;
        if (k[SDL_SCANCODE_D]) b |= N64_CR;
        if (k[SDL_SCANCODE_UP]) b |= N64_CU;
        if (k[SDL_SCANCODE_DOWN]) b |= N64_CD;
    } else {
        // The menus only follow the stick, so steer it with A/D and the arrows.
        if (k[SDL_SCANCODE_A]) sx = -1;
        if (k[SDL_SCANCODE_D]) sx = 1;
        if (k[SDL_SCANCODE_UP]) sy = 1;
        if (k[SDL_SCANCODE_DOWN]) sy = -1;
    }
    if (k[SDL_SCANCODE_SPACE]) b |= N64_Z;
    if (k[SDL_SCANCODE_LSHIFT]) b |= N64_R;
    if (k[SDL_SCANCODE_E]) b |= N64_B;
    if (k[SDL_SCANCODE_Q]) b |= N64_A;
    if (k[SDL_SCANCODE_RETURN]) b |= N64_START;

    // Test mode: GE64_TEST_PRESS=1 taps Start and A in turn every second.
    static const bool test_press = getenv("GE64_TEST_PRESS") != nullptr;
    if (test_press) {
        uint32_t t = SDL_GetTicks() / 250;
        if (t % 4 == 0) b |= (t / 4) % 2 ? N64_A : N64_START;
    }

    *buttons = b;
    *x = sx;
    *y = sy;
    return true;
}

void ge64::set_rumble(int controller, bool on) {
    std::lock_guard lock{g_pad_mutex};
    if (controller == 0 && g_pad) {
        SDL_GameControllerRumble(g_pad, on ? 0xC000 : 0, on ? 0xC000 : 0, on ? 1000 : 0);
    }
}

void ge64::show_error(const char* msg) {
    fprintf(stderr, "[GE64] %s\n", msg);
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "GoldenEye 64", msg, g_window);
}
