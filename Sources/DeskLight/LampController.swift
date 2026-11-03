import CoreBluetooth
import Foundation
import LampKit
import Observation

struct DiscoveredLamp: Identifiable, Hashable {
    let id: UUID
    let name: String
    var rssi: Int
}

@MainActor
@Observable
final class LampController: NSObject {
    enum Status: Equatable {
        case bluetoothOff, unauthorized, idle, scanning, connecting(String), connected(String)

        var label: String {
            switch self {
            case .bluetoothOff: "Bluetooth is off"
            case .unauthorized: "Bluetooth permission denied"
            case .idle: "Not connected"
            case .scanning: "Scanning…"
            case .connecting(let n): "Connecting to \(n)…"
            case .connected(let n): "Connected: \(n)"
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var discovered: [DiscoveredLamp] = []
    private(set) var log: [String] = []

    var isConnected: Bool { characteristic != nil }

    /// What the app last told the lamp to do; used to restore after On-Air / unlock.
    private(set) var isOn = true
    private(set) var look: LampAction?
    /// While set (e.g. On-Air), ambient features like wallpaper sync must not change the colour.
    var lookIsHeld = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var variant: LampProtocol.Variant = .classic
    private var queue: [[UInt8]] = []
    private var writing = false
    private var pendingAfterConnect: [LampAction] = []
    private var reconnectTask: Task<Void, Never>?

    /// Last lamp the user picked; reconnected automatically on launch and wake.
    private var savedLampID: UUID? {
        get { UserDefaults.standard.string(forKey: "lampID").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "lampID") }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Public API

    func startScan() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        status = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.status == .scanning else { return }
            self.central.stopScan()
            self.status = .idle
        }
    }

    func connect(_ lamp: DiscoveredLamp) {
        guard let p = central.retrievePeripherals(withIdentifiers: [lamp.id]).first else { return }
        savedLampID = lamp.id
        connect(p)
    }

    func disconnect() {
        reconnectTask?.cancel()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func forget() {
        savedLampID = nil
        disconnect()
    }

    /// Runs actions now, connecting first if needed (used by schedules).
    func perform(_ actions: [LampAction]) {
        guard isConnected else {
            pendingAfterConnect += actions
            reconnect()
            return
        }
        for action in actions { send(frame(for: action)) }
    }

    func reconnect() {
        guard central.state == .poweredOn, characteristic == nil, let id = savedLampID,
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        connect(p)
    }

    func setPower(_ on: Bool) { perform([on ? .on : .off]) }
    func setBrightness(_ v: Int) { perform([.brightness(v)]) }
    func setWarmth(_ warm: Int) { perform([.colorTemperature(warm: warm)]) }
    func setColor(r: Int, g: Int, b: Int) { perform([.color(r: r, g: g, b: b)]) }
    func setEffect(_ mode: Int) { perform([.effect(mode)]) }
    func setSpeed(_ v: Int) { perform([.speed(v)]) }
    func toggle() { setPower(!isOn) }

    // MARK: Internals

    /// Brightness on `.compact` lamps is tagged with the panel last used (RGB vs white).
    private var lastChannel: LampProtocol.Channel = .rgb

    private func frame(for action: LampAction) -> [UInt8] {
        switch action {
        case .on:
            isOn = true
            return LampProtocol.power(true, variant: variant)
        case .off:
            isOn = false
            return LampProtocol.power(false, variant: variant)
        case .brightness(let b):
            return LampProtocol.brightness(b, variant: variant, channel: lastChannel)
        case .colorTemperature(let w):
            lastChannel = .colorTemperature
            look = action
            return LampProtocol.colorTemperature(warm: w, variant: variant)
        case .color(let r, let g, let b):
            lastChannel = .rgb
            look = action
            return LampProtocol.color(r: r, g: g, b: b, variant: variant)
        case .effect(let n):
            look = action
            return LampProtocol.effect(n, variant: variant)
        case .speed(let v):
            return LampProtocol.speed(v, variant: variant)
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        status = .connecting(p.name ?? "lamp")
        central.stopScan()
        central.connect(p)
    }

    private func send(_ bytes: [UInt8]) {
        guard let peripheral, let characteristic else { return }
        // Collapse rapid slider updates: keep only the newest frame per command type.
        let key = commandKey(bytes)
        queue.removeAll { commandKey($0) == key }
        queue.append(bytes)
        if !writing { drain(peripheral, characteristic) }
    }

    private func commandKey(_ b: [UInt8]) -> [UInt8] {
        b[1] == 0xFF || b[0] == 0x7B ? Array(b.prefix(4)) : Array(b.prefix(2))
    }

    /// The Android app paces writes 30–100 ms apart; the lamp drops frames sent faster.
    private func drain(_ p: CBPeripheral, _ c: CBCharacteristic) {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        writing = true
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(next), for: c, type: type)
        append("→ " + next.map { String(format: "%02X", $0) }.joined(separator: " "))
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            self.writing = false
            if let p = self.peripheral, let c = self.characteristic { self.drain(p, c) }
        }
    }

    private static let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DeskLight.log")

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        let stamped = "\(Date().formatted(.iso8601)) \(line)\n"
        if let h = try? FileHandle(forWritingTo: Self.logFile) {
            h.seekToEndOfFile()
            h.write(Data(stamped.utf8))
            try? h.close()
        } else {
            try? stamped.write(to: Self.logFile, atomically: true, encoding: .utf8)
        }
    }

    private func didBecomeReady(_ p: CBPeripheral, _ c: CBCharacteristic) {
        characteristic = c
        variant = .init(deviceName: p.name ?? "")
        status = .connected(p.name ?? "lamp")
        append("Connected to \(p.name ?? "lamp") (\(variant))")
        if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.send(LampProtocol.handshake())
            let pending = self.pendingAfterConnect
            self.pendingAfterConnect.removeAll()
            if !pending.isEmpty { self.perform(pending) }
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.reconnect()
        }
    }
}

extension LampController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                status = .idle
                reconnect()
            case .unauthorized: status = .unauthorized
            default:
                status = .bluetoothOff
                characteristic = nil
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let id = p.identifier
        MainActor.assumeIsolated {
            guard LampProtocol.isSupported(name: name) else { return }
            if let i = discovered.firstIndex(where: { $0.id == id }) {
                discovered[i].rssi = rssi.intValue
            } else {
                discovered.append(.init(id: id, name: name, rssi: rssi.intValue))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([CBUUID(string: LampProtocol.serviceUUID)])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            append("Connect failed: \(error?.localizedDescription ?? "unknown")")
            status = .idle
            scheduleReconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            characteristic = nil
            queue.removeAll()
            writing = false
            status = .idle
            append("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
            if error != nil { scheduleReconnect() }
        }
    }
}

extension LampController: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == CBUUID(string: LampProtocol.serviceUUID) }) else {
            MainActor.assumeIsolated { append("Service FFE0 not found — not a LED LAMP device?") }
            return
        }
        p.discoverCharacteristics([CBUUID(string: LampProtocol.characteristicUUID)], for: s)
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let c = s.characteristics?.first(where: { $0.uuid == CBUUID(string: LampProtocol.characteristicUUID) }) else { return }
        MainActor.assumeIsolated { didBecomeReady(p, c) }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value else { return }
        MainActor.assumeIsolated {
            append("← " + data.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
    }
}
