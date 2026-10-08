// Host-side check (platform native): renders a feed JSON file like the panel
// would and prints the pixels as JSON, for tools/compare.mjs to diff against
// the browser preview. Usage: host_render <feed.json> <sinceMs>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "feed.h"
#include "render.h"
#include "tables.h"

struct Buffer : Canvas {
  uint32_t px[LED_W * LED_H];
  bool lit[LED_W * LED_H];
  Buffer() { memset(lit, 0, sizeof lit); }
  void set(int x, int y, uint32_t rgb) override {
    if (x < 0 || y < 0 || x >= LED_W || y >= LED_H) return;
    px[y * LED_W + x] = rgb;
    lit[y * LED_W + x] = true;
  }
};

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: host_render feed.json sinceMs\n"); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  static char json[16384];
  size_t n = fread(json, 1, sizeof json - 1, f);
  json[n] = 0;
  fclose(f);
  Feed feed;
  if (!parseFeed(json, feed)) { fprintf(stderr, "bad json\n"); return 1; }
  Buffer b;
  renderFeed(b, feed, atol(argv[2]));
  printf("[");
  for (int i = 0; i < LED_W * LED_H; i++) {
    if (i) printf(",");
    if (b.lit[i]) printf("\"#%06x\"", b.px[i]); else printf("null");
  }
  printf("]\n");
  return 0;
}
