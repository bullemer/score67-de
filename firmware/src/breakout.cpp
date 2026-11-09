#include "breakout.h"
#include <algorithm>
#include <cmath>

void Breakout::serve() {
  x_ = width_ / 2.0f; y_ = height_ - 6.0f;
  vx_ = 0.65f; vy_ = -1.0f;
}
void Breakout::reset(int width, int height, uint32_t now) {
  width_ = width; height_ = height; paddle_ = (width - 11) / 2;
  lives_ = 3; remaining_ = 24; restartAt_ = 0; last_ = now;
  for (auto &row : bricks_) for (bool &brick : row) brick = true;
  serve();
}
void Breakout::update(uint32_t now, int position, bool connected) {
  paddle_ = std::max(1, std::min(width_ - 12, 1 + position * (width_ - 13) / 100));
  if (!connected || !connected_) { last_ = now; connected_ = connected; return; }
  if (restartAt_) {
    if (static_cast<int32_t>(now - restartAt_) >= 0) reset(width_, height_, now);
    return;
  }
  // Fixed steps bound collision movement and avoid a large jump after a stall.
  unsigned steps = std::min<uint32_t>((now - last_) / 30, 4);
  if (steps == 4) last_ = now; else last_ += steps * 30;
  while (steps--) {
    float oldY = y_; x_ += vx_; y_ += vy_;
    if (x_ < 1) { x_ = 1; vx_ = std::abs(vx_); }
    if (x_ > width_ - 2) { x_ = width_ - 2; vx_ = -std::abs(vx_); }
    if (y_ < 1) { y_ = 1; vy_ = std::abs(vy_); }
    int col = ((int(x_) - 1) * 8 + 7) / (width_ - 2), row = (int(y_) - 3) / 3;
    if (y_ >= 3 && row >= 0 && row < 3 && col >= 0 && col < 8 && bricks_[row][col]) {
      bricks_[row][col] = false; --remaining_; vy_ = -vy_;
      if (!remaining_) { restartAt_ = now + 3000; break; }
    }
    const int paddleY = height_ - 3;
    if (vy_ > 0 && oldY < paddleY && y_ >= paddleY && x_ >= paddle_ && x_ < paddle_ + 11) {
      y_ = paddleY - 1; vy_ = -1.0f;
      vx_ = (x_ - (paddle_ + 5)) * 0.19f;
      if (std::abs(vx_) < 0.25f) vx_ = vx_ < 0 ? -0.25f : 0.25f;
    }
    if (y_ >= height_ - 1) {
      if (--lives_ == 0) restartAt_ = now + 3000;
      else serve();
      break;
    }
  }
}
void Breakout::draw(Canvas &c) const {
  const uint32_t colors[] = {0xff4040, 0xffbf30, 0x40df80};
  for (int row = 0; row < 3; ++row) for (int col = 0; col < 8; ++col) {
    int start = 1 + col * (width_ - 2) / 8;
    int end = 1 + (col + 1) * (width_ - 2) / 8;
    if (bricks_[row][col]) for (int y = 0; y < 2; ++y) for (int x = start; x < end - 1; ++x)
      c.set(x, 3 + row * 3 + y, colors[row]);
  }
  for (int x = 0; x < 11; ++x) c.set(paddle_ + x, height_ - 3, 0xffffff);
  c.set(int(x_), int(y_), 0xffffff);
  for (int i = 0; i < lives_; ++i) c.set(1 + i * 2, 0, 0xff4040);
}
