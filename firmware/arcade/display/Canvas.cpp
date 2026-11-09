#include "Canvas.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>

namespace arcade {
namespace {
constexpr uint8_t font5[] = {
#include "Font5x7.inc"
};
// Columns, least-significant bit at the top. Compact uppercase font.
constexpr uint8_t letters[][3] = {
 {30,5,30},{31,21,10},{14,17,17},{31,17,14},{31,21,17},{31,5,1},
 {14,17,29},{31,4,31},{17,31,17},{8,16,15},{31,4,27},{31,16,16},
 {31,2,31},{31,1,30},{14,17,14},{31,5,2},{14,25,30},{31,13,22},
 {18,21,9},{1,31,1},{15,16,15},{7,24,7},{31,8,31},{27,4,27},
 {3,28,3},{25,21,19}
};
constexpr uint8_t digits[][3] = {{31,17,31},{18,31,16},{29,21,23},{17,21,31},{7,4,31},{23,21,29},{31,21,29},{1,1,31},{31,21,31},{23,21,31}};
uint8_t small(char c, int col) {
 if (c >= 'a' && c <= 'z') c -= 32;
 if (c >= 'A' && c <= 'Z') return letters[c-'A'][col];
 if (c >= '0' && c <= '9') return digits[c-'0'][col];
 if (c == ':') return col == 1 ? 10 : 0;
 if (c == '-') return col == 1 ? 4 : 0;
 if (c == '.') return col == 1 ? 16 : 0;
 if (c == '!') return col == 1 ? 23 : 0;
 if (c == ' ') return 0;
 return col == 1 ? 21 : 3;
}
}
Canvas::Canvas(int width, int height) : width_(std::max(1, width)), height_(std::max(1, height)), buffers_{std::vector<uint16_t>(static_cast<size_t>(width_) * height_), std::vector<uint16_t>(static_cast<size_t>(width_) * height_)} {}
void Canvas::clear(uint16_t c) { std::fill(back(), back()+width_*height_, c); }
void Canvas::pixel(int x,int y,uint16_t c) { if (x>=0 && x<width_ && y>=0 && y<height_) back()[y*width_+x]=c; }
void Canvas::line(int x0,int y0,int x1,int y1,uint16_t c) {
 int dx=std::abs(x1-x0), sx=x0<x1?1:-1, dy=-std::abs(y1-y0), sy=y0<y1?1:-1, err=dx+dy;
 for (;;) { pixel(x0,y0,c); if(x0==x1 && y0==y1) break; int e=2*err; if(e>=dy){err+=dy;x0+=sx;} if(e<=dx){err+=dx;y0+=sy;} }
}
void Canvas::rect(int x,int y,int w,int h,uint16_t c) { if(w<=0||h<=0)return; line(x,y,x+w-1,y,c); line(x,y+h-1,x+w-1,y+h-1,c); line(x,y,x,y+h-1,c); line(x+w-1,y,x+w-1,y+h-1,c); }
void Canvas::fillRect(int x,int y,int w,int h,uint16_t c) { if(w<=0||h<=0)return; int x0=std::max(0,x), y0=std::max(0,y), x1=std::min(width_,x+w), y1=std::min(height_,y+h); for(int j=y0;j<y1;++j) for(int i=x0;i<x1;++i) pixel(i,j,c); }
void Canvas::blit(int x,int y,int w,int h,const uint16_t* p,uint16_t transparent) { if(!p||w<=0||h<=0)return; for(int j=0;j<h;++j) for(int i=0;i<w;++i) if(p[j*w+i]!=transparent) pixel(x+i,y+j,p[j*w+i]); }
void Canvas::text(int x,int y,const char* s,uint16_t c,Font f,int scale) {
 if (!s || scale < 1) return;
 const int cw=f==Font::Small3x5?3:5, ch=f==Font::Small3x5?5:7;
 for(;*s;++s,x+=(cw+1)*scale){ unsigned char v=static_cast<unsigned char>(*s); if(v<32||v>127)v='?'; for(int col=0;col<cw;++col){ uint8_t bits=f==Font::Small3x5?small(v,col):font5[(v-32)*5+col]; for(int row=0;row<ch;++row) if(bits&(1<<row)) fillRect(x+col*scale,y+row*scale,scale,scale,c); } }
}
int Canvas::textWidth(const char* s,Font f,int scale) { if(!s||!*s||scale<1)return 0; int cw=f==Font::Small3x5?3:5; return (static_cast<int>(std::strlen(s))*(cw+1)-1)*scale; }
void Canvas::swap(){ front_=1-front_; }

} // namespace arcade
