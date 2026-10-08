#include "render.h"

#include <math.h>
#include <string.h>
#include <stdio.h>
#include "tables.h"

namespace {
constexpr int W = LED_W, H = LED_H;
constexpr int SCROLL_PX_PER_S = 24, BIG_CHARS = (W + 2) / 8;

int jsRound(double v) { return (int)floor(v + 0.5); }

// Characters as the 3x5 font knows them: upper case, umlauts without dots,
// anything else a space. Reads one UTF-8 code point; returns its length.
int glyphChar(const char *s, char &out) {
  unsigned char c = s[0];
  if (c < 0x80) {
    out = (c >= 'a' && c <= 'z') ? c - 32 : (c >= 32 && c <= 90 ? c : ' ');
    return 1;
  }
  int len = (c >= 0xF0) ? 4 : (c >= 0xE0) ? 3 : 2;
  unsigned char d = s[1];
  out = ' ';
  if (c == 0xC3) {
    if (d == 0x84 || d == 0xA4) out = 'A';
    else if (d == 0x96 || d == 0xB6) out = 'O';
    else if (d == 0x9C || d == 0xBC) out = 'U';
  }
  return len;
}

int codePoints(const char *s) {
  int n = 0;
  for (; *s; s++) if (((unsigned char)*s & 0xC0) != 0x80) n++;
  return n;
}

int textWidth(const char *s) { int n = codePoints(s); return n ? n * 4 - 1 : 0; }

uint32_t readable(uint32_t rgb) {
  int r = rgb >> 16, g = (rgb >> 8) & 255, b = rgb & 255;
  int m = r > g ? r : g;
  if (b > m) m = b;
  return m < 90 ? 0xffffff : rgb;
}

void glyph(Canvas &c, const uint8_t *rows, int count, int width, int x, int y, uint32_t color, int scale = 1) {
  for (int row = 0; row < count; row++)
    for (int col = 0; col < width; col++)
      if (rows[row] & (1 << (width - 1 - col)))
        for (int dy = 0; dy < scale; dy++)
          for (int dx = 0; dx < scale; dx++) c.set(x + col * scale + dx, y + row * scale + dy, color);
}

const uint8_t *small(char ch) { return FONT_SMALL[(ch >= 32 && ch <= 90) ? ch - 32 : 0]; }

// 3x5 text; returns the width drawn.
int text(Canvas &c, const char *s, int x, int y, uint32_t color) {
  int cx = x;
  while (*s) {
    char ch;
    s += glyphChar(s, ch);
    glyph(c, small(ch), 5, 3, cx, y, color);
    cx += 4;
  }
  return cx - x - 1 > 0 ? cx - x - 1 : 0;
}

uint32_t hue(double h) {
  auto f = [&](int n) {
    double k = fmod(n + h / 60.0, 6.0);
    double m = k < 4 - k ? k : 4 - k;
    if (m > 1) m = 1;
    if (m < 0) m = 0;
    return (uint32_t)jsRound(255 * (1 - m));
  };
  return (f(5) << 16) | (f(3) << 8) | f(1);
}

// 3x5 text doubled (8 px per character); rainbow colours by index when `rainbowMs` >= 0.
void big(Canvas &c, const char *s, int x, int y, uint32_t color, double rainbowMs = -1) {
  int i = 0;
  while (*s) {
    char ch;
    s += glyphChar(s, ch);
    uint32_t col = rainbowMs >= 0 ? hue(fmod(rainbowMs / 8 + i * 45, 360.0)) : color;
    glyph(c, small(ch), 5, 3, x + i * 8, y, col, 2);
    i++;
  }
}

void icon(Canvas &c, const char *name, int x, int y, int scale = 1) {
  for (int i = 0; i < ICON_COUNT; i++) {
    if (strcmp(ICON_NAMES[i], name)) continue;
    for (int ry = 0; ry < 12; ry++)
      for (int rx = 0; rx < 12; rx++) {
        uint8_t p = ICON_PIXELS[i][ry][rx];
        if (!p) continue;
        for (int dy = 0; dy < scale; dy++)
          for (int dx = 0; dx < scale; dx++) c.set(x + rx * scale + dx, y + ry * scale + dy, ICON_PALETTE[p]);
      }
    return;
  }
}

void clockText(long ms, bool down, char *out) {
  if (down && ms < 60000) { snprintf(out, 12, "%ld.%ld", ms / 1000, (ms % 1000) / 100); return; }
  long seconds = ms / 1000;
  snprintf(out, 12, "%02ld:%02ld", seconds / 60, seconds % 60);
}

void drawClock(Canvas &c, const char *value, int y, uint32_t color) {
  int width = -1;
  for (const char *p = value; *p; p++) width += (*p >= '0' && *p <= '9') ? 6 : 2;
  int x = jsRound((W - width) / 2.0);
  for (const char *p = value; *p; p++) {
    if (*p >= '0' && *p <= '9') { glyph(c, FONT_CLOCK[*p - '0'], 7, 5, x, y, color); x += 6; }
    else if (*p == ':') { c.set(x, y + 2, color); c.set(x, y + 4, color); x += 2; }
    else { c.set(x, y + 6, color); x += 2; }
  }
}

void drawScore(Canvas &c, int value, int rightEdge, int leftStart, bool narrow) {
  char digits[12];
  snprintf(digits, sizeof digits, "%d", value);
  int n = strlen(digits), w = narrow ? 8 : 10, gap = narrow ? 1 : 2;
  int width = n * w + (n - 1) * gap;
  int x = rightEdge >= 0 ? rightEdge - width + 1 : leftStart;
  for (const char *p = digits; *p; p++) {
    int d = *p - '0';
    glyph(c, narrow ? FONT_NARROW[d] : FONT_CLOCK[d], 7, narrow ? 4 : 5, x, 8, COLOR_SCORE, 2);
    x += w + gap;
  }
}

void chartHeader(Canvas &c, const FeedMessage &m) {
  text(c, m.home.shortName, 1, 1, readable(m.home.color));
  text(c, m.guest.shortName, W - 1 - textWidth(m.guest.shortName), 1, readable(m.guest.color));
}

void drawPeriods(Canvas &c, const FeedMessage &m) {
  chartHeader(c, m);
  int count = m.periodCount < 8 ? m.periodCount : 8, first = m.periodCount - count;
  if (!count) return;
  const int top = 8, bottom = 24, slot = W / count;
  int max = 1;
  for (int i = first; i < m.periodCount; i++)
    for (int t = 0; t < 2; t++) if (m.periods[i][t] > max) max = m.periods[i][t];
  uint32_t home = readable(m.home.color), guest = readable(m.guest.color);
  int width = (slot - 2) / 2;
  if (width > 3) width = 3;
  if (width < 1) width = 1;
  for (int i = 0; i < count; i++) {
    int x = i * slot + (slot - 2 * width - 1) / 2;
    const int *pair = m.periods[first + i];
    for (int t = 0; t < 2; t++) {
      int value = pair[t], bx = t ? x + width + 1 : x;
      int height = value ? jsRound((bottom - top) * (double)value / max) : 0;
      if (value && height < 1) height = 1;
      for (int y = bottom - height; y < bottom; y++)
        for (int dx = 0; dx < width; dx++) c.set(bx + dx, y, t ? guest : home);
    }
    char label[4];
    snprintf(label, sizeof label, "%d", i + 1);
    text(c, label, i * slot + (slot - textWidth(label)) / 2, 26, COLOR_DIM);
  }
}

void drawLead(Canvas &c, const FeedMessage &m) {
  chartHeader(c, m);
  const int axis = 19, reach = 11;
  int max = 1;
  for (int i = 0; i < m.leadCount; i++) { int a = m.lead[i] < 0 ? -m.lead[i] : m.lead[i]; if (a > max) max = a; }
  uint32_t home = readable(m.home.color), guest = readable(m.guest.color);
  for (int x = 0; x < W; x++) c.set(x, axis, COLOR_DIM);
  for (int i = 0; i < m.leadCount; i++) {
    int value = m.lead[i], a = value < 0 ? -value : value;
    int x = 1 + i, height = jsRound(reach * (double)a / max);
    for (int d = 1; d <= height; d++) c.set(x, value > 0 ? axis - d : axis + d, value > 0 ? home : guest);
  }
}

void renderMessage(Canvas &c, const FeedMessage &m, long sinceMs) {
  if (!strcmp(m.kind, "periods")) { drawPeriods(c, m); return; }
  if (!strcmp(m.kind, "lead")) { drawLead(c, m); return; }
  if (!strcmp(m.effect, "blink") && (sinceMs / 500) % 2 == 1) return;
  bool rainbow = !strcmp(m.effect, "rainbow");
  double rainbowMs = rainbow ? (double)sinceMs : -1;
  if (!m.text[0]) { icon(c, m.icon, 20, 4, 2); return; }
  char lines[8][12];
  int count = wrapText(m.text, BIG_CHARS, lines, 8);
  auto scroll = [&](int y) {
    int width = codePoints(m.text) * 8 - 2, period = width + W;
    big(c, m.text, W - (int)((sinceMs * SCROLL_PX_PER_S / 1000) % period), y, m.color, rainbowMs);
  };
  if (m.icon[0]) {
    icon(c, m.icon, 26, 1);
    if (count == 1) big(c, lines[0], jsRound((W - (codePoints(lines[0]) * 8 - 2)) / 2.0), 19, m.color, rainbowMs);
    else scroll(19);
    return;
  }
  if (count >= 1 && count <= 2) {
    int top = count == 1 ? 11 : 4;
    for (int i = 0; i < count; i++)
      big(c, lines[i], jsRound((W - (codePoints(lines[i]) * 8 - 2)) / 2.0), top + i * 14, m.color, rainbowMs);
  } else scroll(11);
}
}  // namespace

int wrapText(const char *s, int max, char lines[][12], int maxLines) {
  int count = 0;
  while (*s) {
    while (*s == ' ') s++;
    if (!*s) break;
    const char *end = s;
    while (*end && *end != ' ') end++;
    int len = 0;
    for (const char *p = s; p < end; p++) if (((unsigned char)*p & 0xC0) != 0x80) len++;
    if (len > max) return -1;
    if (count && codePoints(lines[count - 1]) + 1 + len <= max) {
      strncat(lines[count - 1], " ", 11 - strlen(lines[count - 1]));
      strncat(lines[count - 1], s, end - s);
    } else {
      if (count >= maxLines) return -1;
      int bytes = end - s < 11 ? end - s : 11;
      memcpy(lines[count], s, bytes);
      lines[count][bytes] = 0;
      count++;
    }
    s = end;
  }
  return count;
}

void renderFeed(Canvas &c, const Feed &feed, long sinceMs) {
  if (!feed.valid) return;
  bool game = !strcmp(feed.mode, "game");
  if (game && feed.msg.present && sinceMs < feed.msg.ms) { renderMessage(c, feed.msg, sinceMs); return; }
  if (!game) {
    // Pairing (unclaimed) or idle (no game): the connection code large enough
    // to read across the hall, with what it is above it.
    const char *label = !strcmp(feed.mode, "pairing") ? "CODE" : "SCORE67";
    if (!feed.code[0]) { text(c, label, jsRound((W - textWidth(label)) / 2.0), 13, COLOR_DIM); return; }
    text(c, label, jsRound((W - textWidth(label)) / 2.0), 2, COLOR_DIM);
    char shown[10];
    if (strlen(feed.code) == 6) snprintf(shown, sizeof shown, "%.3s %s", feed.code, feed.code + 3);
    else snprintf(shown, sizeof shown, "%s", feed.code);
    big(c, shown, jsRound((W - (codePoints(shown) * 8 - 2)) / 2.0), 13, COLOR_TEXT);
    return;
  }
  const FeedTeam &home = feed.home, &guest = feed.guest;
  int hw = text(c, home.shortName, 1, 1, readable(home.color));
  int gx = W - 1 - textWidth(guest.shortName);
  text(c, guest.shortName, gx, 1, readable(guest.color));
  static const uint8_t bar[3] = {1, 1, 1};
  for (int i = 0; i < home.redCards && i < 3; i++) glyph(c, bar, 3, 1, 2 + hw + i * 2, 2, COLOR_RED);
  for (int i = 0; i < guest.redCards && i < 3; i++) glyph(c, bar, 3, 1, gx - 3 - i * 2, 2, COLOR_RED);
  if (!strcmp(feed.possession, "home")) text(c, "<", 30, 1, COLOR_TEXT);
  if (!strcmp(feed.possession, "away")) text(c, ">", 31, 1, COLOR_TEXT);
  bool narrow = home.score >= 100 || guest.score >= 100;
  drawScore(c, home.score, narrow ? 29 : 28, -1, narrow);
  drawScore(c, guest.score, -1, narrow ? 34 : 35, narrow);
  for (int y = 11; y <= 18; y += (y == 12 ? 5 : 1)) { c.set(31, y, COLOR_SCORE); c.set(32, y, COLOR_SCORE); }
  bool finished = !strcmp(feed.phase, "finished");
  if (feed.clock.visible) {
    long ms = feed.clock.ms;
    if (feed.clock.running) ms = feed.clock.down ? (ms - sinceMs > 0 ? ms - sinceMs : 0) : ms + sinceMs;
    char value[12];
    clockText(ms, feed.clock.down, value);
    drawClock(c, value, 24, feed.clock.running ? COLOR_RUNNING : COLOR_STOPPED);
  } else if (finished) {
    const char *word = !strcmp(feed.lang, "de") ? "ENDE" : "FINAL";
    text(c, word, jsRound((W - textWidth(word)) / 2.0), 25, COLOR_STOPPED);
  }
  if (feed.period[0] && !finished) text(c, feed.period, 1, 26, COLOR_DIM);
  if (home.fouls >= 0 && guest.fouls >= 0) {
    char fouls[12];
    snprintf(fouls, sizeof fouls, "%d-%d", home.fouls, guest.fouls);
    text(c, fouls, W - 1 - textWidth(fouls), 26, COLOR_DIM);
  }
  if (feed.identify && (sinceMs / 400) % 2 == 0) {
    for (int x = 0; x < W; x++) { c.set(x, 0, COLOR_TEXT); c.set(x, H - 1, COLOR_TEXT); }
    for (int y = 0; y < H; y++) { c.set(0, y, COLOR_TEXT); c.set(W - 1, y, COLOR_TEXT); }
  }
}
