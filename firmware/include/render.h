#pragma once
// Draws the panel image for a feed: a port of render() in
// backend/score67/static/led.mjs, pixel for pixel (checked by tools/compare.mjs).
#include <stdint.h>
#include "feed.h"

struct Canvas {
  virtual void set(int x, int y, uint32_t rgb) = 0;   // rgb = 0xRRGGBB
  virtual ~Canvas() {}
};

// sinceMs: local milliseconds since the feed message arrived (clock, scrolling, blinking).
void renderFeed(Canvas &canvas, const Feed &feed, long sinceMs);

// Exposed for tests: words into lines of at most `max` characters (8 on 64 px);
// returns the number of lines, or -1 when a word is longer than a line.
int wrapText(const char *text, int max, char lines[][12], int maxLines);
