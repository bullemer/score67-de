#pragma once
#include <stdint.h>
namespace BleTest {
void start();
void stop();
void loop(uint32_t now);
bool active();
bool connected();
int position();
uint32_t count();
int controllers();
char takeCommand();
void disconnectAll();
}
