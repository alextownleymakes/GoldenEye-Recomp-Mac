// ge - minimap (mod). Built on the game thread from the level's floor map,
// objects and objectives (ge_hooks.cpp); drawn by the overlay (ge_postfx.cpp).

#pragma once

#include <vector>

enum GeMinimapKind { kGeMapEnemy = 0, kGeMapItem = 1, kGeMapAmmo = 2, kGeMapObjective = 3 };

struct GeMinimapMarker {
  float x, z;
  int kind;
};

struct GeMinimapView {
  float bx = 0.f, bz = 0.f;  // Bond, world x/z
  float theta = 0.f;         // Bond's facing, degrees (vv_theta)
  float range = 1200.f;      // world units from centre to rim
  std::vector<float> floors;  // per polygon: n, then n * (x, z)
  std::vector<float> walls;   // per wall: x0, z0, x1, z1
  std::vector<GeMinimapMarker> markers;
};

// A copy of the latest minimap, or false when there's nothing to show (not in
// a level, paused, turned off).
bool ge_minimap_get(GeMinimapView* out);
