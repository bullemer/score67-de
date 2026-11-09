#pragma once
#include <stdint.h>
#include "render.h"

class Breakout {
public:
  void reset(int width, int height, uint32_t now);
  void update(uint32_t now, int position, bool connected);
  void draw(Canvas &canvas) const;
  int lives() const { return lives_; }
  int remaining() const { return remaining_; }
private:
  void serve();
  int width_ = 64, height_ = 32, paddle_ = 0, lives_ = 3, remaining_ = 0;
  float x_ = 0, y_ = 0, vx_ = 0, vy_ = 0;
  bool bricks_[3][8] = {};
  uint32_t last_ = 0, restartAt_ = 0;
  bool connected_ = false;
};
