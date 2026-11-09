#include "render.h"
#include <cassert>
#include <cstring>
struct Square : Canvas {
 int count = 0, outside = 0, w;
 explicit Square(int width = 64) : w(width) {}
 int width() const override { return w; }
 int height() const override { return 64; }
 void set(int x, int y, uint32_t) override { if (x < 0 || x >= w || y < 0 || y >= 64) ++outside; else ++count; }
};
int main() {
 Feed f; f.valid = true; strcpy(f.mode, "game"); strcpy(f.home.shortName, "HOM"); strcpy(f.guest.shortName, "AWY");
 f.home.score = 123; f.guest.score = 99; f.clock.visible = true; f.clock.ms = 125000; strcpy(f.period, "Q3");
 Square s; renderFeed(s, f, 0); assert(s.count > 100); assert(s.outside == 0);
 Square wide(128); renderFeed(wide, f, 0); assert(wide.count > 100); assert(wide.outside == 0);
 strcpy(f.msg.kind, "polonia"); f.msg.present = true; f.msg.ms = 5000; Square logo; renderFeed(logo, f, 0); assert(logo.count > 100); assert(logo.outside == 0);
 strcpy(f.msg.kind, "bram"); Square bram; renderFeed(bram, f, 0); assert(bram.count > 100); assert(bram.outside == 0);
 strcpy(f.mode, "pairing"); strcpy(f.code, "123456"); Square pairing; renderFeed(pairing, f, 0); assert(pairing.count > 0); assert(pairing.outside == 0);
 Square widePairing(128); renderFeed(widePairing, f, 0); assert(widePairing.count > 0); assert(widePairing.outside == 0);
}
