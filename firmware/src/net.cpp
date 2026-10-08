#include "net.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <DNSServer.h>
#include <HTTPClient.h>
#include <WebServer.h>
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
DNSServer dns;
WebServer *portal = nullptr;
char portalMessage[80] = "";

struct Network { String ssid, pass; };
Network networks[WIFI_SLOTS];

int storedNetworks() {
  int n = 0;
  for (auto &w : networks) if (w.ssid.length()) n++;
  return n;
}

void loadNetworks() {
  for (int i = 0; i < WIFI_SLOTS; i++) {
    networks[i].ssid = prefs.getString((String("wifi") + i + "_ssid").c_str(), "");
    networks[i].pass = prefs.getString((String("wifi") + i + "_pass").c_str(), "");
  }
}

void saveNetwork(const String &ssid, const String &pass) {
  int target = -1;
  for (int i = 0; i < WIFI_SLOTS; i++) if (networks[i].ssid == ssid) target = i;          // update
  for (int i = 0; target < 0 && i < WIFI_SLOTS; i++) if (!networks[i].ssid.length()) target = i;   // free slot
  if (target < 0) target = WIFI_SLOTS - 1;                                                // replace the last one
  networks[target] = {ssid, pass};
  prefs.putString((String("wifi") + target + "_ssid").c_str(), ssid);
  prefs.putString((String("wifi") + target + "_pass").c_str(), pass);
}

void deleteNetwork(int i) {
  if (i < 0 || i >= WIFI_SLOTS) return;
  networks[i] = {"", ""};
  prefs.remove((String("wifi") + i + "_ssid").c_str());
  prefs.remove((String("wifi") + i + "_pass").c_str());
}

String htmlEscape(const String &s) {
  String out;
  for (char c : s) {
    if (c == '&') out += "&amp;"; else if (c == '<') out += "&lt;"; else if (c == '"') out += "&quot;";
    else if (c == '\'') out += "&#39;"; else out += c;
  }
  return out;
}

// The setup page: nearby networks to tap, the form, the stored networks.
void portalPage() {
  String page = F("<!doctype html><html lang=de><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
                  "<title>Score67 LED-Tafel</title><style>body{font-family:system-ui,sans-serif;margin:16px;max-width:420px}"
                  "button,input{font-size:18px;padding:10px;margin:4px 0;width:100%;box-sizing:border-box}"
                  ".n{text-align:left;background:#eef;border:1px solid #99c;border-radius:6px}.m{background:#dfd;padding:8px;border-radius:6px}"
                  "small{color:#666}</style><script>function fill(b){document.getElementById('s').value=b.dataset.s}</script>"
                  "</head><body><h2>Score67 LED-Tafel</h2>");
  if (portalMessage[0]) page += String("<p class=m>") + portalMessage + "</p>";
  page += F("<p>WLAN wählen (nur 2,4 GHz; iPhone-Hotspot: „Maximale Kompatibilität“ einschalten) und Passwort eingeben.<br>"
            "<small>Choose a 2.4 GHz network and enter its password.</small></p><form method=post action=/save>");
  int found = WiFi.scanComplete();
  for (int i = 0; i < found; i++) {
    String ssid = WiFi.SSID(i);
    if (!ssid.length()) continue;
    page += "<button type=button class=n onclick='fill(this)' data-s='" + htmlEscape(ssid) + "'>" +
            htmlEscape(ssid) + " <small>" + WiFi.RSSI(i) + " dBm" + (WiFi.encryptionType(i) == WIFI_AUTH_OPEN ? ", offen" : "") + "</small></button>";
            htmlEscape(ssid) + " <small>" + WiFi.RSSI(i) + " dBm" + (WiFi.encryptionType(i) == WIFI_AUTH_OPEN ? ", offen" : "") + "</small></button>";
  }
  page += F("<input id=s name=ssid placeholder='WLAN-Name' required maxlength=32><input name=pass type=password placeholder='Passwort' maxlength=63>"
            "<button type=submit>Speichern und verbinden</button></form><form method=post action=/scan><button type=submit>Erneut suchen</button></form>");
  if (storedNetworks()) {
    page += F("<h3>Gespeicherte WLANs</h3>");
    for (int i = 0; i < WIFI_SLOTS; i++)
      if (networks[i].ssid.length())
        page += "<form method=post action=/delete><input type=hidden name=i value=" + String(i) + "><button type=submit>" + htmlEscape(networks[i].ssid) + " – löschen</button></form>";
    page += F("<form method=post action=/done><button type=submit>Fertig (Tafel verbindet sich)</button></form>");
  }
  page += F("<p><small>Die Tafel merkt sich bis zu 3 WLANs und probiert sie der Reihe nach.</small></p></body></html>");
  portal->send(200, "text/html; charset=utf-8", page);
}

void portalRedirect() {
  portal->sendHeader("Location", "http://192.168.4.1/", true);
  portal->send(302, "text/plain", "");
}
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

void Net::startPortal() {
  if (st.state == NetState::PORTAL) return;
  socket.disconnect();
  socketOpen = false;
  uint8_t mac[6];
  WiFi.macAddress(mac);
  snprintf(st.apName, sizeof st.apName, "score67-%02X%02X", mac[4], mac[5]);
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(st.apName);
  strncpy(st.apIp, WiFi.softAPIP().toString().c_str(), sizeof st.apIp - 1);
  dns.start(53, "*", WiFi.softAPIP());
  WiFi.scanNetworks(true);   // async; the page shows what is there by the time it is opened
  if (!portal) {
    portal = new WebServer(80);
    portal->on("/", HTTP_GET, portalPage);
    portal->on("/scan", HTTP_POST, [] { WiFi.scanNetworks(true); delay(2500); portalRedirect(); });
    portal->on("/save", HTTP_POST, [] {
      String ssid = portal->arg("ssid"), pass = portal->arg("pass");
      ssid.trim();
      if (!ssid.length()) { portalRedirect(); return; }
      saveNetwork(ssid, pass);
      snprintf(portalMessage, sizeof portalMessage, "Gespeichert: %.32s. Die Tafel verbindet sich jetzt.", ssid.c_str());
      portalRedirect();
      net.stopPortal();
    });
    portal->on("/delete", HTTP_POST, [] { deleteNetwork(portal->arg("i").toInt()); portalMessage[0] = 0; portalRedirect(); });
    portal->on("/done", HTTP_POST, [] { portalRedirect(); net.stopPortal(); });
    portal->onNotFound(portalRedirect);   // captive-portal probes (generate_204, hotspot-detect ...) land on the page
    portal->begin();
  }
  portalMessage[0] = 0;
  portalIdle = millis();
  st.state = NetState::PORTAL;
  Serial.printf("[net] portal: hotspot %s at %s\n", st.apName, st.apIp);
}

void Net::stopPortal() {
  if (st.state != NetState::PORTAL) return;
  delay(300);   // let the redirect reach the phone
  dns.stop();
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
  st.networks = storedNetworks();
  st.state = NetState::WIFI_CONNECTING;
  connecting = false;
  slot = -2;   // nextNetwork() starts at slot 0, i.e. the network just saved when it is the first
  Serial.println("[net] portal closed");
}

void Net::portalLoop() {
  dns.processNextRequest();
  portal->handleClient();
  // Without anyone using it, a panel that knows a network goes back to work after 5 minutes.
  if (portal->client()) portalIdle = millis();
  if (storedNetworks() && millis() - portalIdle > 300000) stopPortal();
}

// Starts the next connection attempt. A scan first: of the stored networks in
// range the strongest wins (club Wi-Fi next to a weak phone hotspot). With
// none in range the stored networks are tried in turn anyway, since a hotspot
// is often switched on only later. False when nothing is configured at all.
bool Net::nextNetwork() {
  int best = -2, bestRssi = -1000;
  int found = WiFi.scanNetworks(false, false, false, 200);
  for (int i = 0; i < found; i++) {
    String seen = WiFi.SSID(i);
    for (int j = -1; j < WIFI_SLOTS; j++) {
      const char *ssid = j >= 0 ? networks[j].ssid.c_str() : DEV_WIFI_SSID;
      if (ssid[0] && seen == ssid && WiFi.RSSI(i) > bestRssi) { best = j; bestRssi = WiFi.RSSI(i); }
    }
  }
  WiFi.scanDelete();
  if (best > -2) {
    slot = best;
  } else {
    bool any = false;
    for (int tries = 0; tries < WIFI_SLOTS + 1 && !any; tries++) {
      slot = slot + 1 > WIFI_SLOTS - 1 ? -1 : slot + 1;
      any = (slot >= 0 ? networks[slot].ssid.c_str() : DEV_WIFI_SSID)[0] != 0;
    }
    if (!any) return false;
  }
  const char *ssid = slot >= 0 ? networks[slot].ssid.c_str() : DEV_WIFI_SSID;
  const char *pass = slot >= 0 ? networks[slot].pass.c_str() : DEV_WIFI_PASSWORD;
  strncpy(st.ssid, ssid, sizeof st.ssid - 1);
  WiFi.disconnect();
  WiFi.begin(ssid, pass);
  attemptSince = millis();
  connecting = true;
  Serial.printf("[net] wifi %s%s ...\n", st.ssid, best > -2 ? " (strongest in range)" : "");
  return true;
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
  loadNetworks();
  st.networks = storedNetworks();
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(false);   // we rotate through the stored networks ourselves
  WiFi.persistent(false);
  slot = -2;
  // Networks saved by the setup portal come first; the development network
  // from secrets.h is the fallback (empty in the field). Nothing at all: portal.
  if (!nextNetwork()) startPortal();
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
  if (st.state == NetState::PORTAL) { portalLoop(); return; }
  st.rssi = WiFi.RSSI();
  if (WiFi.status() != WL_CONNECTED) {
    if (st.state != NetState::WIFI_CONNECTING) {
      Serial.println("[net] wifi lost");
      socket.disconnect();
      socketOpen = false;
      st.state = NetState::WIFI_CONNECTING;
      connecting = false;
    }
    // 15 s per network, then the next one; the hotspot may be switched on later.
    if (!connecting || now - attemptSince > 15000) {
      if (!nextNetwork()) startPortal();
    }
    return;
  }
  if (st.state == NetState::WIFI_CONNECTING) {
    connecting = false;
    Serial.printf("[net] wifi connected to %s, %s\n", st.ssid, WiFi.localIP().toString().c_str());
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
