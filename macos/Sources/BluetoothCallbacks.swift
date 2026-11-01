import CoreBluetooth

/// Each central and peripheral delegate belongs to one awake generation. A late callback
/// from a cancelled connection must not become valid just because the Mac woke again.
final class BluetoothCallbacks: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private weak var agent: Agent?
    private let accepts: () -> Bool
    init(agent: Agent, accepts: @escaping () -> Bool) { self.agent = agent; self.accepts = accepts }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if accepts() { agent?.centralManagerDidUpdateState(central) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        if accepts() { agent?.centralManager(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: rssi) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if accepts() { agent?.centralManager(central, didConnect: peripheral) }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if accepts() { agent?.centralManager(central, didDisconnectPeripheral: peripheral, error: error) }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if accepts() { agent?.centralManager(central, didFailToConnect: peripheral, error: error) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if accepts() { agent?.peripheral(peripheral, didDiscoverServices: error) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if accepts() { agent?.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if accepts() { agent?.peripheral(peripheral, didUpdateValueFor: characteristic, error: error) }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if accepts() { agent?.peripheral(peripheral, didWriteValueFor: characteristic, error: error) }
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if accepts() { agent?.peripheral(peripheral, didModifyServices: invalidatedServices) }
    }
}
