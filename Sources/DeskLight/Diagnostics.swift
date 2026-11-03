import CoreBluetooth
import Foundation
import LampKit

/// `open DeskLight.app --args --diagnose [name-substring]`
/// Scans every BLE device, connects to the best lamp candidate, dumps its GATT table,
/// then sends handshake → on → off → on. Writes to ~/Library/Logs/DeskLight-diagnose.log.
final class Diagnostics: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DeskLight-diagnose.log")

    private var central: CBCentralManager!
    private var candidates: [(CBPeripheral, String, Int, [String])] = []
    private var target: CBPeripheral?
    private var writable: [CBCharacteristic] = []
    private let nameFilter: String?

    init(nameFilter: String?) {
        self.nameFilter = nameFilter?.uppercased()
        super.init()
        try? "".write(to: Self.logURL, atomically: true, encoding: .utf8)
        log("DeskLight diagnose \(Date()) authorization=\(CBManager.authorization.rawValue) (0 notDetermined, 1 restricted, 2 denied, 3 allowed)")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func log(_ s: String) {
        print(s)
        guard let h = try? FileHandle(forWritingTo: Self.logURL) else { return }
        h.seekToEndOfFile()
        h.write(Data((s + "\n").utf8))
        try? h.close()
    }

    private func hex(_ d: Data?) -> String { (d ?? Data()).map { String(format: "%02X", $0) }.joined(separator: " ") }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("Bluetooth state: \(c.state.rawValue) (5 = on, 3 = unauthorized, 4 = off)")
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.pick() }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
        guard !candidates.contains(where: { $0.0.identifier == p.identifier }) else { return }
        let name = (a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "(no name)"
        let services = ((a[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).map(\.uuidString)
        let mfg = hex(a[CBAdvertisementDataManufacturerDataKey] as? Data)
        candidates.append((p, name, rssi.intValue, services))
        log("seen \(name) rssi=\(rssi) id=\(p.identifier) services=\(services) mfg=\(mfg)")
    }

    private func score(_ name: String, _ services: [String]) -> Int {
        let n = name.uppercased()
        if let f = nameFilter { return n.contains(f) ? 10 : 0 }
        if services.contains(where: { ["FFE0", "FFF0", "FFD5", "FFE5"].contains($0) }) { return 5 }
        if n.hasPrefix("LED") || n.contains("ELK") || n.contains("BLEDOM") || n.contains("LAMP") || n.contains("LIGHT") { return 4 }
        return 0
    }

    private func pick() {
        central.stopScan()
        let ranked = candidates.map { ($0, score($0.1, $0.3)) }.filter { $0.1 > 0 }
            .sorted { ($0.1, $0.0.2) > ($1.1, $1.0.2) }
        guard let best = ranked.first?.0 else {
            log("No lamp candidate found among \(candidates.count) devices. Is the phone app still connected?")
            exit(1)
        }
        log("Connecting to \(best.1) (\(best.0.identifier))")
        target = best.0
        best.0.delegate = self
        central.connect(best.0)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("Connected. Discovering services…")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("Connect failed: \(String(describing: error))"); exit(1)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("Disconnected: \(String(describing: error))")
    }

    private var pendingServices = 0
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        pendingServices = services.count
        log("Services: \(services.map(\.uuid.uuidString))")
        services.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            log("  \(s.uuid.uuidString) / \(c.uuid.uuidString) props=0x\(String(c.properties.rawValue, radix: 16))")
            if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
            if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) { writable.append(c) }
        }
        pendingServices -= 1
        if pendingServices == 0 { runSequence(p) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        log("← \(c.uuid.uuidString): \(hex(c.value))")
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        log("write ack \(c.uuid.uuidString) error=\(String(describing: error))")
    }

    private func runSequence(_ p: CBPeripheral) {
        guard let c = writable.first(where: { $0.uuid == CBUUID(string: "FFE1") }) ?? writable.first(where: { $0.uuid == CBUUID(string: "FFF3") }) ?? writable.first else {
            log("No writable characteristic."); exit(1)
        }
        let variant = LampProtocol.Variant(deviceName: p.name ?? "")
        let steps: [(String, [UInt8])] = [
            ("handshake", LampProtocol.handshake()),
            ("ON", LampProtocol.power(true, variant: variant)),
            ("OFF", LampProtocol.power(false, variant: variant)),
            ("ON", LampProtocol.power(true, variant: variant)),
            ("brightness 100", LampProtocol.brightness(100, variant: variant)),
            ("RED", LampProtocol.color(r: 255, g: 0, b: 0, variant: variant)),
            ("GREEN", LampProtocol.color(r: 0, g: 255, b: 0, variant: variant)),
            ("BLUE", LampProtocol.color(r: 0, g: 0, b: 255, variant: variant)),
            ("WARM WHITE", LampProtocol.colorTemperature(warm: 80, variant: variant)),
            ("brightness 30", LampProtocol.brightness(30, variant: variant)),
        ]
        log("Writing to \(c.uuid.uuidString), variant \(variant)")
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * 2) {
                let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
                self.log("→ \(step.0): \(step.1.map { String(format: "%02X", $0) }.joined(separator: " ")) (\(type == .withResponse ? "with" : "without") response)")
                p.writeValue(Data(step.1), for: c, type: type)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(steps.count) * 2 + 1) {
            self.log("Done.")
            self.central.cancelPeripheralConnection(p)
            exit(0)
        }
    }
}
