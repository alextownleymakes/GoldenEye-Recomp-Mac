// ge_texpatch: bake replacement textures into the game files at build time.
//
//   ge_texpatch <replace dir> <game assets dir>
//
// <replace dir> mirrors the game's folders, with the game file as a folder and
// one PNG per texture inside it, named by texture number, e.g.
//   files/new/char/suitbond/default.bin/03.png
// (the same layout as the in-game Textures/Replace folder). Each PNG replaces
// that texture in <game assets dir>/files/new/char/suitbond/default.bin. A PNG
// of another size is scaled to fit. Patched files are written as new files, so
// an APFS clone of the original is left untouched.

#include "../src/ge_textures.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using namespace ge::textures;

static std::vector<uint8_t> Scale(const std::vector<uint8_t>& src, uint32_t sw, uint32_t sh,
                                  uint32_t dw, uint32_t dh) {
  std::vector<uint8_t> out(size_t(dw) * dh * 4);
  for (uint32_t y = 0; y < dh; y++) {
    const float fy = std::clamp((y + 0.5f) * sh / dh - 0.5f, 0.0f, float(sh - 1));
    const uint32_t y0 = uint32_t(fy), y1 = std::min(y0 + 1, sh - 1);
    const float ty = fy - y0;
    for (uint32_t x = 0; x < dw; x++) {
      const float fx = std::clamp((x + 0.5f) * sw / dw - 0.5f, 0.0f, float(sw - 1));
      const uint32_t x0 = uint32_t(fx), x1 = std::min(x0 + 1, sw - 1);
      const float tx = fx - x0;
      for (int c = 0; c < 4; c++) {
        auto at = [&](uint32_t xx, uint32_t yy) { return float(src[(size_t(yy) * sw + xx) * 4 + c]); };
        const float v = (at(x0, y0) * (1 - tx) + at(x1, y0) * tx) * (1 - ty) +
                        (at(x0, y1) * (1 - tx) + at(x1, y1) * tx) * ty;
        out[(size_t(y) * dw + x) * 4 + c] = uint8_t(std::lround(std::clamp(v, 0.0f, 255.0f)));
      }
    }
  }
  return out;
}

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr, "usage: ge_texpatch <replace dir> <game assets dir>\n");
    return 2;
  }
  const fs::path replace = argv[1], game = argv[2];
  std::error_code ec;
  std::map<fs::path, std::vector<fs::path>> by_file;
  for (auto it = fs::recursive_directory_iterator(replace, ec); !ec && it != fs::end(it); it.increment(ec)) {
    std::string ext = it->path().extension().string();
    for (char& c : ext) c = char(std::tolower(static_cast<unsigned char>(c)));
    if (!it->is_regular_file(ec) || ext != ".png") continue;
    by_file[fs::relative(it->path().parent_path(), replace, ec)].push_back(it->path());
  }
  int replaced = 0, problems = 0;
  for (auto& [rel, pngs] : by_file) {
    const fs::path target = game / rel;
    std::ifstream in(target, std::ios::binary);
    std::vector<uint8_t> data((std::istreambuf_iterator<char>(in)), {});
    in.close();
    std::vector<TextureInfo> texs;
    if (data.empty() || !ParseCaff(data, texs)) {
      std::printf("    skipped %s: no such game file with textures\n", rel.generic_string().c_str());
      problems++;
      continue;
    }
    bool changed = false;
    std::sort(pngs.begin(), pngs.end());
    for (const fs::path& png : pngs) {
      const std::string name = png.filename().string();
      uint32_t id = 0;
      size_t i = 0;
      while (i < name.size() && std::isdigit(static_cast<unsigned char>(name[i]))) id = id * 10 + uint32_t(name[i++] - '0');
      const auto t = std::find_if(texs.begin(), texs.end(), [&](const TextureInfo& x) { return x.id == id; });
      if (i == 0 || t == texs.end() || !IsSupported(*t)) {
        std::printf("    skipped %s/%s: no texture %u there\n", rel.generic_string().c_str(), name.c_str(), id);
        problems++;
        continue;
      }
      uint32_t w = 0, h = 0;
      std::vector<uint8_t> rgba;
      if (!ReadPng(png, w, h, rgba)) {
        std::printf("    skipped %s: couldn't read it (needs a non-interlaced PNG)\n", png.string().c_str());
        problems++;
        continue;
      }
      if (w != t->width || h != t->height) rgba = Scale(rgba, w, h, t->width, t->height);
      if (Encode(data, *t, rgba)) {
        changed = true;
        replaced++;
      }
    }
    if (!changed) continue;
    const fs::path tmp = target.string() + ".patching";
    {
      std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
      out.write(reinterpret_cast<const char*>(data.data()), std::streamsize(data.size()));
      if (!out) { std::printf("    couldn't write %s\n", tmp.string().c_str()); problems++; continue; }
    }
    fs::rename(tmp, target, ec);  // replaces the clone with the patched copy
    if (ec) { std::printf("    couldn't replace %s\n", target.string().c_str()); problems++; }
  }
  std::printf("    %d texture%s replaced%s\n", replaced, replaced == 1 ? "" : "s",
              problems ? " (some skipped, see above)" : "");
  return 0;
}
