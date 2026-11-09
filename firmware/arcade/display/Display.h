#pragma once
#include "Canvas.h"

namespace arcade {
// Hardware implementations present the published canvas; game code never sees a driver.
class Display {
public:
  virtual ~Display() = default;
  virtual bool begin() = 0;
  virtual void present(const Canvas& canvas) = 0;
};
} // namespace arcade
