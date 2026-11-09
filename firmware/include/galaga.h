#pragma once
#include <stdint.h>
#include "render.h"
class Galaga {
 public:
  void reset(int width, int height, uint32_t now);
  void update(uint32_t now, int position, bool fire);
  void draw(Canvas &canvas) const;
  int lives() const { return lives_; }
  int remaining() const { return remaining_; }
 private:
  int width_=64, height_=32, ship_=32;
  struct Shot { int x=0, y=-1; } shots_[5];
  int enemyX_=0, direction_=1, lives_=3, remaining_=24;
  int bombX_=0, bombY_=-1, nextEnemy_=0;
  int diver_=-1, diveX_=0, diveY_=0;
  bool enemies_[24] = {};
  uint32_t last_=0, lastMove_=0, lastFire_=0, lastBomb_=0, lastDive_=0, restartAt_=0;
};
