#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#define SERVICE_UUID        "12345678-1234-1234-1234-1234567890AB"
#define CHARACTERISTIC_UUID "87654321-4321-4321-4321-BA0987654321"

class MyCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) override {
    String value = pCharacteristic->getValue();
    Serial.print("Got write, len = ");
    Serial.println(value.length());

    if (value.length() > 0) {
      Serial.print("First byte = ");
      Serial.println((uint8_t)value[0]);
    }
  }
};

void setup() {
  Serial.begin(115200);
  delay(2000);
  Serial.println("Starting BLE test");

  BLEDevice::init("InPosture-ESP32");
  BLEServer* server = BLEDevice::createServer();
  BLEService* service = server->createService(SERVICE_UUID);

  BLECharacteristic* characteristic = service->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );

  characteristic->setCallbacks(new MyCallbacks());
  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->start();

  Serial.println("BLE advertising started");
}

void loop() {
  delay(1000);
}
