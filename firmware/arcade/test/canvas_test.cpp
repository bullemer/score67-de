#include "../display/Canvas.h"
#include <cassert>
int main() {
  const int sizes[][2] = {{64,32},{128,32},{64,64},{128,64},{128,128},{256,64},{192,192}};
  for (const auto& size : sizes) {
    arcade::Canvas c(size[0],size[1]);
    assert(c.width() == size[0] && c.height() == size[1]);
    c.clear(); c.pixel(size[0]-1,size[1]-1,0x1234);
    c.pixel(size[0],size[1],0xffff); c.swap();
    assert(c.front()[size[0]*size[1]-1] == 0x1234);
    c.clear(0xabcd); assert(c.front()[0] == 0); c.swap();
    assert(c.front()[0] == 0xabcd);
  }
}
