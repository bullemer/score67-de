#pragma once
// Wi-Fi, registration at score67 and the live feed over WebSocket.
#include <stdint.h>
#include "feed.h"

enum class NetState { WIFI_CONNECTING, REGISTERING, CONNECTING, ONLINE, OFFLINE, PORTAL };

constexpr int WIFI_SLOTS = 3;   // networks the panel remembers (club Wi-Fi, phone hotspot, ...)

struct NetStatus {
  NetState state = NetState::WIFI_CONNECTING;
  char ssid[33] = "";          // the network being tried or in use
  int rssi = 0;
  char apName[20] = "";        // setup hotspot (PORTAL)
  char apIp[16] = "";
  int networks = 0;            // stored networks
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
  // Opens the setup hotspot with the captive portal (UP held 5 s, or no network known).
  void startPortal();
  void stopPortal();

 private:
  NetStatus st;
  uint32_t nextAttempt = 0, lastStatus = 0;
  int backoff = 1;
  int slot = -1;               // network being tried: 0..WIFI_SLOTS-1, -1 = development fallback
  uint32_t attemptSince = 0, portalIdle = 0;
  bool connecting = false;
  void loadIdentity();
  bool registerDevice();
  void openSocket();
  bool nextNetwork();
  void portalLoop();
};

extern Net net;
