#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define PWMA 19
#define AIN1 22
#define AIN2 21

const int pwmFreq = 5000;
const int pwmResolution = 8;   // 0..255

#define SERVICE_UUID        "12345678-1234-1234-1234-1234567890AB"
#define CHARACTERISTIC_UUID "87654321-4321-4321-4321-BA0987654321"

BLECharacteristic* postureCharacteristic;
uint8_t currentLevel = 0;

void motorStop() {
  digitalWrite(AIN1, LOW);
  digitalWrite(AIN2, LOW);
  ledcWrite(PWMA, 0);
}

void motorForward(uint8_t duty) {
  digitalWrite(AIN1, HIGH);
  digitalWrite(AIN2, LOW);
  ledcWrite(PWMA, duty);
}

void applyMotorLevel(uint8_t level) {
  currentLevel = level;

  switch (level) {
    case 0:
      Serial.println("Motor OFF");
      motorStop();
      break;

    case 1:
      Serial.println("Motor LOW");
      motorForward(100);   // tune as needed
      break;

    case 2:
      Serial.println("Motor MEDIUM");
      motorForward(170);   // tune as needed
      break;

    case 3:
      Serial.println("Motor HIGH");
      motorForward(255);
      break;

    default:
      Serial.println("Unknown level, stopping motor");
      motorStop();
      break;
  }
}

class PostureCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) override {
    String value = pCharacteristic->getValue();

    if (value.length() == 0) {
      Serial.println("Received empty BLE write");
      return;
    }

    uint8_t level = (uint8_t)value[0];

    Serial.print("Received level: ");
    Serial.println(level);

    applyMotorLevel(level);
  }
};

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    Serial.println("iPhone connected");
  }

  void onDisconnect(BLEServer* pServer) override {
    Serial.println("iPhone disconnected");
    applyMotorLevel(0);   // fail safe
    BLEDevice::startAdvertising();
  }
};

void setup() {
  Serial.begin(115200);
  delay(2000);
  Serial.println("Starting BLE + motor test");

  pinMode(AIN1, OUTPUT);
  pinMode(AIN2, OUTPUT);

  ledcAttach(PWMA, pwmFreq, pwmResolution);
  motorStop();

  BLEDevice::init("InPosture-ESP32");
  BLEServer* pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  postureCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );

  postureCharacteristic->setCallbacks(new PostureCallbacks());

  pService->start();

  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  Serial.println("BLE advertising started");
}

void loop() {
  delay(100);
}