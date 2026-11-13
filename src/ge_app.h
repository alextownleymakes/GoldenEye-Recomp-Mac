
// ge - ReXGlue Recompiled Project
//
// This file is yours to edit. 'rexglue migrate' will NOT overwrite it.
// Customize your app by overriding virtual hooks from rex::ReXApp.

#pragma once

#include <rex/cvar.h>
#include <rex/rex_app.h>
#include <rex/system/kernel_state.h>
#include <rex/system/xam/user_profile.h>
#include <rex/ui/keybinds.h>
#include <rex/ui/window.h>
#include <rex/ui/windowed_app_context.h>

#include <cstdlib>
#include <filesystem>
#include <string>

#if defined(__APPLE__)
#include <rex/filesystem.h>
#endif

#include "ge_menu.h"
#include "ge_postfx.h"

// Relaunch the current executable as a fresh process (implemented in
// ge_hooks.cpp, which owns the platform includes). Used by the ONLINE menu's
// "Save & Restart" so username/server/enable changes take effect on a clean
// boot -- they are read at startup (UserProfile ctor, online client start).
namespace ge {
void LaunchSelfDetached();
// Start the raw-mouse + cursor-capture thread at startup. Implemented in
// ge_hooks.cpp.
void InitMouseLook();
// Suppress mouse-look while the pause menu is open (cursor is needed for the
// menu, and motion shouldn't turn into look). Implemented in ge_hooks.cpp.
void SetMouselookSuppressed(bool suppressed);
// macOS/Linux: listen for keyboard/mouse on the game window (Windows reads
// input through Win32 directly, so these are no-ops there).
void AttachInputWindow(rex::ui::Window* window);
void DetachInputWindow();
}

class GeApp : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<GeApp>(new GeApp(ctx, "ge",
        PPCImageConfig));
  }

  // GoldenEye boot defaults. Runs before the config file is loaded, so these
  // are just defaults -- ge.toml (written by the in-game menu) overrides them.
  void OnConfigurePaths(rex::PathConfig& paths) override {
#if defined(__APPLE__)
    // macOS app bundle (GoldenEye.app/Contents/MacOS/GoldenEye):
    //  - game files: GoldenEye.app/Contents/Resources/assets (the build copies
    //    them in), else an "assets" folder next to GoldenEye.app;
    //  - settings: ~/Library/Application Support/GoldenEye/ge.toml, never inside
    //    the bundle (it may be read-only, and writing there breaks its signature).
    if (InAppBundle()) {
      const std::filesystem::path contents = BundleContentsDir();
      const std::filesystem::path beside_app = contents.parent_path().parent_path();
      std::error_code ec;
      if (paths.game_data_root.empty()) {
        if (std::filesystem::is_directory(contents / "Resources" / "assets", ec)) {
          paths.game_data_root = contents / "Resources" / "assets";
        } else if (std::filesystem::is_directory(beside_app / "assets", ec)) {
          paths.game_data_root = beside_app / "assets";
        }
      }
      const std::filesystem::path support = MacSupportDir("Application Support");
      if (!support.empty()) {
        std::filesystem::create_directories(support, ec);
        const std::filesystem::path cfg = support / "ge.toml";
        // One-time carry-over of settings saved next to the app by older builds.
        if (!std::filesystem::exists(cfg, ec) &&
            std::filesystem::exists(beside_app / "ge.toml", ec)) {
          std::filesystem::copy_file(beside_app / "ge.toml", cfg, ec);
        }
        paths.config_path = cfg;
      } else {
        paths.config_path = beside_app / "ge.toml";
      }
    }
#else
    (void)paths;
#endif
    // NOTE: vsync is NOT forced here. Its SDK default is false (off), so the
    // in-menu toggle persists: turning it ON differs from default -> written to
    // ge.toml; OFF == default -> not written but still boots off. Forcing it here
    // would re-assert off every boot and the "on" choice would never survive a
    // restart (SaveConfig only writes cvars that differ from their default).
    rex::cvar::SetFlagByName("max_fps", "60");  // default 60 (clamped to native refresh)
    rex::cvar::SetFlagByName("window_width", "2560");
    rex::cvar::SetFlagByName("window_height", "1440");
    // NOTE: fullscreen is NOT forced here. Its default is set to true at the
    // framework level (window.cpp) instead. That makes "windowed" the
    // non-default value, so toggling to windowed actually saves to ge.toml --
    // SaveConfig only writes cvars that differ from their default. Forcing
    // fullscreen=true here would re-assert it every boot and the windowed
    // choice would never persist. The throttle is the same story: its default
    // lives in its REXCVAR_DEFINE and it is tuned live from the pause menu, so
    // it is never written here (writing default==default is a no-op anyway).
  }

#if defined(__APPLE__)
  // Logs go to ~/Library/Logs/GoldenEye (viewable in Console.app) instead of
  // inside the app bundle.
  void OnConfigureLogging(rex::LogConfig& config) override {
    if (InAppBundle()) {
      const std::filesystem::path logs = MacLibraryDir("Logs");
      if (!logs.empty()) config.log_dir = logs;
    }
  }
#endif

  // ReXGlue 0.10+ loads the Xenos GPU as a plugin and leaves graphics off
  // unless one is named. Default to it (a gpu_plugin set in ge.toml or on the
  // command line still wins).
  void OnPreSetup(rex::RuntimeConfig& config) override {
    if (config.gpu_plugin.empty()) {
      config.gpu_plugin = "xenos";
    }
  }

  // Register the ESC pause-menu keybind and create the always-on Post-FX
  // filter overlay once the ImGui drawer exists.
  void OnCreateDialogs(rex::ui::ImGuiDrawer* drawer) override {
    // Window/taskbar title shown while running. Overrides the SDK default
    // ("ge <build stamp>"); the internal app name stays "ge" so ge.toml and the
    // user data dir are unchanged.
    if (window()) window()->SetTitle("GoldenEye");
    rex::ui::RegisterBind("bind_pause_menu", "Escape", "Pause menu",
                          [this] { TogglePauseMenu(); });
    ge::AttachInputWindow(window());  // macOS/Linux keyboard + mouse events
    ge::InitMouseLook();  // start raw-mouse capture/look thread
    postfx_ = std::make_unique<ge::PostFxOverlay>(drawer);
    // Username/server are set in the ONLINE pause-menu tab now -- no first-boot
    // prompt. They apply on the Save & Restart the ONLINE tab triggers.
  }

  // Tear down the menu, overlay and keybind before the drawer is destroyed.
  void OnShutdown() override {
    rex::ui::UnregisterBind("bind_pause_menu");
    ge::DetachInputWindow();
    if (menu_) {
      // Direct delete (not Close()) so we don't re-enter pause bookkeeping
      // during shutdown; removes itself from the drawer in its destructor.
      delete menu_;
      menu_ = nullptr;
    }
    postfx_.reset();
  }

 private:
#if defined(__APPLE__)
  static std::filesystem::path BundleContentsDir() {
    return rex::filesystem::GetExecutableFolder().parent_path();
  }
  static bool InAppBundle() {
    const std::filesystem::path exe_dir = rex::filesystem::GetExecutableFolder();
    return exe_dir.filename() == "MacOS" && exe_dir.parent_path().filename() == "Contents";
  }
  // ~/Library/<sub>/GoldenEye, or empty if HOME is unset.
  static std::filesystem::path MacLibraryDir(const char* sub) {
    const char* home = std::getenv("HOME");
    if (!home || !*home) return {};
    return std::filesystem::path(home) / "Library" / sub / "GoldenEye";
  }
  static std::filesystem::path MacSupportDir(const char* sub) { return MacLibraryDir(sub); }
#endif

  // ESC handler: open or close the menu. The game keeps running underneath.
  void TogglePauseMenu() {
    if (menu_) {
      menu_->RequestClose();  // on_closed clears menu_
      return;
    }
    GeMenuDialog::Callbacks cb;
    cb.on_closed = [this] {
      menu_ = nullptr;
      ge::SetMouselookSuppressed(false);  // re-enable mouse-look on menu close
    };
    cb.on_quit = [this] {
      if (runtime() && runtime()->kernel_state()) {
        runtime()->kernel_state()->TerminateTitle();
      }
      app_context().QuitFromUIThread();
    };
    cb.get_fullscreen = [this] { return window() && window()->IsFullscreen(); };
    cb.request_fullscreen = [this](bool v) {
      // Persist the choice: update the cvar (so SaveConfig writes it) and flush
      // ge.toml now. Without this the window changes but reverts next boot.
      rex::cvar::SetFlagByName("fullscreen", v ? "true" : "false");
      PersistConfig();
      // Defer off the paint thread: applying a window/surface change from inside
      // the ImGui draw (which runs during the presenter's paint) tears down the
      // surface being painted and crashes. Running it from the UI loop between
      // frames is the same safe path as a normal window resize.
      app_context().CallInUIThreadDeferred([this, v] {
        if (window()) window()->SetFullscreen(v);
      });
    };
    cb.persist_config = [this] { PersistConfig(); };
    cb.request_restart = [this] {
      // ONLINE tab "Save & Restart": the menu has already persisted the cvars;
      // launch a fresh process (which reads the new ge.toml at boot) then tear
      // this one down. Deferred to the UI thread -- never quit/relaunch from
      // inside the paint (same reason as request_fullscreen).
      app_context().CallInUIThreadDeferred([this] {
        ge::LaunchSelfDetached();
        if (runtime() && runtime()->kernel_state()) {
          runtime()->kernel_state()->TerminateTitle();
        }
        app_context().QuitFromUIThread();
      });
    };
    ge::SetMouselookSuppressed(true);  // freeze mouse-look while the menu is up
    menu_ = new GeMenuDialog(imgui_drawer(), std::move(cb));
  }

  GeMenuDialog* menu_ = nullptr;  // non-owning; self-deletes via the drawer
  std::unique_ptr<ge::PostFxOverlay> postfx_;       // always-on filter layer
};
