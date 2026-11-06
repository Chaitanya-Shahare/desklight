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
    private(set) var brightnessLevel = Int(UserDefaults.standard.object(forKey: "brightness") as? Double ?? 80)
    /// Persisted so "restore previous colour" (On-Air, Pomodoro stop) works after a relaunch.
    private(set) var look: LampAction? = UserDefaults.standard.data(forKey: "look")
        .flatMap { try? JSONDecoder().decode(LampAction.self, from: $0) } {
        didSet { UserDefaults.standard.set(look.flatMap { try? JSONEncoder().encode($0) }, forKey: "look") }
    }
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

    /// Runs actions now, connecting first if needed. Cancels any running fade.
    func perform(_ actions: [LampAction]) {
        cancelFade()
        apply(actions)
    }

    private func apply(_ actions: [LampAction]) {
        guard isConnected else {
            pendingAfterConnect = Array((pendingAfterConnect + actions).suffix(20))
            reconnect()
            return
        }
        for action in actions {
            if let c = rgbOnlyColor(for: action) {
                look = action
                lastChannel = .rgb
                glide(to: c, tau: Glide.manual)
                continue
            }
            send(frame(for: action))
            // A fade to off leaves brightness at 0; bring it back when switched on again.
            if action == .on, let b = brightnessToRestore {
                brightnessToRestore = nil
                send(frame(for: .brightness(b)))
            }
        }
    }

    /// Live colour from screen/music sync. Dropped (not queued) when it can't be shown.
    /// `tau` is the glide time constant in seconds (≈ time to cover 63% of the change).
    func stream(_ c: RGB, tau: Double) {
        guard isConnected, isOn, !isFading, !lookIsHeld else { return }
        glide(to: c, tau: tau)
    }

    // MARK: Colour glide

    /// Time constants (seconds) for exponential glides; ~3τ to settle.
    enum Glide {
        static let manual = 0.12
        static let fade = 0.4
    }

    private var glideValue: SIMD3<Double>?
    private var glideTarget = SIMD3<Double>(255, 255, 255)
    private var glideTau = Glide.manual
    private var glideTask: Task<Void, Never>?
    private var lastSentColor: RGB?

    /// Colours that the lamp shows through its RGB channels (everything on RGB-only lamps).
    private func rgbOnlyColor(for action: LampAction) -> RGB? {
        switch action {
        case .color(let r, let g, let b): return RGB(r: r, g: g, b: b)
        case .colorTemperature(let w) where variant == .dmx: return Self.rgb(forWarmth: w)
        default: return nil
        }
    }

    /// Moves the shown colour toward `c` with exponential easing. Retargeting mid-glide
    /// continues from wherever the colour currently is, so rapid updates never jump.
    private func glide(to c: RGB, tau: Double) {
        glideTarget = SIMD3(Double(c.r), Double(c.g), Double(c.b))
        glideTau = max(0.001, tau)
        guard glideValue != nil, tau > 0 else {
            glideValue = glideTarget
            sendColor(c)
            return
        }
        guard glideTask == nil else { return }
        glideTask = Task { [weak self] in
            var last = ContinuousClock.now
            while let self, !Task.isCancelled, var v = self.glideValue {
                try? await Task.sleep(for: .milliseconds(25))
                let now = ContinuousClock.now
                let dt = Double((now - last).components.attoseconds) / 1e18 + Double((now - last).components.seconds)
                last = now
                let k = 1 - exp(-dt / self.glideTau)
                v += (self.glideTarget - v) * k
                let done = (self.glideTarget - v).max() < 0.5 && (v - self.glideTarget).max() < 0.5
                if done { v = self.glideTarget }
                self.glideValue = v
                self.sendColor(RGB(r: Int(v.x.rounded()), g: Int(v.y.rounded()), b: Int(v.z.rounded())), log: done)
                if done { break }
            }
            self?.glideTask = nil
        }
    }

    private func sendColor(_ c: RGB, log: Bool = true) {
        guard c != lastSentColor else { return }
        lastSentColor = c
        send(LampProtocol.color(r: c.r, g: c.g, b: c.b, variant: variant), log: log)
    }

    // MARK: Fades

    private(set) var fadeEndsAt: Date?
    private var fadeTask: Task<Void, Never>?
    private var brightnessToRestore: Int?
    var isFading: Bool { fadeTask != nil }

    func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadeEndsAt = nil
    }

    /// Gradually moves colour and brightness to `target` over `seconds`.
    /// `.on` in the target starts from darkness (sunrise); `.off` ends by switching off.
    func fade(to target: [LampAction], over seconds: TimeInterval) {
        cancelFade()
        var fromRGB = currentRGB
        var toRGB = fromRGB
        var fromB = brightnessLevel, toB = brightnessLevel
        var endOff = false
        for action in target {
            switch action {
            case .color(let r, let g, let b): toRGB = RGB(r: r, g: g, b: b)
            case .colorTemperature(let w): toRGB = Self.rgb(forWarmth: w)
            case .brightness(let b): toB = b
            case .off: endOff = true; toB = 0
            case .on:
                if !isOn {
                    fromB = 0
                    brightnessToRestore = nil
                    apply([.brightness(0), .on])
                }
            }
        }
        if !isOn && !target.contains(.on) { fromRGB = toRGB }
        let restore = brightnessLevel > 0 ? brightnessLevel : 80
        let start = Date()
        fadeEndsAt = start.addingTimeInterval(seconds)
        append("Fade over \(Int(seconds))s → \(target.map(\.label).joined(separator: ", "))")
        // Tick often enough for smooth colour, but not wastefully on hour-long fades.
        let tick = min(0.5, max(0.05, seconds / 2000))
        fadeTask = Task { [weak self] in
            var lastB = fromB
            while true {
                try? await Task.sleep(for: .seconds(tick))
                guard let self, !Task.isCancelled else { return }
                let t = min(1, Date().timeIntervalSince(start) / max(seconds, 0.001))
                if fromRGB != toRGB {
                    let c = fromRGB.mixed(with: toRGB, t)
                    self.look = .color(r: c.r, g: c.g, b: c.b)
                    self.glide(to: c, tau: tick)
                }
                let b = Int((Double(fromB) + Double(toB - fromB) * t).rounded())
                if b != lastB {
                    lastB = b
                    self.send(self.frame(for: .brightness(b)), log: false)
                }
                if t >= 1 { break }
            }
            guard let self, !Task.isCancelled else { return }
            if endOff {
                self.apply([.off])
                self.brightnessToRestore = restore
            }
            self.fadeTask = nil
            self.fadeEndsAt = nil
        }
    }

    private var currentRGB: RGB {
        switch look {
        case .color(let r, let g, let b): RGB(r: r, g: g, b: b)
        case .colorTemperature(let w): Self.rgb(forWarmth: w)
        default: RGB(r: 255, g: 255, b: 255)
        }
    }

    private static func rgb(forWarmth w: Int) -> RGB {
        let (r, g, b) = LampProtocol.rgbWhite(warm: w)
        return RGB(r: r, g: g, b: b)
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
            brightnessLevel = b
            return LampProtocol.brightness(b, variant: variant, channel: lastChannel)
        case .colorTemperature(let w):
            lastChannel = .colorTemperature
            look = action
            return LampProtocol.colorTemperature(warm: w, variant: variant)
        case .color(let r, let g, let b):
            lastChannel = .rgb
            look = action
            return LampProtocol.color(r: r, g: g, b: b, variant: variant)
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        status = .connecting(p.name ?? "lamp")
        central.stopScan()
        central.connect(p)
    }

    private func send(_ bytes: [UInt8], log: Bool = true) {
        guard let peripheral, let characteristic else { return }
        if log { append("→ " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")) }
        // Collapse rapid slider updates: keep only the newest frame per command type.
        let key = commandKey(bytes)
        queue.removeAll { commandKey($0) == key }
        queue.append(bytes)
        if !writing { drain(peripheral, characteristic) }
    }

    /// Identifies the command type (not its values) so a newer frame replaces a queued one.
    private func commandKey(_ b: [UInt8]) -> [UInt8] {
        switch (b[0], b[1]) {
        case (0x7B, 0xFF): return Array(b.prefix(3))            // 7B FF <cmd> …
        case (0x7B, _): return Array(b.prefix(3))               // 7B 04 04 (power)
        case (0x7E, 0xFF): return b[2] == 0x05 ? Array(b.prefix(4)) : Array(b.prefix(3)) // 05 has a sub-command
        default: return Array(b.prefix(2))
        }
    }

    /// The Android app paces writes 30–100 ms apart; the lamp drops frames sent faster.
    private func drain(_ p: CBPeripheral, _ c: CBCharacteristic) {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        writing = true
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(next), for: c, type: type)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(45))
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
            glideValue = nil
            lastSentColor = nil
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
