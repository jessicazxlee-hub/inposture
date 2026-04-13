import Foundation
import CoreBluetooth

final class BLEManager: NSObject {
    private var centralManager: CBCentralManager!
    private var posturePeripheral: CBPeripheral?
    private var postureCharacteristic: CBCharacteristic?

    let serviceUUID = CBUUID(string: "12345678-1234-1234-1234-1234567890AB")
    let characteristicUUID = CBUUID(string: "87654321-4321-4321-4321-BA0987654321")

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func sendMotorLevel(_ level: UInt8) {
        guard let peripheral = posturePeripheral,
              let characteristic = postureCharacteristic else {
            print("BLE not ready yet")
            return
        }

        let data = Data([level])
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        print("Sent motor level:", level)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("Bluetooth state:", central.state.rawValue)

        if central.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
            print("Started scanning")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        print("Discovered peripheral:", peripheral.name ?? "Unnamed")

        posturePeripheral = peripheral
        posturePeripheral?.delegate = self
        centralManager.stopScan()
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        print("Connected to peripheral")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        print("Failed to connect:", error?.localizedDescription ?? "unknown error")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        print("Disconnected from peripheral")
        posturePeripheral = nil
        postureCharacteristic = nil
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }

        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics where characteristic.uuid == characteristicUUID {
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                postureCharacteristic = characteristic
                print("Found posture characteristic")
            }
        }
    }
}

