#pragma once
#include <Arduino.h>
namespace Intro {
void begin();
const char *text();
uint32_t color();
bool hasPassword();
bool setPassword(const String &password);
bool save(const String &password, const String &text, uint32_t color);
}
