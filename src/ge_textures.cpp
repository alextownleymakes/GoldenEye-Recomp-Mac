// ge - ReXGlue Recompiled Project
//
// Custom textures (see ge_textures.h).
//
// This file is yours to edit. 'rexglue migrate' will NOT overwrite it.

#include "ge_textures.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <sstream>

#include <mutex>

#if !defined(GE_TEXTURES_STANDALONE)
#include <rex/cvar.h>
#include <rex/logging.h>

REXCVAR_DEFINE_BOOL(ge_custom_textures, false, "Graphics",
                    "Use the PNGs in the Textures/Replace folder in place of the game's textures "
                    "(read at launch)");
#endif

namespace ge::textures {
namespace {

namespace fs = std::filesystem;

// Tiny "{}" formatter (log lines are built before the logger exists).
inline void FmtOne(std::ostringstream& os, const char*& f) {
  while (*f) os << *f++;
}
template <typename T, typename... R>
void FmtOne(std::ostringstream& os, const char*& f, const T& v, const R&... rest) {
  while (*f && !(f[0] == '{' && f[1] == '}')) os << *f++;
  if (*f) { f += 2; os << v; }
  FmtOne(os, f, rest...);
}
template <typename... A>
std::string Fmt(const char* f, const A&... a) {
  std::ostringstream os;
  FmtOne(os, f, a...);
  return os.str();
}

// The patched game folder is built before logging starts, so hold lines until
// SetLoggingReady().
#if !defined(GE_TEXTURES_STANDALONE)
std::mutex g_log_mutex;
std::vector<std::string> g_pending_log;
bool g_log_ready = false;
#endif
void Log(const std::string& line) {
#if defined(GE_TEXTURES_STANDALONE)
  std::fprintf(stderr, "[textures] %s\n", line.c_str());
#else
  std::lock_guard<std::mutex> lock(g_log_mutex);
  if (g_log_ready) REXLOG_INFO("{}", line);
  else g_pending_log.push_back(line);
#endif
}
#define GE_TEX_LOG(...) Log(Fmt(__VA_ARGS__))

fs::path g_folder;
fs::path g_game_root;

uint32_t Be32(const std::vector<uint8_t>& d, size_t o) {
  return (uint32_t(d[o]) << 24) | (uint32_t(d[o + 1]) << 16) | (uint32_t(d[o + 2]) << 8) | d[o + 3];
}
uint16_t Be16(const std::vector<uint8_t>& d, size_t o) { return uint16_t((d[o] << 8) | d[o + 1]); }

bool ReadFile(const fs::path& p, std::vector<uint8_t>& out) {
  std::ifstream f(p, std::ios::binary);
  if (!f) return false;
  f.seekg(0, std::ios::end);
  const std::streamoff n = f.tellg();
  if (n < 0) return false;
  out.resize(size_t(n));
  f.seekg(0);
  f.read(reinterpret_cast<char*>(out.data()), n);
  return bool(f);
}
bool WriteFile(const fs::path& p, const std::vector<uint8_t>& data) {
  std::error_code ec;
  fs::create_directories(p.parent_path(), ec);
  std::ofstream f(p, std::ios::binary | std::ios::trunc);
  if (!f) return false;
  f.write(reinterpret_cast<const char*>(data.data()), std::streamsize(data.size()));
  return bool(f);
}

// ---- Xbox 360 tiling ---------------------------------------------------------
// Block index of block (x, y) in a tiled surface `width` blocks wide, with
// `bpb` bytes per block (XGAddress2DTiledOffset).
uint32_t TiledBlockIndex(uint32_t x, uint32_t y, uint32_t width, uint32_t bpb) {
  const uint32_t aligned = (width + 31) & ~31u;
  const uint32_t lb = (bpb >> 2) + ((bpb >> 1) >> (bpb >> 2));
  const uint32_t macro = ((x >> 5) + (y >> 5) * (aligned >> 5)) << (lb + 7);
  const uint32_t micro = ((x & 7) + ((y & 6) << 2)) << lb;
  const uint32_t off = macro + ((micro & ~15u) << 1) + (micro & 15) + ((y & 8) << (3 + lb)) + ((y & 1) << 4);
  return (((off & ~511u) << 3) + ((off & 448) << 2) + (off & 63) + ((y & 16) << 7) +
          ((((y & 8) >> 2) + (x >> 3)) & 3) * 64) >> lb;
}

// ---- DXT ---------------------------------------------------------------------
enum : uint32_t { kDxt1 = 0x12, kDxt3 = 0x13, kDxt5 = 0x14 };

uint32_t BlockBytes(uint32_t fmt) { return fmt == kDxt1 ? 8 : 16; }

void Unpack565(uint16_t c, int rgb[3]) {
  rgb[0] = ((c >> 11) & 31) * 255 / 31;
  rgb[1] = ((c >> 5) & 63) * 255 / 63;
  rgb[2] = (c & 31) * 255 / 31;
}
uint16_t Pack565(float r, float g, float b) {
  auto q = [](float v, int bits) {
    const int m = (1 << bits) - 1;
    return std::clamp(int(std::lround(v * m / 255.0f)), 0, m);
  };
  return uint16_t((q(r, 5) << 11) | (q(g, 6) << 5) | q(b, 5));
}

// px: 16 RGBA texels. Writes the 8-byte colour block (standard little-endian).
void DecodeColor(const uint8_t* blk, bool allow_punch, uint8_t px[16][4]) {
  const uint16_t c0 = uint16_t(blk[0] | (blk[1] << 8)), c1 = uint16_t(blk[2] | (blk[3] << 8));
  const uint32_t bits = blk[4] | (blk[5] << 8) | (blk[6] << 16) | (uint32_t(blk[7]) << 24);
  int p[4][4];
  Unpack565(c0, p[0]);
  Unpack565(c1, p[1]);
  p[0][3] = p[1][3] = 255;
  if (c0 > c1 || !allow_punch) {
    for (int k = 0; k < 3; k++) {
      p[2][k] = (2 * p[0][k] + p[1][k]) / 3;
      p[3][k] = (p[0][k] + 2 * p[1][k]) / 3;
    }
    p[2][3] = p[3][3] = 255;
  } else {
    for (int k = 0; k < 3; k++) p[2][k] = (p[0][k] + p[1][k]) / 2;
    p[2][3] = 255;
    p[3][0] = p[3][1] = p[3][2] = 0;
    p[3][3] = 0;
  }
  for (int i = 0; i < 16; i++) {
    const int k = (bits >> (2 * i)) & 3;
    for (int c = 0; c < 4; c++) px[i][c] = uint8_t(p[k][c]);
  }
}

void EncodeColor(const uint8_t px[16][4], bool punch_alpha, uint8_t* out) {
  // Punch-through (DXT1 only): texels below half alpha become transparent.
  bool transparent[16] = {};
  bool any_transparent = false;
  if (punch_alpha) {
    for (int i = 0; i < 16; i++) {
      transparent[i] = px[i][3] < 128;
      any_transparent |= transparent[i];
    }
  }
  // Principal axis of the (opaque) colours.
  float mean[3] = {0, 0, 0};
  int n = 0;
  for (int i = 0; i < 16; i++) {
    if (transparent[i]) continue;
    for (int c = 0; c < 3; c++) mean[c] += px[i][c];
    n++;
  }
  if (n == 0) {
    std::memset(out, 0, 4);
    out[4] = out[5] = out[6] = out[7] = 0xFF;  // all index 3 = transparent (c0 <= c1)
    return;
  }
  for (float& m : mean) m /= float(n);
  float cov[6] = {};
  for (int i = 0; i < 16; i++) {
    if (transparent[i]) continue;
    const float r = px[i][0] - mean[0], g = px[i][1] - mean[1], b = px[i][2] - mean[2];
    cov[0] += r * r; cov[1] += r * g; cov[2] += r * b;
    cov[3] += g * g; cov[4] += g * b; cov[5] += b * b;
  }
  float axis[3] = {0.9f, 1.0f, 0.7f};
  for (int it = 0; it < 8; it++) {
    const float x = cov[0] * axis[0] + cov[1] * axis[1] + cov[2] * axis[2];
    const float y = cov[1] * axis[0] + cov[3] * axis[1] + cov[4] * axis[2];
    const float z = cov[2] * axis[0] + cov[4] * axis[1] + cov[5] * axis[2];
    const float len = std::sqrt(x * x + y * y + z * z);
    if (len < 1e-6f) break;
    axis[0] = x / len; axis[1] = y / len; axis[2] = z / len;
  }
  float lo = 1e9f, hi = -1e9f;
  for (int i = 0; i < 16; i++) {
    if (transparent[i]) continue;
    const float t = (px[i][0] - mean[0]) * axis[0] + (px[i][1] - mean[1]) * axis[1] + (px[i][2] - mean[2]) * axis[2];
    lo = std::min(lo, t);
    hi = std::max(hi, t);
  }
  const float inset = (hi - lo) / 32.0f;
  lo += inset;
  hi -= inset;
  float e0[3], e1[3];
  for (int c = 0; c < 3; c++) {
    e0[c] = std::clamp(mean[c] + axis[c] * hi, 0.0f, 255.0f);
    e1[c] = std::clamp(mean[c] + axis[c] * lo, 0.0f, 255.0f);
  }
  uint16_t c0 = Pack565(e0[0], e0[1], e0[2]);
  uint16_t c1 = Pack565(e1[0], e1[1], e1[2]);

  const bool three = any_transparent;  // 3 colours + transparent needs c0 <= c1
  if (three ? (c0 > c1) : (c0 < c1)) std::swap(c0, c1);
  int p[4][3];
  Unpack565(c0, p[0]);
  Unpack565(c1, p[1]);
  int count = 4;
  if (three || c0 == c1) {
    for (int k = 0; k < 3; k++) p[2][k] = (p[0][k] + p[1][k]) / 2;
    count = 3;
  } else {
    for (int k = 0; k < 3; k++) {
      p[2][k] = (2 * p[0][k] + p[1][k]) / 3;
      p[3][k] = (p[0][k] + 2 * p[1][k]) / 3;
    }
  }
  uint32_t bits = 0;
  for (int i = 0; i < 16; i++) {
    int best = 0;
    if (transparent[i]) {
      best = 3;
    } else {
      int best_d = 1 << 30;
      for (int k = 0; k < count; k++) {
        const int dr = px[i][0] - p[k][0], dg = px[i][1] - p[k][1], db = px[i][2] - p[k][2];
        const int d = dr * dr * 3 + dg * dg * 4 + db * db * 2;
        if (d < best_d) { best_d = d; best = k; }
      }
    }
    bits |= uint32_t(best) << (2 * i);
  }
  out[0] = uint8_t(c0); out[1] = uint8_t(c0 >> 8);
  out[2] = uint8_t(c1); out[3] = uint8_t(c1 >> 8);
  out[4] = uint8_t(bits); out[5] = uint8_t(bits >> 8);
  out[6] = uint8_t(bits >> 16); out[7] = uint8_t(bits >> 24);
}

void DecodeAlpha5(const uint8_t* blk, uint8_t px[16][4]) {
  const int a0 = blk[0], a1 = blk[1];
  int pal[8] = {a0, a1};
  if (a0 > a1) {
    for (int i = 0; i < 6; i++) pal[2 + i] = ((6 - i) * a0 + (1 + i) * a1) / 7;
  } else {
    for (int i = 0; i < 4; i++) pal[2 + i] = ((4 - i) * a0 + (1 + i) * a1) / 5;
    pal[6] = 0;
    pal[7] = 255;
  }
  uint64_t bits = 0;
  for (int i = 0; i < 6; i++) bits |= uint64_t(blk[2 + i]) << (8 * i);
  for (int i = 0; i < 16; i++) px[i][3] = uint8_t(pal[(bits >> (3 * i)) & 7]);
}
void EncodeAlpha5(const uint8_t px[16][4], uint8_t* out) {
  int a0 = 0, a1 = 255;
  for (int i = 0; i < 16; i++) { a0 = std::max<int>(a0, px[i][3]); a1 = std::min<int>(a1, px[i][3]); }
  out[0] = uint8_t(a0);
  out[1] = uint8_t(a1);
  uint64_t bits = 0;
  if (a0 > a1) {
    int pal[8] = {a0, a1};
    for (int i = 0; i < 6; i++) pal[2 + i] = ((6 - i) * a0 + (1 + i) * a1) / 7;
    for (int i = 0; i < 16; i++) {
      int best = 0, best_d = 1 << 30;
      for (int k = 0; k < 8; k++) {
        const int d = std::abs(px[i][3] - pal[k]);
        if (d < best_d) { best_d = d; best = k; }
      }
      bits |= uint64_t(best) << (3 * i);
    }
  }
  for (int i = 0; i < 6; i++) out[2 + i] = uint8_t(bits >> (8 * i));
}
void DecodeAlpha3(const uint8_t* blk, uint8_t px[16][4]) {
  for (int i = 0; i < 16; i++) {
    const int nib = (blk[i / 2] >> ((i & 1) * 4)) & 15;
    px[i][3] = uint8_t(nib * 17);
  }
}
void EncodeAlpha3(const uint8_t px[16][4], uint8_t* out) {
  std::memset(out, 0, 8);
  for (int i = 0; i < 16; i++) {
    const int nib = (px[i][3] * 15 + 127) / 255;
    out[i / 2] |= uint8_t(nib << ((i & 1) * 4));
  }
}

// The 360 stores each 16-bit word big-endian (8-in-16).
void Swap16(uint8_t* b, size_t n) {
  for (size_t i = 0; i + 1 < n; i += 2) std::swap(b[i], b[i + 1]);
}

// ---- zlib (inflate + a small fixed-Huffman deflate) ----------------------------
uint32_t Crc32(const uint8_t* d, size_t n, uint32_t crc = 0) {
  static uint32_t table[256];
  static bool init = false;
  if (!init) {
    for (uint32_t i = 0; i < 256; i++) {
      uint32_t c = i;
      for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
      table[i] = c;
    }
    init = true;
  }
  crc = ~crc;
  for (size_t i = 0; i < n; i++) crc = table[(crc ^ d[i]) & 0xFF] ^ (crc >> 8);
  return ~crc;
}
uint32_t Adler32(const uint8_t* d, size_t n) {
  uint32_t a = 1, b = 0;
  for (size_t i = 0; i < n; i++) {
    a = (a + d[i]) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

const uint16_t kLenBase[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                               35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
const uint8_t kLenExtra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                               3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
const uint16_t kDistBase[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
                                193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
                                6145, 8193, 12289, 16385, 24577};
const uint8_t kDistExtra[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
                                6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

struct Huffman {
  uint16_t count[16] = {};
  std::vector<uint16_t> symbol;
  bool Build(const uint8_t* lengths, int n) {
    std::memset(count, 0, sizeof(count));
    for (int i = 0; i < n; i++) count[lengths[i]]++;
    count[0] = 0;
    uint16_t offs[16] = {};
    for (int i = 1; i < 16; i++) offs[i] = uint16_t(offs[i - 1] + count[i - 1]);
    symbol.assign(size_t(n), 0);
    for (int i = 0; i < n; i++)
      if (lengths[i]) symbol[offs[lengths[i]]++] = uint16_t(i);
    return true;
  }
};

struct BitReader {
  const uint8_t* d;
  size_t n, pos = 0;
  uint32_t buf = 0;
  int cnt = 0;
  bool bad = false;
  int Bits(int need) {
    while (cnt < need) {
      if (pos >= n) { bad = true; return 0; }
      buf |= uint32_t(d[pos++]) << cnt;
      cnt += 8;
    }
    const int v = int(buf & ((1u << need) - 1));
    buf >>= need;
    cnt -= need;
    return v;
  }
  int Decode(const Huffman& h) {
    int code = 0, first = 0, index = 0;
    for (int len = 1; len < 16; len++) {
      code |= Bits(1);
      if (bad) return -1;
      const int c = h.count[len];
      if (code - c < first) return h.symbol[size_t(index + (code - first))];
      index += c;
      first += c;
      first <<= 1;
      code <<= 1;
    }
    bad = true;
    return -1;
  }
};

bool Inflate(const uint8_t* src, size_t n, std::vector<uint8_t>& out) {
  BitReader br{src, n};
  bool last = false;
  while (!last) {
    last = br.Bits(1);
    const int type = br.Bits(2);
    if (br.bad) return false;
    if (type == 0) {
      br.buf = 0;
      br.cnt = 0;
      if (br.pos + 4 > n) return false;
      const uint32_t len = src[br.pos] | (src[br.pos + 1] << 8);
      br.pos += 4;
      if (br.pos + len > n) return false;
      out.insert(out.end(), src + br.pos, src + br.pos + len);
      br.pos += len;
      continue;
    }
    Huffman lit, dist;
    if (type == 1) {
      uint8_t l[288], dl[30];
      for (int i = 0; i < 144; i++) l[i] = 8;
      for (int i = 144; i < 256; i++) l[i] = 9;
      for (int i = 256; i < 280; i++) l[i] = 7;
      for (int i = 280; i < 288; i++) l[i] = 8;
      for (int i = 0; i < 30; i++) dl[i] = 5;
      lit.Build(l, 288);
      dist.Build(dl, 30);
    } else if (type == 2) {
      const int nlen = br.Bits(5) + 257, ndist = br.Bits(5) + 1, ncode = br.Bits(4) + 4;
      static const uint8_t order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
      uint8_t cl[19] = {};
      for (int i = 0; i < ncode; i++) cl[order[i]] = uint8_t(br.Bits(3));
      Huffman clh;
      clh.Build(cl, 19);
      uint8_t lengths[320] = {};
      int i = 0;
      while (i < nlen + ndist) {
        const int sym = br.Decode(clh);
        if (sym < 0) return false;
        if (sym < 16) {
          lengths[i++] = uint8_t(sym);
        } else {
          int rep = 0, val = 0;
          if (sym == 16) {
            if (i == 0) return false;
            val = lengths[i - 1];
            rep = 3 + br.Bits(2);
          } else if (sym == 17) {
            rep = 3 + br.Bits(3);
          } else {
            rep = 11 + br.Bits(7);
          }
          if (i + rep > nlen + ndist) return false;
          while (rep--) lengths[i++] = uint8_t(val);
        }
      }
      lit.Build(lengths, nlen);
      dist.Build(lengths + nlen, ndist);
    } else {
      return false;
    }
    for (;;) {
      const int sym = br.Decode(lit);
      if (sym < 0) return false;
      if (sym < 256) {
        out.push_back(uint8_t(sym));
      } else if (sym == 256) {
        break;
      } else {
        const int li = sym - 257;
        if (li >= 29) return false;
        const int len = kLenBase[li] + br.Bits(kLenExtra[li]);
        const int ds = br.Decode(dist);
        if (ds < 0 || ds >= 30) return false;
        const size_t d = kDistBase[ds] + size_t(br.Bits(kDistExtra[ds]));
        if (br.bad || d > out.size()) return false;
        const size_t from = out.size() - d;
        for (int k = 0; k < len; k++) out.push_back(out[from + size_t(k)]);
      }
    }
  }
  return true;
}

struct BitWriter {
  std::vector<uint8_t>& out;
  uint32_t buf = 0;
  int cnt = 0;
  void Put(uint32_t v, int n) {  // LSB-first
    buf |= v << cnt;
    cnt += n;
    while (cnt >= 8) {
      out.push_back(uint8_t(buf));
      buf >>= 8;
      cnt -= 8;
    }
  }
  void PutRev(uint32_t code, int n) {  // Huffman codes go MSB-first
    uint32_t r = 0;
    for (int i = 0; i < n; i++) r |= ((code >> i) & 1) << (n - 1 - i);
    Put(r, n);
  }
  void Flush() {
    if (cnt) out.push_back(uint8_t(buf));
    buf = 0;
    cnt = 0;
  }
};

void PutLiteral(BitWriter& bw, int v) {
  if (v < 144) bw.PutRev(0x30 + v, 8);
  else if (v < 256) bw.PutRev(0x190 + (v - 144), 9);
  else if (v < 280) bw.PutRev(v - 256, 7);
  else bw.PutRev(0xC0 + (v - 280), 8);
}

// Fixed-Huffman deflate with a hashed LZ77 match finder.
void Deflate(const uint8_t* src, size_t n, std::vector<uint8_t>& out) {
  BitWriter bw{out};
  bw.Put(1, 1);  // final block
  bw.Put(1, 2);  // fixed Huffman
  constexpr int kHashBits = 15;
  constexpr size_t kWindow = 32768;
  std::vector<int32_t> head(1 << kHashBits, -1), prev(n, -1);
  auto hash = [&](size_t i) {
    return ((uint32_t(src[i]) << 10) ^ (uint32_t(src[i + 1]) << 5) ^ src[i + 2]) & ((1 << kHashBits) - 1);
  };
  size_t i = 0;
  while (i < n) {
    int best_len = 0;
    size_t best_dist = 0;
    if (i + 2 < n) {
      const uint32_t h = hash(i);
      int32_t cand = head[h];
      int chain = 48;
      while (cand >= 0 && i - size_t(cand) <= kWindow && chain--) {
        const size_t c = size_t(cand);
        int len = 0;
        const int max_len = int(std::min<size_t>(258, n - i));
        while (len < max_len && src[c + size_t(len)] == src[i + size_t(len)]) len++;
        if (len > best_len) {
          best_len = len;
          best_dist = i - c;
          if (len == max_len) break;
        }
        cand = prev[c];
      }
    }
    const size_t step = best_len >= 3 ? size_t(best_len) : 1;
    if (best_len >= 3) {
      int li = 28;
      while (kLenBase[li] > best_len) li--;
      PutLiteral(bw, 257 + li);
      bw.Put(uint32_t(best_len - kLenBase[li]), kLenExtra[li]);
      int di = 29;
      while (kDistBase[di] > best_dist) di--;
      bw.PutRev(uint32_t(di), 5);
      bw.Put(uint32_t(best_dist - kDistBase[di]), kDistExtra[di]);
    } else {
      PutLiteral(bw, src[i]);
    }
    for (size_t k = 0; k < step; k++, i++) {
      if (i + 2 < n) {
        const uint32_t h = hash(i);
        prev[i] = head[h];
        head[h] = int32_t(i);
      }
    }
  }
  PutLiteral(bw, 256);
  bw.Flush();
}

void PutBe32(std::vector<uint8_t>& v, uint32_t x) {
  v.push_back(uint8_t(x >> 24));
  v.push_back(uint8_t(x >> 16));
  v.push_back(uint8_t(x >> 8));
  v.push_back(uint8_t(x));
}
void PngChunk(std::vector<uint8_t>& png, const char type[4], const std::vector<uint8_t>& data) {
  PutBe32(png, uint32_t(data.size()));
  const size_t start = png.size();
  png.insert(png.end(), type, type + 4);
  png.insert(png.end(), data.begin(), data.end());
  PutBe32(png, Crc32(png.data() + start, png.size() - start));
}

int Paeth(int a, int b, int c) {
  const int p = a + b - c, pa = std::abs(p - a), pb = std::abs(p - b), pc = std::abs(p - c);
  return (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
}

// Bilinear resize of RGBA8.
std::vector<uint8_t> Resize(const std::vector<uint8_t>& src, uint32_t sw, uint32_t sh, uint32_t dw, uint32_t dh) {
  std::vector<uint8_t> dst(size_t(dw) * dh * 4);
  for (uint32_t y = 0; y < dh; y++) {
    const float fy = std::max(0.0f, (y + 0.5f) * sh / dh - 0.5f);
    const uint32_t y0 = std::min(uint32_t(fy), sh - 1), y1 = std::min(y0 + 1, sh - 1);
    const float ty = fy - float(y0);
    for (uint32_t x = 0; x < dw; x++) {
      const float fx = std::max(0.0f, (x + 0.5f) * sw / dw - 0.5f);
      const uint32_t x0 = std::min(uint32_t(fx), sw - 1), x1 = std::min(x0 + 1, sw - 1);
      const float tx = fx - float(x0);
      for (int c = 0; c < 4; c++) {
        auto at = [&](uint32_t xx, uint32_t yy) { return float(src[(size_t(yy) * sw + xx) * 4 + c]); };
        const float v = (at(x0, y0) * (1 - tx) + at(x1, y0) * tx) * (1 - ty) +
                        (at(x0, y1) * (1 - tx) + at(x1, y1) * tx) * ty;
        dst[(size_t(y) * dw + x) * 4 + c] = uint8_t(std::clamp(std::lround(v), 0L, 255L));
      }
    }
  }
  return dst;
}

// "03_64x32.png" -> 3
bool IdFromName(const std::string& name, uint32_t& id) {
  size_t i = 0;
  uint32_t v = 0;
  while (i < name.size() && name[i] >= '0' && name[i] <= '9') v = v * 10 + uint32_t(name[i++] - '0');
  if (i == 0) return false;
  id = v;
  return true;
}

std::string LowerExt(const fs::path& p) {
  std::string e = p.extension().string();
  for (char& c : e) c = char(std::tolower(static_cast<unsigned char>(c)));
  return e;
}

}  // namespace

void WriteReadme(const fs::path& folder) {
  std::error_code ec;
  fs::create_directories(folder / "Export", ec);
  fs::create_directories(folder / "Replace", ec);
  const std::string text =
      "Custom textures\n"
      "===============\n\n"
      "Export/   The game's own textures, written by the Export buttons in the VIDEO tab of the\n"
      "          in-game menu. Each folder is named after the game file the textures\n"
      "          come from; each image is named <number>_<width>x<height>.png.\n\n"
      "Replace/  Your edited textures. Copy a folder (or just the images you changed)\n"
      "          from Export/ to the same place under Replace/, keeping the file names\n"
      "          (the number at the start is what matters), and edit the images.\n\n"
      "Then turn on \"Use custom textures\" in the VIDEO tab and restart the game.\n"
      "Images of a different size are scaled to the original size. Transparent\n"
      "areas stay transparent where the original texture supports it.\n"
      "Nothing in the game's own files is changed; delete Replace/ to undo.\n";
  WriteFile(folder / "README.txt", std::vector<uint8_t>(text.begin(), text.end()));
}

// ---- Public -----------------------------------------------------------------

void SetLoggingReady() {
#if !defined(GE_TEXTURES_STANDALONE)
  std::lock_guard<std::mutex> lock(g_log_mutex);
  g_log_ready = true;
  for (const std::string& line : g_pending_log) REXLOG_INFO("{}", line);
  g_pending_log.clear();
#endif
}

bool ConfigSaysOn(const fs::path& config_file) {
  std::ifstream f(config_file);
  std::string line;
  while (std::getline(f, line)) {
    const size_t k = line.find_first_not_of(" \t");
    if (k == std::string::npos || line.compare(k, 18, "ge_custom_textures") != 0) continue;
    const size_t eq = line.find('=', k);
    return eq != std::string::npos && line.find("true", eq) != std::string::npos;
  }
  return false;
}

void SetFolder(const fs::path& folder) { g_folder = folder; }
const fs::path& Folder() { return g_folder; }
void SetGameRoot(const fs::path& root) { g_game_root = root; }
const fs::path& GameRoot() { return g_game_root; }

bool ParseCaff(const std::vector<uint8_t>& d, std::vector<TextureInfo>& out) {
  out.clear();
  if (d.size() < 0x200 || std::memcmp(d.data(), "CAFF", 4) != 0) return false;
  // The section names (".gpu", ".data", ".stream", in file order) follow the
  // section table; each table entry is 0x21 bytes, the last one ending at the
  // names, with the section size 0x18 bytes before the entry's end.
  size_t names_at = 0;
  const size_t scan_end = std::min<size_t>(d.size(), 0x400);
  for (size_t i = 0x40; i + 5 < scan_end; i++) {
    if (std::memcmp(&d[i], ".gpu", 4) == 0 || std::memcmp(&d[i], ".data", 5) == 0 ||
        std::memcmp(&d[i], ".stream", 7) == 0) {
      names_at = i;
      break;
    }
  }
  if (!names_at) return false;
  std::vector<std::string> names;
  size_t p = names_at;
  while (p < d.size() && d[p] == '.') {
    std::string s;
    while (p < d.size() && d[p]) s += char(d[p++]);
    names.push_back(s);
    p++;
  }
  const size_t n = names.size();
  if (n == 0 || n > 8 || names_at < 0x18 + 0x21 * (n - 1)) return false;
  std::vector<size_t> sizes(n), bases(n);
  size_t total = 0;
  for (size_t i = 0; i < n; i++) {
    sizes[i] = Be32(d, names_at - 0x18 - 0x21 * (n - 1 - i));
    total += sizes[i];
  }
  if (total > d.size()) return false;
  size_t o = d.size() - total;
  for (size_t i = 0; i < n; i++) {
    bases[i] = o;
    o += sizes[i];
  }
  // Symbol records: id, offset, size (big-endian u32 each), section (1-based),
  // kind (5 = header, 0x0C = GPU data).
  struct Rec { size_t sec, off, size; bool set = false; };
  std::map<uint32_t, std::pair<Rec, Rec>> recs;
  const size_t end = std::min(bases[0], d.size());
  for (size_t i = names_at; i + 14 <= end; i++) {
    const uint8_t sec = d[i + 12], kind = d[i + 13];
    if (sec < 1 || sec > n || (kind != 5 && kind != 0x0C)) continue;
    const uint32_t off = Be32(d, i + 4), size = Be32(d, i + 8);
    if (!size || size_t(off) + size > sizes[sec - 1]) continue;
    auto& entry = recs[Be32(d, i)];
    Rec& r = kind == 5 ? entry.first : entry.second;
    if (!r.set) r = Rec{sec, off, size, true};
  }
  for (auto& [id, pr] : recs) {
    const Rec& h = pr.first;
    const Rec& g = pr.second;
    if (!h.set || !g.set || h.size != 0x70) continue;
    const size_t ho = bases[h.sec - 1] + h.off;
    if (ho + 0x70 > d.size() || std::memcmp(&d[ho], "texture\0" "04.05.05.0032", 21) != 0) continue;
    TextureInfo t;
    t.id = id;
    t.format = d[ho + 0x1B];
    t.width = Be16(d, ho + 0x24);
    t.height = Be16(d, ho + 0x26);
    t.levels = d[ho + 0x30];
    t.header_offset = ho;
    t.data_offset = bases[g.sec - 1] + g.off;
    t.data_size = g.size;
    if (t.width && t.height && t.data_offset + t.data_size <= d.size()) out.push_back(t);
  }
  return true;
}

bool IsSupported(const TextureInfo& t) {
  const uint32_t f = t.format & 0x3F;
  return f == kDxt1 || f == kDxt3 || f == kDxt5;
}

bool Decode(const std::vector<uint8_t>& file, const TextureInfo& t, std::vector<uint8_t>& rgba) {
  if (!IsSupported(t)) return false;
  const uint32_t fmt = t.format & 0x3F, bpb = BlockBytes(fmt);
  const uint32_t bw = std::max(1u, (t.width + 3) / 4), bh = std::max(1u, (t.height + 3) / 4);
  rgba.assign(size_t(t.width) * t.height * 4, 0);
  for (uint32_t by = 0; by < bh; by++) {
    for (uint32_t bx = 0; bx < bw; bx++) {
      const size_t at = size_t(TiledBlockIndex(bx, by, bw, bpb)) * bpb;
      if (at + bpb > t.data_size) return false;
      uint8_t blk[16];
      std::memcpy(blk, &file[t.data_offset + at], bpb);
      Swap16(blk, bpb);
      uint8_t px[16][4];
      if (fmt == kDxt1) {
        DecodeColor(blk, true, px);
      } else {
        DecodeColor(blk + 8, false, px);
        if (fmt == kDxt3) DecodeAlpha3(blk, px);
        else DecodeAlpha5(blk, px);
      }
      for (int i = 0; i < 16; i++) {
        const uint32_t x = bx * 4 + uint32_t(i % 4), y = by * 4 + uint32_t(i / 4);
        if (x < t.width && y < t.height) std::memcpy(&rgba[(size_t(y) * t.width + x) * 4], px[i], 4);
      }
    }
  }
  return true;
}

bool Encode(std::vector<uint8_t>& file, const TextureInfo& t, const std::vector<uint8_t>& rgba) {
  if (!IsSupported(t) || rgba.size() != size_t(t.width) * t.height * 4) return false;
  const uint32_t fmt = t.format & 0x3F, bpb = BlockBytes(fmt);
  const uint32_t bw = std::max(1u, (t.width + 3) / 4), bh = std::max(1u, (t.height + 3) / 4);
  for (uint32_t by = 0; by < bh; by++) {
    for (uint32_t bx = 0; bx < bw; bx++) {
      uint8_t px[16][4];
      for (int i = 0; i < 16; i++) {  // clamp to the edge for partial blocks
        const uint32_t x = std::min(bx * 4 + uint32_t(i % 4), t.width - 1);
        const uint32_t y = std::min(by * 4 + uint32_t(i / 4), t.height - 1);
        std::memcpy(px[i], &rgba[(size_t(y) * t.width + x) * 4], 4);
      }
      uint8_t blk[16];
      if (fmt == kDxt1) {
        EncodeColor(px, true, blk);
      } else {
        EncodeColor(px, false, blk + 8);
        if (fmt == kDxt3) EncodeAlpha3(px, blk);
        else EncodeAlpha5(px, blk);
      }
      Swap16(blk, bpb);
      const size_t at = size_t(TiledBlockIndex(bx, by, bw, bpb)) * bpb;
      if (at + bpb > t.data_size) return false;
      std::memcpy(&file[t.data_offset + at], blk, bpb);
    }
  }
  // Only the full-size level is replaced, so tell the game the texture has a
  // single level; otherwise it would keep drawing the old smaller copies at a
  // distance.
  file[t.header_offset + 0x30] = 1;
  return true;
}

bool WritePng(const fs::path& path, uint32_t w, uint32_t h, const std::vector<uint8_t>& rgba) {
  bool opaque = true;
  for (size_t i = 3; i < rgba.size(); i += 4) opaque &= rgba[i] == 255;
  const uint32_t ch = opaque ? 3 : 4;
  const size_t stride = size_t(w) * ch;
  std::vector<uint8_t> raw;
  raw.reserve((stride + 1) * h);
  std::vector<uint8_t> row(stride), prev_row(stride, 0), best, cand(stride);
  for (uint32_t y = 0; y < h; y++) {
    for (uint32_t x = 0; x < w; x++)
      for (uint32_t c = 0; c < ch; c++) row[x * ch + c] = rgba[(size_t(y) * w + x) * 4 + c];
    // Pick the filter with the smallest sum of absolute residuals.
    long best_score = -1;
    int best_type = 0;
    for (int type = 0; type < 5; type++) {
      long score = 0;
      for (size_t i = 0; i < stride; i++) {
        const int a = i >= ch ? row[i - ch] : 0, b = prev_row[i], c = i >= ch ? prev_row[i - ch] : 0;
        int pred = 0;
        switch (type) {
          case 1: pred = a; break;
          case 2: pred = b; break;
          case 3: pred = (a + b) / 2; break;
          case 4: pred = Paeth(a, b, c); break;
          default: break;
        }
        cand[i] = uint8_t(row[i] - pred);
        score += std::abs(int(int8_t(cand[i])));
      }
      if (best_score < 0 || score < best_score) {
        best_score = score;
        best_type = type;
        best = cand;
      }
    }
    raw.push_back(uint8_t(best_type));
    raw.insert(raw.end(), best.begin(), best.end());
    prev_row = row;
  }
  std::vector<uint8_t> z = {0x78, 0x01};
  Deflate(raw.data(), raw.size(), z);
  PutBe32(z, Adler32(raw.data(), raw.size()));

  std::vector<uint8_t> png = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
  std::vector<uint8_t> ihdr;
  PutBe32(ihdr, w);
  PutBe32(ihdr, h);
  ihdr.push_back(8);
  ihdr.push_back(opaque ? 2 : 6);
  ihdr.push_back(0);
  ihdr.push_back(0);
  ihdr.push_back(0);
  PngChunk(png, "IHDR", ihdr);
  PngChunk(png, "IDAT", z);
  PngChunk(png, "IEND", {});
  return WriteFile(path, png);
}

bool ReadPng(const fs::path& path, uint32_t& w, uint32_t& h, std::vector<uint8_t>& rgba) {
  std::vector<uint8_t> d;
  if (!ReadFile(path, d) || d.size() < 33 || std::memcmp(d.data(), "\x89PNG\r\n\x1a\n", 8) != 0) return false;
  size_t p = 8;
  int depth = 0, ctype = 0, interlace = 0;
  std::vector<uint8_t> idat, plte, trns;
  while (p + 12 <= d.size()) {
    const uint32_t len = Be32(d, p);
    const std::string type(reinterpret_cast<const char*>(&d[p + 4]), 4);
    if (p + 12 + len > d.size()) return false;
    const uint8_t* body = &d[p + 8];
    if (type == "IHDR") {
      w = Be32(d, p + 8);
      h = Be32(d, p + 12);
      depth = body[8];
      ctype = body[9];
      interlace = body[12];
    } else if (type == "PLTE") {
      plte.assign(body, body + len);
    } else if (type == "tRNS") {
      trns.assign(body, body + len);
    } else if (type == "IDAT") {
      idat.insert(idat.end(), body, body + len);
    } else if (type == "IEND") {
      break;
    }
    p += 12 + len;
  }
  if (!w || !h || w > 8192 || h > 8192 || interlace != 0 || idat.size() < 2) return false;
  int channels = 0;
  switch (ctype) {
    case 0: channels = 1; break;
    case 2: channels = 3; break;
    case 3: channels = 1; break;
    case 4: channels = 2; break;
    case 6: channels = 4; break;
    default: return false;
  }
  if (depth != 1 && depth != 2 && depth != 4 && depth != 8 && depth != 16) return false;
  std::vector<uint8_t> raw;
  if (!Inflate(idat.data() + 2, idat.size() - 2, raw)) return false;
  const size_t bits_pp = size_t(channels) * size_t(depth);
  const size_t stride = (size_t(w) * bits_pp + 7) / 8;
  const size_t bpp = std::max<size_t>(1, bits_pp / 8);
  if (raw.size() < (stride + 1) * h) return false;
  std::vector<uint8_t> img(stride * h), prev(stride, 0);
  for (uint32_t y = 0; y < h; y++) {
    const uint8_t type = raw[y * (stride + 1)];
    const uint8_t* src = &raw[y * (stride + 1) + 1];
    uint8_t* row = &img[y * stride];
    for (size_t i = 0; i < stride; i++) {
      const int a = i >= bpp ? row[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      int pred = 0;
      switch (type) {
        case 0: break;
        case 1: pred = a; break;
        case 2: pred = b; break;
        case 3: pred = (a + b) / 2; break;
        case 4: pred = Paeth(a, b, c); break;
        default: return false;
      }
      row[i] = uint8_t(src[i] + pred);
    }
    std::memcpy(prev.data(), row, stride);
  }
  auto sample = [&](uint32_t y, size_t idx) -> int {  // idx-th sample in the row, scaled to 8 bits
    const uint8_t* row = &img[y * stride];
    if (depth == 8) return row[idx];
    if (depth == 16) return row[idx * 2];
    const size_t bit = idx * size_t(depth);
    const int v = (row[bit / 8] >> (8 - depth - int(bit % 8))) & ((1 << depth) - 1);
    return ctype == 3 ? v : v * 255 / ((1 << depth) - 1);
  };
  rgba.assign(size_t(w) * h * 4, 255);
  for (uint32_t y = 0; y < h; y++) {
    for (uint32_t x = 0; x < w; x++) {
      uint8_t* o = &rgba[(size_t(y) * w + x) * 4];
      const size_t s = size_t(x) * size_t(channels);
      switch (ctype) {
        case 0: o[0] = o[1] = o[2] = uint8_t(sample(y, s)); break;
        case 4: o[0] = o[1] = o[2] = uint8_t(sample(y, s)); o[3] = uint8_t(sample(y, s + 1)); break;
        case 2: for (int c = 0; c < 3; c++) o[c] = uint8_t(sample(y, s + size_t(c))); break;
        case 6: for (int c = 0; c < 4; c++) o[c] = uint8_t(sample(y, s + size_t(c))); break;
        case 3: {
          const int i = sample(y, s);
          if (size_t(i) * 3 + 2 < plte.size()) {
            o[0] = plte[size_t(i) * 3]; o[1] = plte[size_t(i) * 3 + 1]; o[2] = plte[size_t(i) * 3 + 2];
          }
          if (size_t(i) < trns.size()) o[3] = trns[size_t(i)];
          break;
        }
      }
    }
  }
  return true;
}

ExportResult ExportAll(const fs::path& game_root, const fs::path& folder, ExportProgress& progress,
                       const std::vector<std::string>& only) {
  ExportResult result;
  std::error_code ec;
  const fs::path files = game_root / "files";
  std::vector<fs::path> list;
  for (auto it = fs::recursive_directory_iterator(files, fs::directory_options::skip_permission_denied, ec);
       !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
    if (!it->is_regular_file(ec)) continue;
    if (!only.empty()) {
      const std::string rel = fs::relative(it->path(), game_root, ec).generic_string();
      if (std::none_of(only.begin(), only.end(), [&](const std::string& pre) { return rel.rfind(pre, 0) == 0; }))
        continue;
    }
    list.push_back(it->path());
  }
  if (list.empty()) {
    result.error = "no game files found in " + files.string();
    return result;
  }
  WriteReadme(folder);
  progress.files_total = int(list.size());
  for (const fs::path& path : list) {
    if (progress.cancel) {
      result.error = "cancelled";
      break;
    }
    std::vector<uint8_t> data;
    std::vector<TextureInfo> texs;
    if (ReadFile(path, data) && ParseCaff(data, texs) && !texs.empty()) {
      const fs::path out_dir = folder / "Export" / fs::relative(path, game_root, ec);
      bool any = false;
      for (const TextureInfo& t : texs) {
        if (!IsSupported(t)) {
          result.unsupported++;
          continue;
        }
        std::vector<uint8_t> rgba;
        if (!Decode(data, t, rgba)) continue;
        char name[64];
        std::snprintf(name, sizeof(name), "%02u_%ux%u.png", t.id, t.width, t.height);
        if (WritePng(out_dir / name, t.width, t.height, rgba)) {
          result.textures++;
          progress.textures_written++;
          any = true;
        }
      }
      if (any) result.files++;
    }
    progress.files_done++;
  }
  GE_TEX_LOG("GETEXTURES export: {} textures from {} files ({} in unsupported formats) -> {}",
             result.textures, result.files, result.unsupported, (folder / "Export").string());
  return result;
}

fs::path BuildPatchedGameFolder(const fs::path& game_root, const fs::path& folder) {
  std::error_code ec;
  const fs::path replace = folder / "Replace";
  if (game_root.empty() || !fs::is_directory(replace, ec)) return {};

  // Replacement PNGs grouped by the game file they belong to:
  // Replace/<relative game file>/<id>_<w>x<h>.png
  std::map<fs::path, std::vector<fs::path>> by_file;
  std::ostringstream signature;
  signature << "v1|" << game_root.string() << "\n";
  for (auto it = fs::recursive_directory_iterator(replace, fs::directory_options::skip_permission_denied, ec);
       !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
    if (!it->is_regular_file(ec) || LowerExt(it->path()) != ".png") continue;
    const fs::path rel_file = fs::relative(it->path().parent_path(), replace, ec);
    by_file[rel_file].push_back(it->path());
    signature << fs::relative(it->path(), replace, ec).generic_string() << "|" << it->file_size(ec) << "|"
              << static_cast<long long>(it->last_write_time(ec).time_since_epoch().count()) << "\n";
  }
  if (by_file.empty()) return {};

  const fs::path out = folder / ".patched";
  const fs::path sig_path = out / ".signature";
  {
    std::vector<uint8_t> old;
    const std::string sig = signature.str();
    if (ReadFile(sig_path, old) && std::string(old.begin(), old.end()) == sig) {
      GE_TEX_LOG("GETEXTURES using the patched game files from the last launch ({} game files)", by_file.size());
      return out;
    }
  }

  // Patch each game file that has replacements.
  std::map<fs::path, std::vector<uint8_t>> patched;
  int replaced = 0;
  for (const auto& [rel, pngs] : by_file) {
    std::vector<uint8_t> data;
    std::vector<TextureInfo> texs;
    if (!ReadFile(game_root / rel, data) || !ParseCaff(data, texs)) {
      GE_TEX_LOG("GETEXTURES skipped {}: no such game file with textures", rel.generic_string());
      continue;
    }
    bool changed = false;
    for (const fs::path& png : pngs) {
      uint32_t id = 0;
      if (!IdFromName(png.filename().string(), id)) {
        GE_TEX_LOG("GETEXTURES skipped {}: name must start with the texture number", png.filename().string());
        continue;
      }
      const auto t = std::find_if(texs.begin(), texs.end(), [&](const TextureInfo& x) { return x.id == id; });
      if (t == texs.end() || !IsSupported(*t)) {
        GE_TEX_LOG("GETEXTURES skipped {}: no texture {} in {}", png.filename().string(), id, rel.generic_string());
        continue;
      }
      uint32_t w = 0, h = 0;
      std::vector<uint8_t> rgba;
      if (!ReadPng(png, w, h, rgba)) {
        GE_TEX_LOG("GETEXTURES skipped {}: could not read it (needs a non-interlaced PNG)", png.string());
        continue;
      }
      if (w != t->width || h != t->height) rgba = Resize(rgba, w, h, t->width, t->height);
      if (Encode(data, *t, rgba)) {
        changed = true;
        replaced++;
      }
    }
    if (changed) patched[rel] = std::move(data);
  }
  if (patched.empty()) return {};

  // Mirror the game folder: real directories, links to every original file,
  // and the patched copies in place of the files that changed.
  fs::remove_all(out, ec);
  fs::create_directories(out, ec);
  for (auto it = fs::recursive_directory_iterator(game_root, fs::directory_options::skip_permission_denied, ec);
       !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
    const fs::path rel = fs::relative(it->path(), game_root, ec);
    const fs::path dst = out / rel;
    if (it->is_directory(ec)) {
      fs::create_directories(dst, ec);
      continue;
    }
    const auto p = patched.find(rel);
    std::error_code lec;
    if (p != patched.end()) {
      if (!WriteFile(dst, p->second)) lec = std::make_error_code(std::errc::io_error);
    } else {
      fs::create_symlink(it->path(), dst, lec);
    }
    if (lec) {
      GE_TEX_LOG("GETEXTURES could not set up {} ({}); using the original game files", dst.string(), lec.message());
      fs::remove_all(out, ec);
      return {};
    }
  }
  if (ec) {
    GE_TEX_LOG("GETEXTURES could not read the game folder ({}); using the original game files", ec.message());
    fs::remove_all(out, ec);
    return {};
  }
  const std::string sig = signature.str();
  WriteFile(sig_path, std::vector<uint8_t>(sig.begin(), sig.end()));
  GE_TEX_LOG("GETEXTURES replaced {} textures in {} game files", replaced, patched.size());
  return out;
}

}  // namespace ge::textures
