import Foundation
import CoreBluetooth
import Combine

/// BLE control link to QCY earbuds. All CoreBluetooth callbacks run on the
/// main queue, so state is only touched from the main thread.
final class Earbuds: NSObject, ObservableObject {
    enum Status: Equatable {
        case bluetoothOff
        case unauthorized
        case searching
        case connecting
        case connected
    }

    enum Transport { case qcy, jieli }

    @Published private(set) var status: Status = .searching
    @Published private(set) var name: String?
    @Published private(set) var model: UInt16?
    @Published private(set) var firmware: String?
    @Published private(set) var battery: Battery? {
        didSet { batteryIsLastKnown = false }
    }
    /// The battery shown is what we read before the link dropped, not live.
    @Published private(set) var batteryIsLastKnown = false
    @Published private(set) var anc: AncSetting?
    @Published private(set) var aiAnc: Bool?
    @Published private(set) var eqPreset: UInt8?
    @Published var customGains: [Double] = Array(repeating: 0, count: 10)
    @Published private(set) var balance: Int?
    @Published private(set) var toggles: [UInt8: Bool] = [:]
    @Published private(set) var gameMode: Bool?
    @Published private(set) var promptVolume: UInt8?
    @Published private(set) var autoPowerOff: UInt16?
    @Published private(set) var powerTimer: UInt16?
    @Published private(set) var keys: [UInt8: UInt8] = [:]
    @Published private(set) var fitResult: (left: UInt8, right: UInt8)?
    @Published private(set) var log: [String] = []

    private(set) var transport: Transport = .qcy

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var pendingServices = 0
    private var rcsp = RCSP()
    private var queue: [(CBCharacteristic, [UInt8])] = []
    private var draining = false
    private var pollTimer: Timer?
    private var userDisconnected = false
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/QCYBar.log")

    override init() {
        super.init()
        try? Data().write(to: logURL)
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isConnected: Bool { status == .connected }

    /// Both buds were charging when the link dropped: they are in the case,
    /// where they switch their radio off until taken out.
    var isInCase: Bool {
        guard !isConnected, batteryIsLastKnown, let b = battery else { return false }
        return b.left?.charging == true && b.right?.charging == true
    }

    var ancScenes: [AncScene] { AncScene.scenes(forModel: model) }

    // MARK: - Commands

    func setAnc(_ s: AncSetting) {
        anc = s
        send(TLV(.anc, s.bytes))
        confirm(.anc, after: 1.5)
    }

    func setAiAnc(_ on: Bool) {
        aiAnc = on
        send(TLV(.aiAnc, [on ? 0x00 : 0x04, 0, 0, 0, 0, 1]))
        confirm(.aiAnc)
    }

    func setEq(_ preset: EqPreset) {
        eqPreset = preset.id
        let pad: Int
        if transport == .jieli {
            pad = 0 // the JieLi path sends at most ten bands, no padding
        } else {
            let maxLen = peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 182
            pad = max(preset.bands.count, min(20, (maxLen - 4 - 3) / 7))
        }
        send(TLV(.multiEq2, preset.payload(padTo: pad)))
    }

    func applyCustomEq() {
        setEq(EqPreset.custom(gains: customGains))
    }

    func setBalance(_ v: Int) {
        balance = v
        send(TLV(.balance, [UInt8(max(0, min(100, v)))]))
    }

    func setToggle(_ spec: ToggleSpec, _ on: Bool) {
        toggles[spec.cmd.rawValue] = on
        send(TLV(spec.cmd, [on ? spec.on : spec.off]))
        confirm(spec.cmd)
    }

    /// Game mode (command 0x4A, `[enabled, sync game EQ]`). Reboots the buds.
    func setGameMode(_ on: Bool) {
        gameMode = on
        send(TLV(.gameConfig, [on ? 1 : 0, on ? 1 : 0]))
    }

    func setPromptVolume(_ level: UInt8) {
        promptVolume = level
        send(TLV(.promptVolume, [level, 0]))
        confirm(.promptVolume)
    }

    /// Power off this many minutes after the phone/computer disconnects.
    func setAutoPowerOff(_ minutes: UInt16) {
        autoPowerOff = minutes
        send(TLV(.autoPowerOff, le(minutes)))
        confirm(.autoPowerOff)
    }

    /// Sleep timer; `0xFFFF` = off. Minutes 0 powers off immediately, so it
    /// is never used to cancel.
    func setPowerTimer(_ minutes: UInt16) {
        precondition(minutes > 0)
        powerTimer = minutes
        send(TLV(.powerOffTimer, le(minutes) + [0, 0]))
        confirm(.powerOffTimer)
    }

    /// Turns the earbuds off right away (the app's "Shut down" button).
    func powerOffNow() {
        send(TLV(.powerOffTimer, [0, 0, 0, 0]))
    }

    func setKey(_ g: Gesture, _ a: KeyAction) {
        keys[g.rawValue] = a.rawValue
        if transport == .qcy, let c = chars[UUIDs.keys] {
            enqueue(c, [g.rawValue, a.rawValue])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.read(UUIDs.keys) }
        } else {
            send(TLV(.keyFunctions, [g.rawValue, a.rawValue]))
            confirm(.keyFunctions)
        }
    }

    func rename(_ newName: String) {
        var bytes = Array(newName.utf8)
        if bytes.count > 32 { bytes = Array(bytes.prefix(32)) }
        guard !bytes.isEmpty else { return }
        name = newName
        send(TLV(.deviceName, bytes))
    }

    func reset(_ cmd: Cmd) {
        precondition([.resetDefault, .clearPairing, .factoryReset].contains(cmd))
        send(TLV(cmd))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() }
    }

    func startFitTest() {
        fitResult = nil
        send(TLV(.fitTest, [1, 1, 1]))
    }

    func stopFitTest() {
        send(TLV(.fitTest, [0, 0, 0]))
    }

    /// Reads every setting again.
    func refresh() {
        guard isConnected else { return }
        var requests: [Cmd] = [
            .anc, .aiAnc, .multiEq2, .balance, .gameConfig, .promptVolume, .autoPowerOff,
            .powerOffTimer, .deviceName,
        ] + ToggleSpec.all.map(\.cmd)
        switch transport {
        case .jieli:
            requests = [.battery, .version, .keyFunctions] + requests
        case .qcy:
            read(UUIDs.version)
            read(UUIDs.battery)
            read(UUIDs.settings)
            read(UUIDs.keys)
        }
        for r in requests { send(.request(r)) }
    }

    func reconnect() {
        userDisconnected = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
    }

    // MARK: - Plumbing

    private func send(_ tlv: TLV) {
        switch transport {
        case .qcy:
            guard let c = chars[UUIDs.command] else { return }
            enqueue(c, QCYFrame.encode([tlv]))
        case .jieli:
            guard let c = chars[UUIDs.rcspWrite] else { return }
            enqueue(c, rcsp.custom(tlv))
        }
    }

    private func confirm(_ cmd: Cmd, after delay: Double = 1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.send(.request(cmd))
        }
    }

    private func read(_ uuid: CBUUID) {
        guard let p = peripheral, let c = chars[uuid], c.properties.contains(.read) else { return }
        p.readValue(for: c)
    }

    private func enqueue(_ c: CBCharacteristic, _ data: [UInt8]) {
        queue.append((c, data))
        drain()
    }

    /// Writes one at a time with a small gap; the buds drop bursts.
    private func drain() {
        guard !draining, let p = peripheral, !queue.isEmpty else { return }
        draining = true
        let (c, data) = queue.removeFirst()
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(data), for: c, type: type)
        trace("→ \(c.uuid.uuidString.prefix(8)) \(hex(data))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.draining = false
            self?.drain()
        }
    }

    private func trace(_ s: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(s)"
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(Data((line + "\n").utf8))
            try? h.close()
        }
    }

    private func start() {
        guard central.state == .poweredOn, !userDisconnected else { return }
        status = .searching
        let known = central.retrieveConnectedPeripherals(withServices: [UUIDs.qcyService, UUIDs.jieliService])
        if let p = known.first {
            trace("already connected to the system: \(p.name ?? "?")")
            connect(p)
        } else {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        status = .connecting
        if name == nil { name = p.name }
        central.connect(p)
        // CoreBluetooth never gives up on its own; a bud that powered off
        // (or went back into the case) would leave us "connecting" forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak p] in
            guard let self, let p, self.peripheral === p, self.status == .connecting else { return }
            self.trace("connection timed out; searching again")
            self.central.cancelPeripheralConnection(p)
            self.peripheral = nil
            self.start()
        }
    }

    private func didFinishDiscovery() {
        guard peripheral != nil else { return }
        transport = chars[UUIDs.rcspWrite] != nil && chars[UUIDs.command] == nil ? .jieli : .qcy
        if chars[UUIDs.rcspWrite] != nil, let m = model, m & 0x80F0 == 0x8070 { transport = .jieli }
        trace("transport: \(transport == .jieli ? "JieLi RCSP (0xA002)" : "QCY (0xA001)")")
        status = .connected
        if transport == .jieli {
            rcsp = RCSP()
            for w in rcsp.hello(unixTime: UInt32(Date().timeIntervalSince1970)) {
                if let c = chars[UUIDs.rcspWrite] { enqueue(c, w) }
            }
        }
        refresh()
        if CommandLine.arguments.contains("--selftest") { selfTest() }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: transport == .jieli ? 20 : 60, repeats: true) { [weak self] _ in
            guard let self, self.isConnected else { return }
            if self.transport == .jieli {
                self.send(.request(.battery))
                self.send(.request(.anc))
            } else {
                self.read(UUIDs.battery)
            }
        }
    }

    /// `--selftest`: switches to adaptive ANC, checks the read-back, then
    /// restores the previous mode.
    private func selfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            let original = anc ?? .normal
            trace("selftest: original \(original.bytes)")
            setAnc(.anc(scene: 5))
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [self] in
                trace("selftest: read \(anc?.bytes ?? []) (expected [1, 5, 0])")
                setAnc(original)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                    trace("selftest: restored \(anc?.bytes ?? [])")
                }
            }
        }
    }

    private func handle(_ tlvs: [TLV]) {
        for t in tlvs { apply(t) }
    }

    private func apply(_ t: TLV) {
        let p = t.payload
        if let spec = ToggleSpec.all.first(where: { $0.cmd.rawValue == t.id }), let v = p.first {
            toggles[t.id] = v == spec.on
            return
        }
        guard let cmd = Cmd(rawValue: t.id) else { return }
        switch cmd {
        case .battery:
            if let b = Battery(p) { battery = b }
        case .anc where p.count >= 3:
            anc = AncSetting(mode: p[0], scene: p[1], level: p[2])
        case .aiAnc where !p.isEmpty:
            aiAnc = p[0] != 4
        case .multiEq2 where !p.isEmpty:
            eqPreset = p[0]
        case .balance where !p.isEmpty:
            balance = Int(p[0])
        case .promptVolume where !p.isEmpty:
            promptVolume = p[0]
        case .autoPowerOff where p.count >= 2:
            autoPowerOff = UInt16(p[0]) | UInt16(p[1]) << 8
        case .powerOffTimer where p.count >= 2:
            powerTimer = UInt16(p[0]) | UInt16(p[1]) << 8
        case .deviceName:
            let s = String(decoding: p.prefix { $0 != 0 }, as: UTF8.self)
            if !s.isEmpty { name = s }
        case .version where p.count >= 3:
            firmware = "\(p[0]).\(p[1]).\(p[2])"
        case .keyFunctions:
            parseKeys(p)
        case .gameConfig where !p.isEmpty:
            gameMode = p[0] == 1
        case .fitTest where p.count >= 3:
            if p[0] == 2 { fitResult = (p[1], p[2]) }
        default:
            break
        }
    }

    private func parseKeys(_ p: [UInt8]) {
        var k = keys
        var i = 0
        while i + 1 < p.count {
            if p[i] != 0 { k[p[i]] = p[i + 1] }
            i += 2
        }
        keys = k
    }
}

// MARK: - CBCentralManagerDelegate

extension Earbuds: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: start()
        case .unauthorized: status = .unauthorized
        default: status = .bluetoothOff
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        guard let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        let b = [UInt8](m)
        // Company id 0x521C (or 0x522C), little endian, then the model id
        // big endian and the battery of L / R / case at offsets 5…7.
        guard b.count >= 10, b[1] == 0x52, b[0] == 0x1C || b[0] == 0x2C else { return }
        let d = Array(b.dropFirst(2))
        model = UInt16(d[0]) << 8 | UInt16(d[1])
        if let bat = Battery(Array(d[5...7])) { battery = bat }
        name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        trace("found \(name ?? "?") model 0x\(String(format: "%04X", model!)) rssi \(rssi)")
        connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        trace("connected (BLE)")
        chars = [:]
        p.discoverServices([UUIDs.qcyService, UUIDs.jieliService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        trace("failed to connect: \(error?.localizedDescription ?? "-")")
        peripheral = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        // Late callback for a connection we already abandoned.
        guard peripheral === p else { return }
        trace("disconnected \(error?.localizedDescription ?? "")")
        pollTimer?.invalidate()
        peripheral = nil
        chars = [:]
        queue = []
        draining = false
        status = .searching
        batteryIsLastKnown = battery != nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }
}

// MARK: - CBPeripheralDelegate

extension Earbuds: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = (p.services ?? []).filter { $0.uuid == UUIDs.qcyService || $0.uuid == UUIDs.jieliService }
        guard !services.isEmpty else {
            trace("QCY control service not found")
            central.cancelPeripheralConnection(p)
            return
        }
        pendingServices = services.count
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        // Look characteristics up by their parent service: the OTA service
        // 0x7033 reuses 0x1001/0x1002 and must never be touched.
        for c in s.characteristics ?? [] {
            if s.uuid == UUIDs.qcyService || (s.uuid == UUIDs.jieliService && [UUIDs.rcspWrite, UUIDs.rcspNotify].contains(c.uuid)) {
                chars[c.uuid] = c
                if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
            }
        }
        pendingServices -= 1
        if pendingServices == 0 { didFinishDiscovery() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value else { return }
        let b = [UInt8](data)
        trace("← \(c.uuid.uuidString.prefix(8)) \(hex(b))")
        let service = c.service?.uuid
        switch (service, c.uuid) {
        case (UUIDs.qcyService, UUIDs.settings):
            handle(QCYFrame.decode(b))
        case (UUIDs.qcyService, UUIDs.battery):
            if let bat = Battery(b) { battery = bat }
        case (UUIDs.qcyService, UUIDs.version) where b.count >= 3:
            firmware = "\(b[0]).\(b[1]).\(b[2])"
        case (UUIDs.qcyService, UUIDs.keys):
            parseKeys(b)
        case (UUIDs.jieliService, UUIDs.rcspNotify):
            for f in rcsp.push(b) where f.status == 0 {
                if f.opcode == RCSP.Op.custom.rawValue {
                    handle(QCYFrame.decodeEntries(f.params))
                } else if f.opcode == RCSP.Op.targetInfo.rawValue, model == nil {
                    // Target info carries the company id followed by the model id.
                    let t = f.params
                    if let i = (0..<max(0, t.count - 3)).first(where: { t[$0] == 0x1C && t[$0 + 1] == 0x52 }) {
                        model = UInt16(t[i + 2]) << 8 | UInt16(t[i + 3])
                        trace("model 0x\(String(format: "%04X", model!))")
                    }
                }
            }
        default:
            break
        }
    }
}
