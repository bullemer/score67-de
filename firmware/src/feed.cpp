#include "feed.h"

#include <ArduinoJson.h>
#include <string.h>
#include <stdlib.h>

namespace {
void copyText(char *dest, size_t size, const char *value) {
  if (!value) { dest[0] = 0; return; }
  strncpy(dest, value, size - 1);
  dest[size - 1] = 0;
}

uint32_t parseColor(const char *hex, uint32_t fallback) {
  if (!hex || hex[0] != '#' || strlen(hex) != 7) return fallback;
  return strtoul(hex + 1, nullptr, 16);
}

void parseTeam(JsonObjectConst o, FeedTeam &t) {
  t = FeedTeam();
  if (o.isNull()) return;
  copyText(t.shortName, sizeof t.shortName, o["short"] | "");
  t.color = parseColor(o["color"] | (const char *)nullptr, 0xffffff);
  t.score = o["score"] | 0;
  t.fouls = o["fouls"].isNull() ? -1 : (int)(o["fouls"] | 0);
  t.redCards = o["red_cards"] | 0;
}
}  // namespace

bool parseFeed(const char *json, Feed &feed) {
  JsonDocument doc;
  if (deserializeJson(doc, json)) {
    feed.valid = false;
    return false;
  }
  Feed f;
  f.valid = true;
  f.seq = doc["seq"] | 0L;
  f.serverNow = doc["server_now"] | 0L;
  copyText(f.mode, sizeof f.mode, doc["mode"] | "idle");
  copyText(f.name, sizeof f.name, doc["name"] | "");
  copyText(f.code, sizeof f.code, doc["code"] | "");
  copyText(f.lang, sizeof f.lang, doc["lang"] | "de");
  f.brightness = doc["brightness"] | 60;
  f.identify = doc["identify"] | false;
  copyText(f.sport, sizeof f.sport, doc["sport"] | "");
  copyText(f.phase, sizeof f.phase, doc["phase"] | "");
  copyText(f.period, sizeof f.period, doc["period"] | "");
  copyText(f.possession, sizeof f.possession, doc["possession"] | "");
  parseTeam(doc["home"], f.home);
  parseTeam(doc["guest"], f.guest);
  JsonObjectConst c = doc["clock"];
  if (!c.isNull()) {
    f.clock.visible = c["visible"] | false;
    f.clock.running = c["running"] | false;
    f.clock.down = strcmp(c["direction"] | "up", "down") == 0;
    f.clock.ms = c["ms"] | 0L;
  }
  JsonObjectConst m = doc["msg"];
  if (!m.isNull()) {
    f.msg.present = true;
    copyText(f.msg.kind, sizeof f.msg.kind, m["kind"] | "text");
    copyText(f.msg.text, sizeof f.msg.text, m["text"] | "");
    copyText(f.msg.icon, sizeof f.msg.icon, m["icon"] | "");
    copyText(f.msg.effect, sizeof f.msg.effect, m["effect"] | "static");
    f.msg.color = parseColor(m["color"] | (const char *)nullptr, 0xffa31a);
    f.msg.ms = m["ms"] | 0L;
    for (JsonArrayConst pair : m["periods"].as<JsonArrayConst>()) {
      if (f.msg.periodCount == 8) {   // keep the last 8, like the preview
        memmove(f.msg.periods[0], f.msg.periods[1], sizeof(f.msg.periods) - sizeof(f.msg.periods[0]));
        f.msg.periodCount = 7;
      }
      f.msg.periods[f.msg.periodCount][0] = pair[0] | 0;
      f.msg.periods[f.msg.periodCount][1] = pair[1] | 0;
      f.msg.periodCount++;
    }
    for (JsonVariantConst v : m["lead"].as<JsonArrayConst>()) {
      if (f.msg.leadCount >= 64) break;
      f.msg.lead[f.msg.leadCount++] = v | 0;
    }
    parseTeam(m["home"], f.msg.home);
    parseTeam(m["guest"], f.msg.guest);
  }
  JsonObjectConst fw = doc["firmware"];
  if (!fw.isNull()) {
    f.firmware.present = true;
    copyText(f.firmware.version, sizeof f.firmware.version, fw["version"] | "");
    copyText(f.firmware.url, sizeof f.firmware.url, fw["url"] | "");
    copyText(f.firmware.sha256, sizeof f.firmware.sha256, fw["sha256"] | "");
    f.firmware.size = fw["size"] | 0L;
  }
  feed = f;
  return true;
}
