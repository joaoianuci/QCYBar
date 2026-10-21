import Foundation
import CoreBluetooth

// QCY earbuds control protocol, reverse-engineered by the community
// (BrunoAssis/qcyx, hm-aktaruzzaman-mukdho/Orphion, hui1601/Quicky).
//
// Two transports exist:
// - "QCY" (WuQi/Realtek/generic chips): service 0xA001, write 0x1001,
//   notify/read 0x1002, frames `FF len {id n payload}...`.
// - "JieLi" (new JieLi chips): service 0xA002, write 0x0001, notify 0x0002,
//   RCSP frames `FE DC BA flags op lenBE body EF`; QCY TLVs travel inside
//   the custom opcode 0xFF.
// Both use the same setting ids, so the app only builds TLVs and the
// transport wraps them.

enum UUIDs {
    static let qcyService = CBUUID(string: "A001")
    static let jieliService = CBUUID(string: "A002")
    static let command = CBUUID(string: "1001")
    static let settings = CBUUID(string: "1002")
    static let battery = CBUUID(string: "00000008-0000-1000-8000-00805F9B34FB")
    static let version = CBUUID(string: "00000007-0000-1000-8000-00805F9B34FB")
    static let keys = CBUUID(string: "0000000D-0000-1000-8000-00805F9B34FB")
    static let rcspWrite = CBUUID(string: "00000001-0000-1000-8000-00805F9B34FB")
    static let rcspNotify = CBUUID(string: "00000002-0000-1000-8000-00805F9B34FB")
}

/// QCY setting ids.
enum Cmd: UInt8 {
    case resetDefault = 0x01
    case clearPairing = 0x02
    case factoryReset = 0x03
    case sleepMode = 0x10
    case fitTest = 0x11
    case powerOffTimer = 0x14
    case balance = 0x16
    case anc = 0x17
    case deviceName = 0x18
    case promptVolume = 0x1D
    case autoPowerOff = 0x1F
    case multiEq2 = 0x22
    case ldac = 0x23
    case dualDevice = 0x24
    case dynamicEq = 0x27
    case ancResult = 0x28
    case antiWind = 0x2A
    case keyFunctions = 0x2B
    case battery = 0x2F
    case version = 0x30
    case gameConfig = 0x4A
    case ecoMode = 0x53
    case aiAnc = 0x54
    case requestData = 0xFE
}

struct TLV: Equatable {
    var id: UInt8
    var payload: [UInt8]

    init(_ id: UInt8, _ payload: [UInt8] = []) {
        self.id = id
        self.payload = payload
    }

    init(_ cmd: Cmd, _ payload: [UInt8] = []) {
        self.init(cmd.rawValue, payload)
    }

    static func request(_ cmd: Cmd) -> TLV { TLV(.requestData, [cmd.rawValue]) }
}

enum QCYFrame {
    /// `FF len {id n payload}...`
    static func encode(_ tlvs: [TLV]) -> [UInt8] {
        var body: [UInt8] = []
        for t in tlvs {
            body.append(t.id)
            body.append(UInt8(t.payload.count))
            body += t.payload
        }
        return [0xFF, UInt8(body.count)] + body
    }

    static func decode(_ data: [UInt8]) -> [TLV] {
        guard data.count >= 4, data[0] == 0xFF else { return [] }
        let end = min(data.count, Int(data[1]) + 2)
        return decodeEntries(Array(data[2..<end]))
    }

    /// `{id n payload}...` without the frame header.
    static func decodeEntries(_ body: [UInt8]) -> [TLV] {
        var out: [TLV] = []
        var i = 0
        while i + 2 <= body.count {
            let id = body[i]
            let n = Int(body[i + 1])
            guard i + 2 + n <= body.count else { break }
            out.append(TLV(id, Array(body[(i + 2)..<(i + 2 + n)])))
            i += 2 + n
        }
        return out
    }
}

/// JieLi RCSP framing.
struct RCSP {
    static let header: [UInt8] = [0xFE, 0xDC, 0xBA]
    static let trailer: UInt8 = 0xEF

    enum Op: UInt8 {
        case targetInfo = 0x03
        case setAdv = 0xC0
        case custom = 0xFF
    }

    struct Frame {
        var opcode: UInt8
        var isCommand: Bool
        var status: UInt8
        var params: [UInt8]
    }

    private var sn: UInt8 = 0
    private var buffer: [UInt8] = []

    mutating func command(_ op: Op, _ params: [UInt8]) -> [UInt8] {
        let body = UInt16(1 + params.count)
        var out = RCSP.header
        out.append(0xC0) // command, response wanted
        out.append(op.rawValue)
        out.append(UInt8(body >> 8))
        out.append(UInt8(body & 0xFF))
        out.append(sn)
        out += params
        out.append(RCSP.trailer)
        sn &+= 1
        return out
    }

    /// One QCY TLV inside the custom opcode, without the `FF len` header.
    mutating func custom(_ tlv: TLV) -> [UInt8] {
        command(.custom, [tlv.id, UInt8(tlv.payload.count)] + tlv.payload)
    }

    /// Writes sent right after connecting: target info, then the clock.
    mutating func hello(unixTime: UInt32) -> [[UInt8]] {
        let t = withUnsafeBytes(of: unixTime.bigEndian) { Array($0) }
        return [
            command(.targetInfo, [0xFF, 0xFF, 0xFF, 0xFF, 0x00]),
            command(.setAdv, [UInt8(1 + t.count), 7] + t),
        ]
    }

    /// Feeds notification bytes; returns complete frames.
    mutating func push(_ data: [UInt8]) -> [Frame] {
        buffer += data
        var frames: [Frame] = []
        while true {
            guard let start = Self.findHeader(buffer) else {
                buffer = Array(buffer.suffix(2))
                break
            }
            buffer.removeFirst(start)
            guard buffer.count >= 7 else { break }
            let len = Int(buffer[5]) << 8 | Int(buffer[6])
            if len > 530 || len == 0 { buffer.removeFirst(); continue }
            let total = 7 + len + 1
            guard buffer.count >= total else { break }
            guard buffer[total - 1] == RCSP.trailer else { buffer.removeFirst(); continue }
            let flags = buffer[3]
            let body = Array(buffer[7..<(7 + len)])
            let isCommand = flags & 0x80 != 0
            if isCommand {
                frames.append(Frame(opcode: buffer[4], isCommand: true, status: 0, params: Array(body.dropFirst())))
            } else if body.count >= 2 {
                frames.append(Frame(opcode: buffer[4], isCommand: false, status: body[0], params: Array(body.dropFirst(2))))
            }
            buffer.removeFirst(total)
        }
        return frames
    }

    private static func findHeader(_ b: [UInt8]) -> Int? {
        guard b.count >= 3 else { return nil }
        for i in 0...(b.count - 3) where b[i] == 0xFE && b[i + 1] == 0xDC && b[i + 2] == 0xBA {
            return i
        }
        return nil
    }
}

// MARK: - Values

struct BudBattery: Equatable {
    var percent: Int
    var charging: Bool

    /// Bit 7 = charging, bits 0–6 = percent, 0 = unknown.
    init?(byte: UInt8) {
        let p = Int(byte & 0x7F)
        guard p > 0, p <= 100 else { return nil }
        percent = p
        charging = byte & 0x80 != 0
    }
}

struct Battery: Equatable {
    var left: BudBattery?
    var right: BudBattery?
    var caseBox: BudBattery?

    init?(_ p: [UInt8]) {
        guard p.count >= 3 else { return nil }
        left = BudBattery(byte: p[0])
        right = BudBattery(byte: p[1])
        caseBox = BudBattery(byte: p[2])
    }
}

/// Noise control triple `[mode, scene, level]` of command 0x17.
struct AncSetting: Equatable, Hashable {
    var mode: UInt8
    var scene: UInt8
    var level: UInt8

    static let normal = AncSetting(mode: 2, scene: 0, level: 0)
    static let transparencyVoice = AncSetting(mode: 3, scene: 2, level: 0)
    static func transparency(_ level: UInt8) -> AncSetting { AncSetting(mode: 3, scene: 1, level: level) }
    static func anc(scene: UInt8, level: UInt8 = 0) -> AncSetting { AncSetting(mode: 1, scene: scene, level: level) }

    var bytes: [UInt8] { [mode, scene, level] }

    enum Kind { case anc, transparency, normal }
    var kind: Kind {
        switch mode {
        case 1: return .anc
        case 3: return .transparency
        default: return .normal
        }
    }
}

/// Model-specific labels for the ANC scenes (from QCY's control panels).
struct AncScene: Identifiable, Hashable {
    var scene: UInt8
    var name: String
    var levels: Int // 0 = no level choice

    var id: UInt8 { scene }

    static func scenes(forModel model: UInt16?) -> [AncScene] {
        // The JieLi A30 panel (0x8076) swaps the Indoor and Noisy labels
        // compared to the generic A30 panel (0x4D5D).
        let jieliA30 = model == 0x8076 || model == 0x807D
        return [
            AncScene(scene: 5, name: "Adaptive", levels: 0),
            AncScene(scene: jieliA30 ? 3 : 1, name: "Indoor", levels: 3),
            AncScene(scene: 2, name: "Commuting", levels: 3),
            AncScene(scene: jieliA30 ? 1 : 3, name: "Noisy", levels: 3),
            AncScene(scene: 4, name: "Wind reduction", levels: 0),
        ]
    }
}

enum Gesture: UInt8, CaseIterable, Identifiable {
    case leftSingle = 1, rightSingle = 2, leftDouble = 3, rightDouble = 4
    case leftTriple = 5, rightTriple = 6, leftLong = 9, rightLong = 10

    var id: UInt8 { rawValue }
    var isLeft: Bool { rawValue % 2 == 1 }
    var label: String {
        switch self {
        case .leftSingle, .rightSingle: return "Tap"
        case .leftDouble, .rightDouble: return "Double tap"
        case .leftTriple, .rightTriple: return "Triple tap"
        case .leftLong, .rightLong: return "Long press"
        }
    }
}

enum KeyAction: UInt8, CaseIterable, Identifiable {
    case none = 0, playPause = 1, previous = 2, next = 3, assistant = 4
    case volumeUp = 5, volumeDown = 6, gameMode = 7, ancCycle = 11

    var id: UInt8 { rawValue }
    var label: String {
        switch self {
        case .none: return "Nothing"
        case .playPause: return "Play/Pause"
        case .previous: return "Previous track"
        case .next: return "Next track"
        case .assistant: return "Voice assistant"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .gameMode: return "Game mode"
        case .ancCycle: return "Cycle noise mode"
        }
    }
}

/// On/off settings shown as switches, with the bytes the A30 panel uses.
struct ToggleSpec: Identifiable {
    var cmd: Cmd
    var title: String
    var help: String?
    var on: UInt8 = 1
    var off: UInt8 = 0
    var restarts = false

    var id: UInt8 { cmd.rawValue }

    static let all: [ToggleSpec] = [
        ToggleSpec(cmd: .antiWind, title: "Wind noise reduction"),
        ToggleSpec(cmd: .ecoMode, title: "Eco mode", help: "Turns noise cancelling off at low battery"),
        ToggleSpec(cmd: .dynamicEq, title: "Dynamic EQ"),
        ToggleSpec(cmd: .sleepMode, title: "Sleep mode", help: "Disables touch until back in the case", on: 1, off: 2),
        ToggleSpec(cmd: .dualDevice, title: "Multipoint", help: "Connect up to 3 devices"),
        ToggleSpec(cmd: .ldac, title: "LDAC", help: "Restarts the earbuds and turns multipoint off", restarts: true),
    ]
}

// MARK: - Equalizer

struct EqBand {
    var freq: UInt16
    var gain: Double
    var q: Double
    var type: UInt8
}

struct EqPreset: Identifiable, Hashable {
    var id: UInt8
    var name: String

    static func == (a: EqPreset, b: EqPreset) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var masterGain: Double
    var bands: [EqBand]

    static let customID: UInt8 = 255
    static let graphicFrequencies: [UInt16] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private static func make(_ id: UInt8, _ name: String, _ master: Double, _ eqs: [Double], _ q: [Double], _ freq: [UInt16], _ types: [UInt8]) -> EqPreset {
        let bands = (0..<eqs.count).map { EqBand(freq: freq[$0], gain: eqs[$0], q: q[$0], type: types[$0]) }
        return EqPreset(id: id, name: name, masterGain: master, bands: bands)
    }

    /// Presets of the MeloBuds A30 control panel (model 19805 / 32886).
    static let a30: [EqPreset] = [
        make(1, "Default", -15, [-11, -15, -3, -2, 12.5, 3, 6], [0.8, 0.6, 1, 1, 0.8, 3, 1.5], [20, 160, 750, 350, 2900, 8000, 10000], [2, 2, 2, 2, 2, 2, 5]),
        make(10, "Spatial sound", -8.5, [-11, -15, -3, -2, 12.5, 3, 6], [0.8, 0.6, 1, 1, 0.8, 3, 1.5], [20, 160, 750, 350, 2900, 8000, 10000], [2, 2, 2, 2, 2, 2, 5]),
        make(2, "Pop", -15, [-11, -15, -3, -2, 12.5, 3, 6, -4], [0.8, 0.45, 1, 1, 0.8, 3, 1.5, 0.5], [20, 160, 750, 350, 2900, 8000, 10000, 55], [2, 2, 2, 2, 2, 2, 5, 2]),
        make(3, "Heavy bass", -15, [-6, -12, -2, -1, 9.5, 1.5, 3.5], [0.8, 0.6, 1, 1, 0.8, 3, 1.5], [20, 160, 750, 350, 2900, 8000, 10000], [2, 2, 2, 2, 2, 2, 5]),
        make(4, "Rock", -15, [-4, -17, -3, -2, 12.5, 6, 6], [0.8, 0.9, 1, 1, 0.8, 1.5, 1.5], [20, 160, 750, 350, 2900, 8000, 10000], [2, 2, 2, 2, 2, 2, 5]),
        make(5, "Soft", -15, [-14, -15, -3, -2, 9, 2, 6], [0.45, 0.6, 1, 1, 0.8, 3, 1.5], [20, 160, 750, 350, 2900, 8000, 10000], [2, 2, 2, 2, 2, 2, 5]),
        make(6, "Classical", -15, [-1, -9, -3, -2, 12.5, 3, 6], [0.6, 0.5, 1, 1, 0.8, 3, 1.5], [20, 160, 750, 350, 2900, 8000, 10000], [2, 2, 2, 2, 2, 2, 5]),
        make(13, "Game", -15, [-14, -15, -3, -2, 12.5, 2.5, 2, 4, 2], [0.45, 0.6, 1, 1, 0.8, 3, 1.5, 2, 1], [20, 160, 750, 350, 2900, 8000, 10000, 12275, 1750], [2, 2, 2, 2, 2, 2, 5, 2, 2]),
    ]

    /// 10-band user curve (gains −8…+8 dB), as the app builds it.
    static func custom(gains: [Double]) -> EqPreset {
        let bands = zip(graphicFrequencies, gains).map { EqBand(freq: $0, gain: min(8, max(-8, $1)), q: 0.7, type: 2) }
        return EqPreset(id: customID, name: "Custom", masterGain: autoMasterGain(bands, volumeLevel: 0), bands: bands)
    }

    /// Payload of command 0x22: index, master i16 LE (dB×100, truncated),
    /// then `{freq u16, gain i16 (dB×100), q u16 (×100), type}` per band,
    /// padded with unused bands up to `padTo`.
    func payload(padTo: Int) -> [UInt8] {
        var out: [UInt8] = [id]
        out += le(Int16(masterGain * 100))
        var all = bands
        while all.count < padTo { all.append(EqBand(freq: 0, gain: 0, q: 0, type: 255)) }
        for b in all {
            out += le(b.freq)
            out += le(Int16((b.gain * 100).rounded()))
            out += le(UInt16((b.q * 100).rounded()))
            out.append(b.type)
        }
        return out
    }

    /// Port of `QCYConnectManager.getMaxGain`: lowers the master gain so a
    /// boosted user curve does not clip.
    static func autoMasterGain(_ bands: [EqBand], volumeLevel: Double, base: Double = 0) -> Double {
        let fs = 44_100.0
        let filters: [([Double], [Double])] = bands.filter { $0.freq > 0 }.map { b in
            let w0 = 2 * Double.pi * Double(b.freq) / fs
            let alpha = sin(w0) / (2 * b.q)
            let a = pow(10, b.gain / 40)
            let c = cos(w0)
            return ([1 + alpha * a, -2 * c, 1 - alpha * a], [1 + alpha / a, -2 * c, 1 - alpha / a])
        }
        var peak = 0.0
        var peakFreq = 0
        var i = 0
        for f in stride(from: 20, through: 20_000, by: 5) {
            let w = (Double(f) * 20_000 + 1) * Double.pi / (fs * 10_000)
            var total = 0.0
            for (bc, ac) in filters {
                func mag(_ k: [Double]) -> Double {
                    let re = k[0] + k[1] * cos(w) + k[2] * cos(2 * w)
                    let im = -k[1] * sin(w) - k[2] * sin(2 * w)
                    return (re * re + im * im).squareRoot()
                }
                total += 20 * log10(mag(bc) / mag(ac))
            }
            if total > peak { peak = total; peakFreq = i * 5 }
            i += 1
        }
        peak += 0.5
        let limit: Double
        if peak > volumeLevel && peakFreq < 1500 {
            limit = volumeLevel
        } else if peak > volumeLevel + 4 && peakFreq >= 1500 {
            limit = volumeLevel + 4
        } else {
            return base
        }
        return base + (limit - peak)
    }
}

func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
    withUnsafeBytes(of: v.littleEndian) { Array($0) }
}

func hex(_ b: [UInt8]) -> String {
    b.map { String(format: "%02x", $0) }.joined(separator: " ")
}
