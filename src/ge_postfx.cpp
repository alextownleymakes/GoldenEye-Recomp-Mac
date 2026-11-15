// ge - ReXGlue Recompiled Project
//
// Post-processing filter overlay implementation. See ge_postfx.h.
//
// The filter is built from standard alpha-blended full-screen primitives (the
// only blend mode ImGui exposes), so it covers tint / brightness / vignette /
// scanlines. Per-pixel curve ops (contrast / saturation / gamma) would need a
// dedicated shader pass and are intentionally out of scope here.

#include "ge_postfx.h"
#include "ge_minimap.h"

#include <rex/cvar.h>

#include <imgui.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

// --- Tunable cvars (category "PostFX"; persisted via the menu's Save) ---
REXCVAR_DEFINE_BOOL(postfx_enabled, false, "PostFX", "Enable the post-processing filter");
REXCVAR_DEFINE_DOUBLE(postfx_brightness, 0.0, "PostFX", "Brightness offset (-1 dark .. +1 bright)")
    .range(-1.0, 1.0);
REXCVAR_DEFINE_DOUBLE(postfx_tint_r, 1.0, "PostFX", "Tint colour red (0..1)").range(0.0, 1.0);
REXCVAR_DEFINE_DOUBLE(postfx_tint_g, 1.0, "PostFX", "Tint colour green (0..1)").range(0.0, 1.0);
REXCVAR_DEFINE_DOUBLE(postfx_tint_b, 1.0, "PostFX", "Tint colour blue (0..1)").range(0.0, 1.0);
REXCVAR_DEFINE_DOUBLE(postfx_tint, 0.0, "PostFX", "Tint strength (0..1)").range(0.0, 1.0);
REXCVAR_DEFINE_DOUBLE(postfx_vignette, 0.0, "PostFX", "Vignette strength (0..1)").range(0.0, 1.0);
REXCVAR_DEFINE_DOUBLE(postfx_scanlines, 0.0, "PostFX", "Scanline strength (0..1)").range(0.0, 1.0);
// Shader colour-grade params (applied by the GPU grade pass in the D3D12 swap).
REXCVAR_DEFINE_DOUBLE(postfx_contrast, 1.0, "PostFX", "Contrast (1=none)").range(0.0, 2.0);
REXCVAR_DEFINE_DOUBLE(postfx_saturation, 1.0, "PostFX", "Saturation (1=none)").range(0.0, 2.0);
REXCVAR_DEFINE_DOUBLE(postfx_vibrance, 0.0, "PostFX", "Vibrance (-1..1)").range(-1.0, 1.0);
REXCVAR_DEFINE_DOUBLE(postfx_temperature, 0.0, "PostFX", "Temperature, warm/cool (-1..1)")
    .range(-1.0, 1.0);
REXCVAR_DEFINE_DOUBLE(postfx_gamma, 1.0, "PostFX", "Gamma (1=none)").range(0.3, 3.0);

// Defined in ge_hooks.cpp: the current quicksave/quickload message, if any.
bool ge_toast_current(std::string* text, float* alpha);

namespace ge {

namespace {

struct Preset {
  const char* name;
  bool enabled;
  float brightness, contrast, saturation, vibrance, temperature, gamma;  // shader grade
  float r, g, b, tint;                                                   // shader tint
  float vignette, scanlines;                                            // overlay
};

// Index 0 must be the neutral "Off" default.
const Preset kPresets[] = {
    // name        en    bri    con   sat   vib   tmp   gam   r     g     b    tint  vig  scan
    {"Off", false, 0.f, 1.f, 1.f, 0.f, 0.f, 1.f, 1.f, 1.f, 1.f, 0.f, 0.f, 0.f},
    {"Cinematic", true, -0.04f, 1.15f, 1.05f, 0.15f, -0.10f, 1.0f, 1.0f, 0.95f, 0.85f, 0.12f, 0.40f,
     0.f},
    {"Sepia", true, -0.02f, 1.05f, 0.20f, 0.f, 0.25f, 1.0f, 1.0f, 0.82f, 0.55f, 0.50f, 0.30f, 0.f},
    {"Noir", true, -0.03f, 1.35f, 0.0f, 0.f, 0.f, 1.0f, 1.f, 1.f, 1.f, 0.f, 0.55f, 0.f},
    {"Cold", true, 0.f, 1.05f, 1.0f, 0.10f, -0.55f, 1.0f, 0.70f, 0.85f, 1.0f, 0.15f, 0.18f, 0.f},
    {"Warm", true, 0.02f, 1.05f, 1.05f, 0.15f, 0.55f, 1.0f, 1.0f, 0.85f, 0.60f, 0.12f, 0.18f, 0.f},
    {"Vibrant", true, 0.f, 1.10f, 1.20f, 0.50f, 0.f, 1.0f, 1.f, 1.f, 1.f, 0.f, 0.f, 0.f},
    {"Matrix", true, -0.03f, 1.10f, 0.85f, 0.20f, 0.f, 1.0f, 0.55f, 1.0f, 0.60f, 0.30f, 0.30f,
     0.25f},
    {"CRT", true, -0.02f, 1.05f, 1.10f, 0.10f, 0.f, 1.0f, 0.90f, 1.0f, 0.90f, 0.10f, 0.20f, 0.50f},
};
constexpr int kPresetCount = static_cast<int>(sizeof(kPresets) / sizeof(kPresets[0]));

void SetD(const char* name, float v) { rex::cvar::SetFlagByName(name, std::to_string(v)); }

}  // namespace

int PostFxPresetCount() { return kPresetCount; }

const char* PostFxPresetName(int index) {
  if (index < 0 || index >= kPresetCount) return "";
  return kPresets[index].name;
}

void ApplyPostFxPreset(int index) {
  if (index < 0 || index >= kPresetCount) return;
  const Preset& p = kPresets[index];
  rex::cvar::SetFlagByName("postfx_enabled", p.enabled ? "true" : "false");
  SetD("postfx_brightness", p.brightness);
  SetD("postfx_contrast", p.contrast);
  SetD("postfx_saturation", p.saturation);
  SetD("postfx_vibrance", p.vibrance);
  SetD("postfx_temperature", p.temperature);
  SetD("postfx_gamma", p.gamma);
  SetD("postfx_tint_r", p.r);
  SetD("postfx_tint_g", p.g);
  SetD("postfx_tint_b", p.b);
  SetD("postfx_tint", p.tint);
  SetD("postfx_vignette", p.vignette);
  SetD("postfx_scanlines", p.scanlines);
}

void ResetPostFx() { ApplyPostFxPreset(0); }


// --- Minimap (mod) -----------------------------------------------------------
// Circular, Bond at the centre facing up; the map turns and slides around him.
// Data comes from ge_minimap_get (built on the game thread in ge_hooks.cpp).
namespace {

// Clip a convex polygon (screen space) to a convex polygon `clip` (CCW or
// CW, consistently) -- Sutherland-Hodgman.
std::vector<ImVec2> ClipConvex(const std::vector<ImVec2>& poly, const std::vector<ImVec2>& clip) {
  std::vector<ImVec2> out = poly;
  // Orientation of the clip polygon.
  float area = 0.f;
  for (size_t i = 0; i < clip.size(); ++i) {
    const ImVec2& a = clip[i];
    const ImVec2& b = clip[(i + 1) % clip.size()];
    area += a.x * b.y - b.x * a.y;
  }
  const float sgn = area >= 0.f ? 1.f : -1.f;
  for (size_t e = 0; e < clip.size() && !out.empty(); ++e) {
    const ImVec2 a = clip[e], b = clip[(e + 1) % clip.size()];
    auto inside = [&](const ImVec2& p) {
      return sgn * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) >= 0.f;
    };
    std::vector<ImVec2> in = std::move(out);
    out.clear();
    for (size_t i = 0; i < in.size(); ++i) {
      const ImVec2 p = in[i], q = in[(i + 1) % in.size()];
      const bool pin = inside(p), qin = inside(q);
      if (pin) out.push_back(p);
      if (pin != qin) {
        const float d1 = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
        const float d2 = (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x);
        const float t = d1 / (d1 - d2);
        out.push_back(ImVec2(p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t));
      }
    }
  }
  return out;
}

// Clip segment p-q to the circle (c, r). False if it misses.
bool ClipSegment(ImVec2 c, float r, ImVec2* p, ImVec2* q) {
  const float dx = q->x - p->x, dy = q->y - p->y;
  const float fx = p->x - c.x, fy = p->y - c.y;
  const float a = dx * dx + dy * dy;
  if (a < 1e-6f) return fx * fx + fy * fy <= r * r;
  const float b = 2.f * (fx * dx + fy * dy);
  const float cc = fx * fx + fy * fy - r * r;
  const float disc = b * b - 4.f * a * cc;
  if (disc < 0.f) return false;
  const float sq = std::sqrt(disc);
  float t0 = (-b - sq) / (2.f * a), t1 = (-b + sq) / (2.f * a);
  if (t1 < 0.f || t0 > 1.f) return false;
  t0 = std::max(t0, 0.f);
  t1 = std::min(t1, 1.f);
  const ImVec2 p0 = *p;
  *p = ImVec2(p0.x + dx * t0, p0.y + dy * t0);
  *q = ImVec2(p0.x + dx * t1, p0.y + dy * t1);
  return true;
}

void DrawMinimap(const ImGuiIO& io) {
  GeMinimapView v;
  if (!::ge_minimap_get(&v)) return;
  const float W = io.DisplaySize.x, H = io.DisplaySize.y;
  if (W <= 0.f || H <= 0.f) return;
  // The game picture is 16:9, centred (bars on the other axis).
  const float vw = std::min(W, H * 16.f / 9.f), vh = vw * 9.f / 16.f;
  const float vx1 = (W + vw) * 0.5f, vy1 = (H + vh) * 0.5f;
  const float R = vh * 0.13f;
  const ImVec2 c(vx1 - R - vh * 0.035f, vy1 - R - vh * 0.05f);

  const float th = v.theta * 0.017453292f;
  const float fx = -std::sin(th), fz = std::cos(th);  // forward
  const float rx = -std::cos(th), rz = -std::sin(th);  // right
  const float k = R / std::max(v.range, 1.f);
  auto to_screen = [&](float x, float z) {
    const float dx = x - v.bx, dz = z - v.bz;
    return ImVec2(c.x + (dx * rx + dz * rz) * k, c.y - (dx * fx + dz * fz) * k);
  };

  ImDrawList* dl = ImGui::GetForegroundDrawList();
  dl->AddCircleFilled(c, R, IM_COL32(8, 10, 14, 150), 64);

  std::vector<ImVec2> circle;
  for (int i = 0; i < 40; ++i) {
    const float a = static_cast<float>(i) * 6.2831853f / 40.f;
    circle.push_back(ImVec2(c.x + std::cos(a) * R, c.y + std::sin(a) * R));
  }

  // Floors.
  for (size_t i = 0; i < v.floors.size();) {
    const int n = static_cast<int>(v.floors[i++]);
    if (n < 3 || i + 2 * n > v.floors.size()) break;
    std::vector<ImVec2> poly;
    for (int j = 0; j < n; ++j) poly.push_back(to_screen(v.floors[i + 2 * j], v.floors[i + 2 * j + 1]));
    i += 2 * n;
    std::vector<ImVec2> clipped = ClipConvex(poly, circle);
    if (clipped.size() >= 3) {
      dl->AddConvexPolyFilled(clipped.data(), static_cast<int>(clipped.size()),
                              IM_COL32(70, 78, 88, 150));
    }
  }
  // Walls.
  for (size_t i = 0; i + 3 < v.walls.size(); i += 4) {
    ImVec2 p = to_screen(v.walls[i], v.walls[i + 1]), q = to_screen(v.walls[i + 2], v.walls[i + 3]);
    if (ClipSegment(c, R, &p, &q)) dl->AddLine(p, q, IM_COL32(200, 206, 214, 220), 1.5f);
  }

  // Markers (objectives stick to the rim when off the map).
  const float s = std::max(3.f, R * 0.035f);
  for (const GeMinimapMarker& m : v.markers) {
    ImVec2 p = to_screen(m.x, m.z);
    const float dx = p.x - c.x, dy = p.y - c.y, d = std::sqrt(dx * dx + dy * dy);
    if (d > R - s) {
      if (m.kind != kGeMapObjective) continue;
      p = ImVec2(c.x + dx / d * (R - s), c.y + dy / d * (R - s));
    }
    switch (m.kind) {
      case kGeMapEnemy:
        dl->AddCircleFilled(p, s, IM_COL32(230, 40, 40, 255), 12);
        break;
      case kGeMapItem:
        dl->AddLine(ImVec2(p.x - s, p.y - s), ImVec2(p.x + s, p.y + s), IM_COL32(190, 190, 190, 255), 2.f);
        dl->AddLine(ImVec2(p.x - s, p.y + s), ImVec2(p.x + s, p.y - s), IM_COL32(190, 190, 190, 255), 2.f);
        break;
      case kGeMapAmmo:
        dl->AddRect(ImVec2(p.x - s, p.y - s), ImVec2(p.x + s, p.y + s), IM_COL32(240, 200, 40, 255), 0.f, 0, 2.f);
        break;
      default: {
        const ImVec2 pts[4] = {ImVec2(p.x, p.y - s * 1.4f), ImVec2(p.x + s * 1.4f, p.y),
                               ImVec2(p.x, p.y + s * 1.4f), ImVec2(p.x - s * 1.4f, p.y)};
        dl->AddConvexPolyFilled(pts, 4, IM_COL32(60, 220, 90, 255));
        break;
      }
    }
  }

  // Bond: an arrow at the centre, pointing the way he faces (always up).
  const float b = std::max(5.f, R * 0.06f);
  dl->AddTriangleFilled(ImVec2(c.x, c.y - b * 1.3f), ImVec2(c.x + b * 0.8f, c.y + b * 0.8f),
                        ImVec2(c.x - b * 0.8f, c.y + b * 0.8f), IM_COL32(255, 255, 255, 255));
  dl->AddCircle(c, R, IM_COL32(200, 206, 214, 200), 64, 2.f);
}

}  // namespace

PostFxOverlay::PostFxOverlay(rex::ui::ImGuiDrawer* drawer) : rex::ui::ImGuiDialog(drawer) {}
PostFxOverlay::~PostFxOverlay() = default;

void PostFxOverlay::OnDraw(ImGuiIO& io) {
  // Minimap (bottom right), independent of post-FX.
  DrawMinimap(io);

  // Quicksave / quickload message (top centre), independent of post-FX.
  {
    std::string text;
    float alpha = 0.0f;
    if (::ge_toast_current(&text, &alpha) && io.DisplaySize.x > 0.0f) {
      ImDrawList* fg = ImGui::GetForegroundDrawList();
      const ImVec2 ts = ImGui::CalcTextSize(text.c_str());
      const float pad = 12.0f;
      const ImVec2 p0((io.DisplaySize.x - ts.x) * 0.5f - pad, 24.0f);
      const ImVec2 p1(p0.x + ts.x + pad * 2.0f, p0.y + ts.y + pad * 1.4f);
      fg->AddRectFilled(p0, p1, IM_COL32(10, 12, 16, int(200 * alpha)), 6.0f);
      fg->AddText(ImVec2(p0.x + pad, p0.y + pad * 0.7f), IM_COL32(235, 225, 190, int(255 * alpha)),
                  text.c_str());
    }
  }

  if (!REXCVAR_GET(postfx_enabled)) return;

  const float W = io.DisplaySize.x, H = io.DisplaySize.y;
  if (W <= 0.0f || H <= 0.0f) return;

  ImGui::SetNextWindowPos(ImVec2(0, 0));
  ImGui::SetNextWindowSize(io.DisplaySize);
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
  ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                           ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                           ImGuiWindowFlags_NoScrollWithMouse | ImGuiWindowFlags_NoBackground |
                           ImGuiWindowFlags_NoInputs | ImGuiWindowFlags_NoNav |
                           ImGuiWindowFlags_NoBringToFrontOnFocus |
                           ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoSavedSettings;
  if (!ImGui::Begin("##ge_postfx", nullptr, flags)) {
    ImGui::End();
    ImGui::PopStyleVar();
    return;
  }
  ImDrawList* dl = ImGui::GetWindowDrawList();
  const ImVec2 p0(0, 0), p1(W, H);

  auto a8 = [](float f) {
    if (f < 0.0f) f = 0.0f;
    if (f > 1.0f) f = 1.0f;
    return static_cast<int>(f * 255.0f + 0.5f);
  };

  // NOTE: brightness / contrast / saturation / vibrance / temperature / gamma /
  // tint are all done per-pixel by the GPU grade shader (ge_grade.cs.hlsl) in
  // the D3D12 swap. This overlay only adds the spatial effects ImGui can do:
  // vignette and scanlines.

  // Vignette: four edge gradients (transparent inner -> dark edge) stack at the
  // corners to approximate a radial darkening.
  const float vig = static_cast<float>(REXCVAR_GET(postfx_vignette));
  if (vig > 0.001f) {
    const ImU32 dark = IM_COL32(0, 0, 0, a8(vig));
    const ImU32 clear = IM_COL32(0, 0, 0, 0);
    const float ext = 0.42f;  // fraction of the screen each edge band covers
    const float bw = W * ext, bh = H * ext;
    // top (dark at top edge -> clear downward)
    dl->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(W, bh), dark, dark, clear, clear);
    // bottom
    dl->AddRectFilledMultiColor(ImVec2(0, H - bh), ImVec2(W, H), clear, clear, dark, dark);
    // left
    dl->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(bw, H), dark, clear, clear, dark);
    // right
    dl->AddRectFilledMultiColor(ImVec2(W - bw, 0), ImVec2(W, H), clear, dark, dark, clear);
  }

  // Scanlines (CRT): thin dark horizontal lines every few pixels.
  const float scan = static_cast<float>(REXCVAR_GET(postfx_scanlines));
  if (scan > 0.001f) {
    const ImU32 line = IM_COL32(0, 0, 0, a8(scan * 0.7f));
    for (float y = 0.0f; y < H; y += 3.0f) {
      dl->AddRectFilled(ImVec2(0, y), ImVec2(W, y + 1.0f), line);
    }
  }

  ImGui::End();
  ImGui::PopStyleVar();
}

}  // namespace ge
