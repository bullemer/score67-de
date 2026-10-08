#pragma once
// The compact display feed (docs/DISPLAY-API.md, backend/score67/display_feed.py)
// as the panel keeps it: one complete state, replaced by every message.
#include <stdint.h>

struct FeedTeam {
  char shortName[8] = "";
  uint32_t color = 0xffffff;
  int score = 0;
  int fouls = -1;        // -1: not shown
  int redCards = 0;
};

struct FeedClock {
  bool visible = false, running = false, down = false;
  long ms = 0;           // value at server_now; the panel counts on locally
};

struct FeedMessage {
  bool present = false;
  char kind[10] = "text";   // text | periods | lead
  char text[64] = "";
  char icon[12] = "";
  char effect[10] = "static";
  uint32_t color = 0xffa31a;
  long ms = 0;              // time left at server_now
  int periodCount = 0;
  int periods[8][2] = {};
  int leadCount = 0;
  int lead[64] = {};
  FeedTeam home, guest;
};

struct FeedFirmware {
  bool present = false;
  char version[20] = "";
  char url[64] = "";
  char sha256[65] = "";
  long size = 0;
};

struct Feed {
  bool valid = false;
  long seq = 0, serverNow = 0;
  char mode[10] = "idle";   // pairing | idle | game
  char name[32] = "";
  char code[8] = "";
  char lang[4] = "de";
  int brightness = 60;
  bool identify = false;
  char sport[12] = "";
  char phase[18] = "";
  char period[8] = "";
  char possession[6] = "";
  FeedTeam home, guest;
  FeedClock clock;
  FeedMessage msg;
  FeedFirmware firmware;
};

// Parses one feed message; false (and feed.valid = false) on bad JSON.
bool parseFeed(const char *json, Feed &feed);
