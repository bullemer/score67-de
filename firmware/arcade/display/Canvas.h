#pragma once
#include <cstdint>
#include <cstddef>
#include <vector>

namespace arcade {
class Canvas {
public:
    explicit Canvas(int width = 64, int height = 64);
    int width() const { return width_; }
    int height() const { return height_; }
    enum class Font { Small3x5, Normal5x7 };
    static constexpr uint16_t rgb(uint8_t r, uint8_t g, uint8_t b) {
        return ((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3);
    }
    void clear(uint16_t color = 0);
    void pixel(int x, int y, uint16_t color);
    void line(int x0, int y0, int x1, int y1, uint16_t color);
    void rect(int x, int y, int w, int h, uint16_t color);
    void fillRect(int x, int y, int w, int h, uint16_t color);
    void blit(int x, int y, int w, int h, const uint16_t* pixels, uint16_t transparent);
    void text(int x, int y, const char* value, uint16_t color, Font font = Font::Normal5x7, int scale = 1);
    static int textWidth(const char* value, Font font = Font::Normal5x7, int scale = 1);
    // Draw into the back buffer; swap publishes it and makes the old front the new back.
    void swap();
    const uint16_t* front() const { return buffers_[front_].data(); }
private:
    int width_, height_;
    std::vector<uint16_t> buffers_[2];
    unsigned front_ = 0;
    uint16_t* back() { return buffers_[1 - front_].data(); }
};

} // namespace arcade
