#include "intro.h"
#include <Preferences.h>
#include <mbedtls/sha256.h>
#include <esp_system.h>
#include <string.h>
namespace Intro {
namespace {
Preferences prefs;
char message[41] = "WELCOME TO SCORE67";
uint32_t rgb = 0x00ffff;
void digest(const String &pass, const unsigned char *salt, unsigned char *out) {
  mbedtls_sha256_context ctx; mbedtls_sha256_init(&ctx);
  mbedtls_sha256_starts_ret(&ctx, 0);
  mbedtls_sha256_update_ret(&ctx, salt, 16);
  mbedtls_sha256_update_ret(&ctx, reinterpret_cast<const unsigned char *>(pass.c_str()), pass.length());
  mbedtls_sha256_finish_ret(&ctx, out); mbedtls_sha256_free(&ctx);
}
bool verify(const String &pass) {
  unsigned char salt[16], expected[32], actual[32];
  if (prefs.getBytes("salt", salt, sizeof salt) != sizeof salt || prefs.getBytes("hash", expected, sizeof expected) != sizeof expected) return false;
  digest(pass, salt, actual); unsigned char diff = 0;
  for (int i=0; i<32; ++i) diff |= expected[i] ^ actual[i];
  return diff == 0;
}
}
void begin() {
  prefs.begin("s67-intro", false);
  // Provision the requested initial credential once; later USB changes persist.
  if (!prefs.getBool("admin-v1", false)) {
    const unsigned char salt[16] = {0x3a, 0x99, 0x78, 0x1d, 0x7a, 0x55, 0xdd, 0x60, 0x5f, 0xc7, 0xb3, 0x9a, 0xb9, 0x29, 0x81, 0x17};
    const unsigned char hash[32] = {0x33, 0x00, 0xb0, 0x54, 0x89, 0xd2, 0xe7, 0xf8, 0x11, 0x45, 0xb5, 0x32, 0x42, 0x98, 0x11, 0x23, 0xf5, 0x59, 0xd4, 0x59, 0x8f, 0xfa, 0x86, 0x5a, 0x6a, 0x60, 0x5f, 0xfb, 0xcb, 0xbf, 0xda, 0x5b};
    if (prefs.putBytes("salt", salt, sizeof salt) == sizeof salt && prefs.putBytes("hash", hash, sizeof hash) == sizeof hash)
      prefs.putBool("admin-v1", true);
  }
  String saved=prefs.getString("text", message);
  strlcpy(message, saved.c_str(), sizeof message); rgb=prefs.getUInt("color", rgb);
}
const char *text() { return message; }
uint32_t color() { return rgb; }
bool hasPassword() { return prefs.getBytesLength("salt") == 16 && prefs.getBytesLength("hash") == 32; }
bool setPassword(const String &pass) {
  if (pass.length() < 8 || pass.length() > 80) return false;
  unsigned char salt[16], hash[32]; esp_fill_random(salt, sizeof salt); digest(pass,salt,hash);
  return prefs.putBytes("salt",salt,sizeof salt)==sizeof salt && prefs.putBytes("hash",hash,sizeof hash)==sizeof hash;
}
bool save(const String &pass, const String &value, uint32_t color) {
  if (!verify(pass) || value.length() == 0 || value.length() > 40 || color > 0xffffff) return false;
  for (size_t i=0; i<value.length(); ++i) if (value[i] < 32 || value[i] > 90) return false;
  if (!prefs.putString("text",value) || !prefs.putUInt("color",color)) return false;
  strlcpy(message,value.c_str(),sizeof message); rgb=color; return true;
}
}
