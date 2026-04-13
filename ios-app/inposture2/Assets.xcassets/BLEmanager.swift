import Foundation
import CoreBluetooth

final class BLEManager: NSObject, ObservableObject {
    
    // MARK: - BLE UUIDs
    // These MUST match the UUIDs used on the ESP32 side.
    private let serviceUUID = CBUUID(string: "12345678-1234-1234-1234-1234567890AB")
    private let characteristicUUID = CBUUID(string: "87654321-4321-4321-4321-BA0987654321")
    
    // Optional: set this if you want to connect only to a specific advertised name.
    // Leave nil to connect to any peripheral advertising the service UUID above.
    private let targetPeripheralName: String? = "InPostureESP32"
    
    // MARK: - BLE State
    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var postureCharacteristic: CBCharacteristic?
    
    private var isScanning = false
    private var hasPrintedWaitingForBluetooth = false
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Public API
    
    func start() {
        // If Bluetooth is already powered on, start scanning immediately.
        if centralManager.state == .poweredOn {
            startScanning()
        }
    }
    
    func disconnect() {
        if let targetPeripheral {
            centralManager.cancelPeripheralConnection(targetPeripheral)
        }
    }
    
    func sendPostureState(isBad: Bool) {
        let value: UInt8 = isBad ? 1 : 0
        sendByte(value)
    }
    
    func sendPostureScore(_ score: Int) {
        let clamped = max(0, min(100, score))
        let value = UInt8(clamped)
        sendByte(value)
    }
    
    // MARK: - Private Helpers
    
    private func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        guard !isScanning else { return }
        
        print("BLE: Starting scan...")
        isScanning = true
        
        // Scan only for peripherals advertising our service UUID.
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    private func stopScanning() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
        print("BLE: Stopped scan.")
    }
    
    private func sendByte(_ byte: UInt8) {
        guard let peripheral = targetPeripheral,
              let characteristic = postureCharacteristic else {
            print("BLE: Cannot send, peripheral or characteristic not ready.")
            return
        }
        
        let data = Data([byte])
        
        // Use .withResponse for reliability.
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        print("BLE: Sent byte \(byte)")
    }
}

extension BLEManager: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown:
            print("BLE: State unknown")
        case .resetting:
            print("BLE: State resetting")
        case .unsupported:
            print("BLE: Bluetooth unsupported on this device")
        case .unauthorized:
            print("BLE: Bluetooth unauthorized")
        case .poweredOff:
            print("BLE: Bluetooth is powered off")
        case .poweredOn:
            print("BLE: Bluetooth is powered on")
            hasPrintedWaitingForBluetooth = false
            startScanning()
        @unknown default:
            print("BLE: Unknown future state")
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        
        let discoveredName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        
        if let targetPeripheralName {
            guard discoveredName == targetPeripheralName else {
                return
            }
        }
        
        print("BLE: Discovered peripheral: \(discoveredName ?? "Unnamed Device")")
        
        targetPeripheral = peripheral
        targetPeripheral?.delegate = self
        
        stopScanning()
        centralManager.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("BLE: Connected to \(peripheral.name ?? "device")")
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        print("BLE: Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        postureCharacteristic = nil
        targetPeripheral = nil
        startScanning()
    }
    
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        print("BLE: Disconnected from \(peripheral.name ?? "device")")
        
        postureCharacteristic = nil
        targetPeripheral = nil
        
        if let error {
            print("BLE: Disconnect error: \(error.localizedDescription)")
        }
        
        startScanning()
    }
}

extension BLEManager: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            print("BLE: Service discovery error: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else {
            print("BLE: No services found")
            return
        }
        
        for service in services where service.uuid == serviceUUID {
            print("BLE: Found target service")
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
            return
        }
        
        print("BLE: Target service not found")
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            print("BLE: Characteristic discovery error: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else {
            print("BLE: No characteristics found")
            return
        }
        
        for characteristic in characteristics where characteristic.uuid == characteristicUUID {
            postureCharacteristic = characteristic
            print("BLE: Found posture characteristic. Ready to send data.")
            return
        }
        
        print("BLE: Target characteristic not found")
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            print("BLE: Write failed: \(error.localizedDescription)")
        } else {
            print("BLE: Write successful")
        }
    }
}
