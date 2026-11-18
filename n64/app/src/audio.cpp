// Sound output (SDL2). The game's audio microcode, recompiled from the ROM
// (aspMain), mixes into RDRAM; the runtime passes each finished buffer here.

#include <cstdio>
#include <mutex>
#include <vector>
#include <SDL.h>
#include "ge64.hpp"

namespace {
    SDL_AudioDeviceID g_device = 0;
    uint32_t g_frequency = 0;
    std::mutex g_mutex;
    std::vector<int16_t> g_swapped;

    void open_device(uint32_t freq) {
        if (g_device) {
            SDL_CloseAudioDevice(g_device);
            g_device = 0;
        }
        SDL_AudioSpec want{}, have{};
        want.freq = (int)freq;
        want.format = AUDIO_S16SYS;
        want.channels = 2;
        want.samples = 512;
        // SDL converts to the output device's own rate.
        g_device = SDL_OpenAudioDevice(nullptr, 0, &want, &have, 0);
        if (!g_device) {
            fprintf(stderr, "[GE64] No sound: %s\n", SDL_GetError());
            return;
        }
        SDL_PauseAudioDevice(g_device, 0);
    }
}

void ge64::audio_set_frequency(uint32_t freq) {
    std::lock_guard lock{g_mutex};
    if (freq == g_frequency && g_device) return;
    g_frequency = freq;
    if (SDL_WasInit(SDL_INIT_AUDIO)) {
        open_device(freq);
    }
}

void ge64::audio_queue_samples(int16_t* samples, size_t count) {
    std::lock_guard lock{g_mutex};
    if (!g_device) return;
    // RDRAM is stored in 32-bit words, so each stereo pair arrives with
    // left and right swapped.
    g_swapped.resize(count);
    for (size_t i = 0; i + 1 < count; i += 2) {
        g_swapped[i] = samples[i + 1];
        g_swapped[i + 1] = samples[i];
    }
    SDL_QueueAudio(g_device, g_swapped.data(), (Uint32)(count * sizeof(int16_t)));
}

size_t ge64::audio_frames_remaining() {
    std::lock_guard lock{g_mutex};
    if (!g_device) return 0;
    return SDL_GetQueuedAudioSize(g_device) / (2 * sizeof(int16_t));
}
