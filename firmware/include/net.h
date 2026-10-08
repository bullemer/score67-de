#pragma once
// Wi-Fi, registration at score67 and the live feed over WebSocket.
#include <stdint.h>
#include "feed.h"

enum class NetState { WIFI_CONNECTING, REGISTERING, CONNECTING, ONLINE, OFFLINE };

struct NetStatus {
  NetState state = NetState::WIFI_CONNECTING;
  char ssid[33] = "";
  int rssi = 0;
  char displayId[16] = "";
  bool haveToken = false;
  uint32_t lastMessageAt = 0;   // millis() of the last feed message
  uint32_t connectedAt = 0;
  int failures = 0;             // socket failures in a row
};

class Net {
 public:
  // Called when a feed message arrived (already parsed).
  void (*onFeed)(const Feed &) = nullptr;
  void begin();
  void loop();
  const NetStatus &status() const { return st; }
  // Status line to the server ({"fw", "rssi", "uptime", "panel"}), also sent every 30 s.
  void sendStatus();
  // Forgets the device key: the panel becomes a new, unclaimed display (factory reset).
  void forgetDevice();

 private:
  NetStatus st;
  uint32_t nextAttempt = 0, lastStatus = 0;
  int backoff = 1;
  void loadIdentity();
  bool registerDevice();
  void openSocket();
};

extern Net net;
