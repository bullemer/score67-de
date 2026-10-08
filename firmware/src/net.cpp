#include "net.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <WebSocketsClient.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include "certs.h"
#include "config.h"
#include "secrets.h"

Net net;

namespace {
Preferences prefs;
WebSocketsClient socket;
char deviceKey[48] = "", token[64] = "";
bool socketOpen = false;
char lastFeed[4096];   // the newest message, parsed in loop() (the callback must stay short)
volatile bool feedPending = false;

void randomKey(char *out, int length) {
  static const char alphabet[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  for (int i = 0; i < length; i++) out[i] = alphabet[esp_random() % (sizeof(alphabet) - 1)];
  out[length] = 0;
}

void socketEvent(WStype_t type, uint8_t *payload, size_t length) {
  NetStatus &st = const_cast<NetStatus &>(net.status());
  switch (type) {
    case WStype_CONNECTED:
      socketOpen = true;
      st.state = NetState::ONLINE;
      st.connectedAt = millis();
      Serial.println("[net] socket connected");
      net.sendStatus();
      break;
    case WStype_DISCONNECTED:
      if (socketOpen) Serial.println("[net] socket closed");
      socketOpen = false;
      // Closed right after connecting and never fed: the token is gone (panel
      // removed in the app, code 1008) or the server rejected it. Re-register.
      if (st.state == NetState::ONLINE && st.lastMessageAt < st.connectedAt) st.failures++;
      else if (st.state == NetState::ONLINE) st.failures = 0;
      st.state = NetState::OFFLINE;
      break;
    case WStype_TEXT:
      if (length < sizeof lastFeed) {
        memcpy(lastFeed, payload, length);
        lastFeed[length] = 0;
        feedPending = true;
      }
      break;
    default:
      break;
  }
}
}  // namespace

void Net::loadIdentity() {
  prefs.begin("score67", false);
  String key = prefs.getString("device_key", "");
  if (key.length() < 32) {
    randomKey(deviceKey, 40);
    prefs.putString("device_key", deviceKey);
    Serial.println("[net] new device key");
  } else {
    strncpy(deviceKey, key.c_str(), sizeof deviceKey - 1);
  }
  String t = prefs.getString("token", "");
  strncpy(token, t.c_str(), sizeof token - 1);
  String id = prefs.getString("display_id", "");
  strncpy(st.displayId, id.c_str(), sizeof st.displayId - 1);
  st.haveToken = token[0] != 0;
}

void Net::forgetDevice() {
  prefs.clear();
  token[0] = deviceKey[0] = st.displayId[0] = 0;
  st.haveToken = false;
  socket.disconnect();
  loadIdentity();
  st.state = NetState::REGISTERING;
  nextAttempt = 0;
}

void Net::begin() {
  loadIdentity();
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  // Networks saved by the setup portal come first; the development network
  // from secrets.h is the fallback (empty in the field).
  String ssid = prefs.getString("wifi_ssid", DEV_WIFI_SSID), pass = prefs.getString("wifi_pass", DEV_WIFI_PASSWORD);
  strncpy(st.ssid, ssid.c_str(), sizeof st.ssid - 1);
  if (ssid.length()) WiFi.begin(ssid.c_str(), pass.c_str());
  Serial.printf("[net] wifi %s ...\n", st.ssid);
  socket.onEvent(socketEvent);
  socket.setReconnectInterval(5000);
  socket.enableHeartbeat(15000, 5000, 2);
}

bool Net::registerDevice() {
  WiFiClientSecure secure;
  WiFiClient plain;
  secure.setCACert(ISRG_ROOTS);
  HTTPClient http;
  String url = String(SCORE67_TLS ? "https://" : "http://") + SCORE67_HOST + ":" + SCORE67_PORT + "/api/display/register";
  if (!(SCORE67_TLS ? http.begin(secure, url) : http.begin(plain, url))) return false;
  http.addHeader("Content-Type", "application/json");
  JsonDocument body;
  body["device_key"] = deviceKey;
  body["fw"] = FW_VERSION;
  String json;
  serializeJson(body, json);
  int code = http.POST(json);
  if (code != 200) {
    Serial.printf("[net] register failed: %d\n", code);
    http.end();
    return false;
  }
  JsonDocument doc;
  if (deserializeJson(doc, http.getString())) { http.end(); return false; }
  http.end();
  strncpy(token, doc["token"] | "", sizeof token - 1);
  strncpy(st.displayId, doc["display_id"] | "", sizeof st.displayId - 1);
  prefs.putString("token", token);
  prefs.putString("display_id", st.displayId);
  st.haveToken = token[0] != 0;
  const char *pairing = doc["code"] | "";
  Serial.printf("[net] registered as %s%s%s\n", st.displayId, pairing[0] ? ", code " : "", pairing);
  return st.haveToken;
}

void Net::openSocket() {
  String path = String("/ws/display?format=compact&token=") + token;
  if (SCORE67_TLS) socket.beginSslWithCA(SCORE67_HOST, SCORE67_PORT, path.c_str(), ISRG_ROOTS);
  else socket.begin(SCORE67_HOST, SCORE67_PORT, path.c_str());
  st.state = NetState::CONNECTING;
}

void Net::sendStatus() {
  if (!socketOpen) return;
  JsonDocument doc;
  doc["fw"] = FW_VERSION;
  doc["rssi"] = WiFi.RSSI();
  doc["uptime"] = (long)(millis() / 1000);
  doc["panel"] = "64x32";
  String json;
  serializeJson(doc, json);
  socket.sendTXT(json);
  lastStatus = millis();
}

void Net::loop() {
  uint32_t now = millis();
  st.rssi = WiFi.RSSI();
  if (WiFi.status() != WL_CONNECTED) {
    if (st.state != NetState::WIFI_CONNECTING) {
      Serial.println("[net] wifi lost");
      socket.disconnect();
      socketOpen = false;
    }
    st.state = NetState::WIFI_CONNECTING;
    return;
  }
  if (st.state == NetState::WIFI_CONNECTING) {
    Serial.printf("[net] wifi connected, %s\n", WiFi.localIP().toString().c_str());
    st.state = st.haveToken ? NetState::OFFLINE : NetState::REGISTERING;
    nextAttempt = 0;
  }
  if (st.failures >= 3) {   // the token no longer works: register again (same key keeps owner and game)
    st.failures = 0;
    st.haveToken = false;
    socket.disconnect();
    st.state = NetState::REGISTERING;
  }
  if ((st.state == NetState::REGISTERING || st.state == NetState::OFFLINE) && now >= nextAttempt) {
    bool ok = st.haveToken || registerDevice();
    if (ok) {
      backoff = 1;
      openSocket();
    } else {
      nextAttempt = now + backoff * 1000;
      backoff = backoff < 30 ? backoff * 2 : 30;
    }
  }
  socket.loop();
  if (feedPending) {
    feedPending = false;
    Feed feed;
    if (parseFeed(lastFeed, feed)) {
      st.lastMessageAt = now;
      st.failures = 0;
      if (onFeed) onFeed(feed);
    } else {
      Serial.println("[net] bad feed json");
    }
  }
  if (socketOpen && now - lastStatus > 30000) sendStatus();
}
