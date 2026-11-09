#include "galaga.h"
#include <algorithm>

void Galaga::reset(int width, int height, uint32_t now) {
  width_=width; height_=height; ship_=width/2;
  for (auto &shot : shots_) shot.y=-1;
  enemyX_=0; direction_=1; lives_=3; remaining_=24;
  bombY_=-1; nextEnemy_=0; lastBomb_=lastDive_=now; diver_=-1;
  for (bool &enemy : enemies_) enemy=true;
  last_=lastMove_=now; lastFire_=0; restartAt_=0;
}
void Galaga::update(uint32_t now, int position, bool fire) {
  ship_=2 + position * (width_-5) / 100;
  if (restartAt_) {
    if (static_cast<int32_t>(now-restartAt_) >= 0) reset(width_,height_,now);
    return;
  }
  if (fire && now-lastFire_>=120) for (auto &shot : shots_) if (shot.y<0) {
    shot.x=ship_; shot.y=height_-5; lastFire_=now; break;
  }
  if (now-lastMove_>=300) {
    lastMove_=now; enemyX_+=direction_;
    if (enemyX_>=4 || enemyX_<=-4) direction_=-direction_;
  }
  if (now-last_<60) return;
  last_=now;
  if (diver_<0 && now-lastDive_>=1800) {
    for (int j=0;j<24;++j) { int i=(nextEnemy_+j)%24; if (enemies_[i]) {
      diver_=i; diveX_=6+(i%8)*((width_-12)/8)+enemyX_; diveY_=3+(i/8)*4;
      nextEnemy_=(i+7)%24; lastDive_=now; break;
    }}
  }
  if (diver_>=0) {
    ++diveY_;
    if ((diveY_ & 1)==0) diveX_ += (ship_>diveX_) - (ship_<diveX_);
    if (diveY_>=height_-4) {
      if (diveX_>=ship_-2 && diveX_<=ship_+2 && --lives_==0) restartAt_=now+3000;
      diver_=-1;
    }
  }
  if (bombY_<0 && now-lastBomb_>=700) {
    for (int j=0; j<24; ++j) { int i=(nextEnemy_+j)%24; if (enemies_[i]) {
      bombX_=6+(i%8)*((width_-12)/8)+enemyX_; bombY_=5+(i/8)*4;
      nextEnemy_=(i+7)%24; lastBomb_=now; break;
    }}
  }
  if (bombY_>=0 && ++bombY_>=height_-4) {
    if (bombX_>=ship_-2 && bombX_<=ship_+2 && --lives_==0) restartAt_=now+3000;
    bombY_=-1;
  }
  for (auto &shot : shots_) if (shot.y>=0) {
    --shot.y;
    if (diver_>=0 && shot.x>=diveX_-1 && shot.x<=diveX_+1 && shot.y>=diveY_ && shot.y<=diveY_+1) {
      enemies_[diver_]=false; diver_=-1; --remaining_; shot.y=-1;
      if (!remaining_) restartAt_=now+3000;
      continue;
    }
    int spacing=(width_-12)/8;
    for (int i=0;i<24;i++) if (enemies_[i] && i!=diver_) {
      int x=6+(i%8)*spacing+enemyX_, y=3+(i/8)*4;
      if (shot.x>=x-1 && shot.x<=x+1 && shot.y>=y && shot.y<=y+1) {
        enemies_[i]=false; --remaining_; shot.y=-1;
        if (!remaining_) restartAt_=now+3000;
        break;
      }
    }
  }
}
void Galaga::draw(Canvas &c) const {
  int spacing=(width_-12)/8;
  for(int i=0;i<24;i++) if(enemies_[i] && i!=diver_) {
    int x=6+(i%8)*spacing+enemyX_, y=3+(i/8)*4;
    c.set(x,y,0xff4080); c.set(x-1,y+1,0x40dfff); c.set(x+1,y+1,0x40dfff);
  }
  c.set(ship_,height_-5,0xffffff);
  for(int x=-2;x<=2;x++) c.set(ship_+x,height_-4,0x40ff80);
  if(diver_>=0) { c.set(diveX_,diveY_,0xff4080); c.set(diveX_-1,diveY_+1,0x40dfff); c.set(diveX_+1,diveY_+1,0x40dfff); }
  for(const auto &shot : shots_) if(shot.y>=0) c.set(shot.x,shot.y,0xffff00);
  if(bombY_>=0) c.set(bombX_,bombY_,0xff3030);
  for(int i=0;i<lives_;i++) c.set(1+i*2,0,0xff3030);
}
