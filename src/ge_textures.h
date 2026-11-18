// ge - ReXGlue Recompiled Project
//
// Custom textures: export the game's textures as PNG files, and load edited
// PNGs back in place of the originals.
//
//   <Textures>/Export/<game file>/<id>_<w>x<h>.png   written by "Export textures"
//   <Textures>/Replace/<game file>/<id>_<w>x<h>.png  your edited copies
//
// With custom textures on, at launch every game file that has a replacement is
// rewritten into a patched copy, and the game reads its files through a mirror
// of the real game folder that points at those copies (everything else links
// to the original files). Nothing in the real game folder is changed.
//
// This file is yours to edit. 'rexglue migrate' will NOT overwrite it.

#pragma once

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

namespace ge::textures {

// Log lines produced before the logger starts are held until this is called.
void SetLoggingReady();

// True if the config file turns custom textures on (ge_custom_textures = true).
// Read directly because the patched folder is chosen before the config loads.
bool ConfigSaysOn(const std::filesystem::path& config_file);

// Create Export/ and Replace/ and a README explaining them.
void WriteReadme(const std::filesystem::path& folder);

// Where Export/ and Replace/ live. Set once at startup.
void SetFolder(const std::filesystem::path& folder);
const std::filesystem::path& Folder();

// The real game folder (before any patched mirror is swapped in).
void SetGameRoot(const std::filesystem::path& root);
const std::filesystem::path& GameRoot();

// Startup: if Replace/ holds any PNGs, build the patched mirror of game_root
// and return its path (the caller then reads game files from there). Returns
// an empty path when there is nothing to replace or anything goes wrong, in
// which case the original files are used.
std::filesystem::path BuildPatchedGameFolder(const std::filesystem::path& game_root,
                                             const std::filesystem::path& folder);

// Write every texture in game_root/files to folder/Export as PNG.
struct ExportProgress {
  std::atomic<int> files_done{0};
  std::atomic<int> files_total{0};
  std::atomic<int> textures_written{0};
  std::atomic<bool> cancel{false};
};
struct ExportResult {
  int files = 0;
  int textures = 0;
  int unsupported = 0;  // textures in formats this can't convert yet
  std::string error;
};
// `only`: game-file path prefixes to include (e.g. "files/new/char"); empty = all.
ExportResult ExportAll(const std::filesystem::path& game_root,
                       const std::filesystem::path& folder, ExportProgress& progress,
                       const std::vector<std::string>& only = {});

// ---- Building blocks (also used by the tests) ------------------------------

struct TextureInfo {
  uint32_t id = 0;
  uint32_t format = 0;       // Xenos format byte from the header (low 6 bits = format)
  uint32_t width = 0, height = 0, levels = 0;
  size_t header_offset = 0;  // file offset of the 0x70-byte texture header
  size_t data_offset = 0;    // file offset of the (tiled) pixel data
  size_t data_size = 0;
};

// Parse a Rare CAFF file (the game's .bin / .rba container). Returns false if
// it isn't one. Only textures are reported.
bool ParseCaff(const std::vector<uint8_t>& file, std::vector<TextureInfo>& out);

// True for the formats Decode/Encode handle (DXT1, DXT3, DXT5).
bool IsSupported(const TextureInfo& tex);

// Base mip level <-> RGBA8 (width*height*4 bytes).
bool Decode(const std::vector<uint8_t>& file, const TextureInfo& tex,
            std::vector<uint8_t>& rgba);
bool Encode(std::vector<uint8_t>& file, const TextureInfo& tex,
            const std::vector<uint8_t>& rgba);

bool WritePng(const std::filesystem::path& path, uint32_t width, uint32_t height,
              const std::vector<uint8_t>& rgba);
bool ReadPng(const std::filesystem::path& path, uint32_t& width, uint32_t& height,
             std::vector<uint8_t>& rgba);

}  // namespace ge::textures
