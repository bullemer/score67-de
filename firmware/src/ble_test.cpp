#include "ble_test.h"
#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

namespace BleTest {
namespace {
constexpr char SERVICE[] = "7f671001-8a60-4e16-9b3f-5c6e3331a001";
constexpr char INPUT_UUID[] = "7f671002-8a60-4e16-9b3f-5c6e3331a001";
constexpr char ACK[] = "7f671003-8a60-4e16-9b3f-5c6e3331a001";
BLEServer *server = nullptr;
BLECharacteristic *ack = nullptr;
portMUX_TYPE lock = portMUX_INITIALIZER_UNLOCKED;
bool enabled = false, link = false, restartAdvertising = false;
uint16_t connections[4];
int connectionCount = 0;
char pendingCommand = 0;
int cursor = 50;
uint32_t events = 0, lastActivity = 0;
class ServerEvents : public BLEServerCallbacks {
  void onConnect(BLEServer*, esp_ble_gatts_cb_param_t *p) override {
    portENTER_CRITICAL(&lock); if (connectionCount < 4) connections[connectionCount++] = p->connect.conn_id; link = connectionCount > 0; restartAdvertising = true; lastActivity = millis(); portEXIT_CRITICAL(&lock);
  }
  void onDisconnect(BLEServer*, esp_ble_gatts_cb_param_t *p) override {
    portENTER_CRITICAL(&lock); for (int i = 0; i < connectionCount; ++i) if (connections[i] == p->disconnect.conn_id) { connections[i] = connections[--connectionCount]; break; } link = connectionCount > 0; restartAdvertising = enabled; lastActivity = millis(); portEXIT_CRITICAL(&lock);
  }
};
class InputEvents : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *ch) override {
    std::string value = ch->getValue();
    if (value.empty()) return;
    // BLE Joystick Pro defaults: D/d = left, B/b = right (short/long).
    // L/R remain supported by the Score67 browser controller.
    const char command = value[0];
    const bool left = command == 'L' || command == 'D' || command == 'd';
    const bool right = command == 'R' || command == 'B' || command == 'b';
    if (!left && !right) {
      if (command == 'A' || command == 'C' || command == 'E' || command == 'e' || command == 'F' || command == 'G' || command == 'H') {
        portENTER_CRITICAL(&lock); pendingCommand = command; portEXIT_CRITICAL(&lock);
      }
      return;
    }
    portENTER_CRITICAL(&lock);
    if (!enabled) { portEXIT_CRITICAL(&lock); return; }
    cursor += left ? -5 : 5;
    if (cursor < 0) cursor = 0; if (cursor > 100) cursor = 100;
    ++events; lastActivity = millis();
    portEXIT_CRITICAL(&lock);
    // Echo the input bytes. A test client can measure write-to-notification RTT;
    // this does not include the time until the display refreshes.
    ack->setValue((uint8_t *)value.data(), value.size()); ack->notify();
  }
};
}
void start() {
  if (enabled) return;
  if (!server) {
    BLEDevice::init("Score67 BLE Test");
    server = BLEDevice::createServer(); server->setCallbacks(new ServerEvents());
    BLEService *service = server->createService(SERVICE);
    BLECharacteristic *input = service->createCharacteristic(INPUT_UUID, BLECharacteristic::PROPERTY_WRITE);
    input->setCallbacks(new InputEvents());
    ack = service->createCharacteristic(ACK, BLECharacteristic::PROPERTY_NOTIFY);
    ack->addDescriptor(new BLE2902()); service->start();
    BLEDevice::getAdvertising()->addServiceUUID(SERVICE);
  }
  portENTER_CRITICAL(&lock); enabled = true; cursor = 50; events = 0; lastActivity = millis(); portEXIT_CRITICAL(&lock);
  BLEDevice::startAdvertising(); Serial.println("[ble] test started; device Score67 BLE Test");
}
void stop() {
  portENTER_CRITICAL(&lock); enabled = false; restartAdvertising = false; bool wasConnected = link; link = false; portEXIT_CRITICAL(&lock);
  BLEDevice::getAdvertising()->stop();
  if (server && wasConnected) server->disconnect(server->getConnId());
  Serial.println("[ble] test stopped");
}
void loop(uint32_t now) {
  portENTER_CRITICAL(&lock); bool run=enabled, again=restartAdvertising; restartAdvertising=false; portEXIT_CRITICAL(&lock);
  if (!run) return;
  // Keep advertising while idle so a controller can connect at any time.
  if (again) BLEDevice::startAdvertising();
}
bool active() { portENTER_CRITICAL(&lock); bool v=enabled; portEXIT_CRITICAL(&lock); return v; }
bool connected() { portENTER_CRITICAL(&lock); bool v=link; portEXIT_CRITICAL(&lock); return v; }
int position() { portENTER_CRITICAL(&lock); int v=cursor; portEXIT_CRITICAL(&lock); return v; }
uint32_t count() { portENTER_CRITICAL(&lock); uint32_t v=events; portEXIT_CRITICAL(&lock); return v; }
int controllers() { portENTER_CRITICAL(&lock); int v=connectionCount; portEXIT_CRITICAL(&lock); return v; }
char takeCommand() { portENTER_CRITICAL(&lock); char v=pendingCommand; pendingCommand=0; portEXIT_CRITICAL(&lock); return v; }
void disconnectAll() {
  uint16_t ids[4]; int n;
  portENTER_CRITICAL(&lock); n=connectionCount; for (int i=0; i<n; ++i) ids[i]=connections[i]; pendingCommand=0; portEXIT_CRITICAL(&lock);
  for (int i=0; i<n; ++i) server->disconnect(ids[i]);
}
}
