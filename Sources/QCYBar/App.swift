import SwiftUI
import AppKit
import AVFoundation

@main
struct QCYBarApp: App {
    @StateObject private var buds = Earbuds()

    var body: some Scene {
        MenuBarExtra {
            ControlPanel()
                .environmentObject(buds)
        } label: {
            MenuBarLabel(buds: buds)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var buds: Earbuds

    var body: some View {
        let symbol: String = {
            guard buds.isConnected else { return "earbuds" }
            switch buds.anc?.kind {
            case .anc: return "earbuds.case.fill"
            case .transparency: return "ear.badge.waveform"
            default: return "earbuds"
            }
        }()
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if buds.isConnected, let p = lowestBattery(buds.battery) {
                Text("\(p)%").monospacedDigit()
            }
        }
    }

    private func lowestBattery(_ b: Battery?) -> Int? {
        [b?.left?.percent, b?.right?.percent].compactMap { $0 }.min()
    }
}

// MARK: - Panel

struct ControlPanel: View {
    @EnvironmentObject var buds: Earbuds

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header()
                .padding(14)
            Divider()
            if buds.isConnected {
                NoiseSection()
                    .padding(14)
                Divider()
                // Everything else opens in its own popover beside the panel,
                // so the panel never needs to scroll.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    Tile(icon: "slider.vertical.3", title: L("Equalizer"), subtitle: eqSummary) { EqSection() }
                    Tile(icon: "dial.medium", title: L("Balance"), subtitle: balanceSummary) { BalanceSection() }
                    Tile(icon: "switch.2", title: L("Features"), subtitle: featuresSummary) { FeaturesSection() }
                    Tile(icon: "hand.tap", title: L("Touch"), subtitle: L("L/R gestures")) { TouchSection() }
                    Tile(icon: "bolt.badge.clock", title: L("Power & sounds"), subtitle: powerSummary) { PowerSection() }
                    Tile(icon: "gearshape", title: L("Advanced"), subtitle: L("Fit, name, reset")) { AdvancedSection() }
                }
                .padding(12)
            } else {
                Disconnected()
                    .padding(14)
            }
            Divider()
            HStack(spacing: 14) {
                Button(L("Reconnect")) { buds.reconnect() }
                if buds.isConnected {
                    Button {
                        if confirm(L("Turn the earbuds off now? To turn them on again, put them in the case and take them out."), L("Turn off")) {
                            buds.powerOffNow()
                        }
                    } label: {
                        Label(L("Turn off earbuds"), systemImage: "power")
                    }
                }
                Spacer()
                Button(L("Quit")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { WindowFitter(height: $0.size.height) })
    }

    private var eqSummary: String {
        guard let id = buds.eqPreset else { return "–" }
        if id == EqPreset.customID { return L("Custom") }
        return EqPreset.a30.first { $0.id == id }.map { L($0.name) } ?? String(format: L("Preset %d"), Int(id))
    }

    private var balanceSummary: String {
        guard let b = buds.balance else { return "–" }
        if b == 50 { return L("Centered") }
        return b < 50 ? L("Toward left") : L("Toward right")
    }

    private var featuresSummary: String {
        let on = ToggleSpec.all.filter { buds.toggles[$0.cmd.rawValue] == true }.count + (buds.gameMode == true ? 1 : 0)
        return on == 0 ? L("None on") : on == 1 ? L("1 on") : String(format: L("%d on"), on)
    }

    private var powerSummary: String {
        if let t = buds.powerTimer, t != 0xFFFF { return String(format: L("Off in %d min"), Int(t)) }
        return L("Timer off")
    }
}

/// The MenuBarExtra window keeps the height the panel had before it shrank
/// (connected → buds back in the case), leaving a see-through band above the
/// content. Snap the window to the content, keeping its top under the menu bar,
/// whenever the content changes size and each time the panel is opened.
struct WindowFitter: NSViewRepresentable {
    var height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.height = height
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var height: CGFloat = 0
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if window !== self.window {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                self.window = window
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in self?.fit() }
            }
            fit()
        }

        private func fit() {
            guard let window, height > 0 else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.height - height) > 0.5 else { return }
            let fitted = NSRect(x: content.minX, y: content.maxY - height, width: content.width, height: height)
            window.setFrame(window.frameRect(forContentRect: fitted), display: true)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// A button in the panel grid that opens its section in a popover.
struct Tile<Content: View>: View {
    @EnvironmentObject var buds: Earbuds
    var icon: String
    var title: String
    var subtitle: String
    @ViewBuilder var content: () -> Content
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(open || hover ? Color.primary.opacity(0.1) : Color.primary.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .popover(isPresented: $open, arrowEdge: .leading) {
            content()
                .environmentObject(buds)
                .padding(16)
                .frame(width: 300)
        }
    }
}

struct Header: View {
    @EnvironmentObject var buds: Earbuds

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            if let b = buds.battery {
                HStack(spacing: 14) {
                    BatteryChip(label: L("L"), value: b.left)
                    BatteryChip(label: L("R"), value: b.right)
                    BatteryChip(label: L("Case"), value: b.caseBox)
                }
                .opacity(buds.batteryIsLastKnown ? 0.55 : 1)
                .help(buds.batteryIsLastKnown ? L("Last reading before the earbuds disconnected") : "")
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "earbuds")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(buds.name ?? "QCY MeloBuds").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if buds.isConnected {
                Button {
                    buds.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L("Read settings again"))
            }
        }
    }

    private var statusText: String {
        switch buds.status {
        case .bluetoothOff: return L("Bluetooth is off")
        case .unauthorized: return L("No Bluetooth permission")
        case .searching where buds.isInCase: return L("In the case · charging")
        case .searching: return L("Looking for the earbuds…")
        case .connecting: return L("Connecting…")
        case .connected:
            var s = L("Connected")
            if let f = buds.firmware { s += " · " + String(format: L("firmware %@"), f) }
            return s
        }
    }
}

struct BatteryChip: View {
    var label: String
    var value: BudBattery?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(value.map { "\(label) \($0.percent)%" } ?? "\(label) –")
                .font(.caption)
                .monospacedDigit()
        }
    }

    private var icon: String {
        guard let v = value else { return "battery.0percent" }
        if v.charging { return "battery.100percent.bolt" }
        switch v.percent {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var color: Color {
        guard let v = value else { return .secondary }
        return v.percent < 20 && !v.charging ? .red : .primary
    }
}

struct Disconnected: View {
    @EnvironmentObject var buds: Earbuds

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: message.icon)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(message.title).font(.callout.weight(.medium))
                if let d = message.detail {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var message: (icon: String, title: String, detail: String?) {
        switch buds.status {
        case .unauthorized:
            return ("lock.shield", L("No Bluetooth permission"), L("Allow Bluetooth access in System Settings › Privacy & Security › Bluetooth."))
        case .bluetoothOff:
            return ("bolt.horizontal.circle", L("Bluetooth is off"), L("Turn Bluetooth on in Control Center."))
        case .connecting:
            return ("antenna.radiowaves.left.and.right", L("Connecting…"), nil)
        default:
            if buds.isInCase {
                return ("earbuds.case", L("Earbuds in the case"), L("Take them out to control them: they switch Bluetooth off while charging."))
            }
            return ("magnifyingglass", L("Earbuds not found"), L("Take them out of the case. If they still do not connect, close the QCY app on your phone: the earbuds accept only one controller at a time."))
        }
    }
}

struct PanelSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Noise control

struct NoiseSection: View {
    @EnvironmentObject var buds: Earbuds
    @State private var lastAnc = AncSetting.anc(scene: 5)
    @State private var lastTransparency = AncSetting.transparency(4)

    var body: some View {
        PanelSection(title: L("Noise control")) {
            Picker("", selection: kindBinding) {
                Text(L("Noise cancelling")).tag(AncSetting.Kind.anc)
                Text(L("Ambient")).tag(AncSetting.Kind.transparency)
                Text(L("Normal")).tag(AncSetting.Kind.normal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let a = buds.anc, a.kind == .anc {
                ancOptions(a)
            } else if let a = buds.anc, a.kind == .transparency {
                transparencyOptions(a)
            }

            Toggle(L("AI scene noise cancelling"), isOn: Binding(
                get: { buds.aiAnc ?? false },
                set: { buds.setAiAnc($0) }
            ))
            .help(L("Switches the mode automatically for your surroundings"))
        }
    }

    private var kindBinding: Binding<AncSetting.Kind> {
        Binding(
            get: { buds.anc?.kind ?? .normal },
            set: { k in
                if let a = buds.anc {
                    if a.kind == .anc { lastAnc = a }
                    if a.kind == .transparency { lastTransparency = a }
                }
                switch k {
                case .anc: buds.setAnc(lastAnc)
                case .transparency: buds.setAnc(lastTransparency)
                case .normal: buds.setAnc(.normal)
                }
            }
        )
    }

    @ViewBuilder
    private func ancOptions(_ a: AncSetting) -> some View {
        let scenes = buds.ancScenes
        Picker(L("Scene"), selection: Binding(
            get: { a.scene },
            set: { s in
                let level = scenes.first { $0.scene == s }?.levels ?? 0 > 0 ? min(a.level, 2) : 0
                buds.setAnc(.anc(scene: s, level: level))
            }
        )) {
            ForEach(scenes) { Text(L($0.name)).tag($0.scene) }
        }
        if let scene = scenes.first(where: { $0.scene == a.scene }), scene.levels > 0 {
            Picker(L("Strength"), selection: Binding(
                get: { a.level },
                set: { buds.setAnc(.anc(scene: a.scene, level: $0)) }
            )) {
                Text(L("Light")).tag(UInt8(0))
                Text(L("Medium")).tag(UInt8(1))
                Text(L("Strong")).tag(UInt8(2))
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func transparencyOptions(_ a: AncSetting) -> some View {
        let voice = a.scene == 2
        Toggle(L("Voice focus"), isOn: Binding(
            get: { voice },
            set: { $0 ? buds.setAnc(.transparencyVoice) : buds.setAnc(.transparency(4)) }
        ))
        if !voice {
            HStack {
                Text(L("Ambient sound"))
                Slider(value: Binding(
                    get: { Double(max(1, a.level)) },
                    set: { buds.setAnc(.transparency(UInt8($0.rounded()))) }
                ), in: 1...6, step: 1)
                Text("\(max(1, a.level))").monospacedDigit().frame(width: 14)
            }
        }
    }
}

// MARK: - EQ

struct EqSection: View {
    @EnvironmentObject var buds: Earbuds
    @State private var showCustom = false

    var body: some View {
        PanelSection(title: L("Equalizer")) {
            Picker(L("Preset"), selection: Binding(
                get: { buds.eqPreset ?? 1 },
                set: { id in
                    if id == EqPreset.customID {
                        showCustom = true
                        buds.applyCustomEq()
                    } else if let p = EqPreset.a30.first(where: { $0.id == id }) {
                        buds.setEq(p)
                    }
                }
            )) {
                ForEach(EqPreset.a30) { Text(L($0.name)).tag($0.id) }
                Divider()
                Text(L("Custom")).tag(EqPreset.customID)
            }
            DisclosureGroup(L("Manual (10 bands)"), isExpanded: $showCustom) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<10, id: \.self) { i in
                        VStack(spacing: 2) {
                            Text(String(format: "%+.0f", buds.customGains[i]))
                                .font(.system(size: 9)).monospacedDigit()
                            Slider(value: $buds.customGains[i], in: -8...8, step: 1) { editing in
                                if !editing { buds.applyCustomEq() }
                            }
                            .rotationEffect(.degrees(-90))
                            .frame(width: 90, height: 24)
                            .frame(width: 26, height: 90)
                            Text(freqLabel(EqPreset.graphicFrequencies[i]))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(L("Reset")) {
                        buds.customGains = Array(repeating: 0, count: 10)
                        buds.applyCustomEq()
                    }
                }
            }
            .font(.callout)
        }
    }

    private func freqLabel(_ f: UInt16) -> String {
        f >= 1000 ? "\(f / 1000)k" : "\(f)"
    }
}

struct BalanceSection: View {
    @EnvironmentObject var buds: Earbuds
    @State private var value: Double = 50

    var body: some View {
        PanelSection(title: L("Balance")) {
            HStack {
                Text(L("L"))
                Slider(value: $value, in: 0...100, step: 1) { editing in
                    if !editing { buds.setBalance(Int(value)) }
                }
                Text(L("R"))
                Button(L("Center")) {
                    value = 50
                    buds.setBalance(50)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .onAppear { value = Double(buds.balance ?? 50) }
        .onChange(of: buds.balance) { _, v in value = Double(v ?? 50) }
    }
}

// MARK: - Features

struct FeaturesSection: View {
    @EnvironmentObject var buds: Earbuds

    var body: some View {
        PanelSection(title: L("Features")) {
            Toggle(isOn: Binding(
                get: { buds.gameMode ?? false },
                set: { on in
                    if confirm(L("Changing game mode restarts the earbuds."), L("Continue")) { buds.setGameMode(on) }
                }
            )) {
                Label(L("Game mode (low latency)"), systemImage: "gamecontroller")
            }
            ForEach(ToggleSpec.all) { spec in
                Toggle(isOn: Binding(
                    get: { buds.toggles[spec.cmd.rawValue] ?? false },
                    set: { on in
                        if !spec.restarts || confirm(L(spec.help ?? "The earbuds will restart."), L("Continue")) {
                            buds.setToggle(spec, on)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L(spec.title))
                        if let h = spec.help {
                            Text(L(h)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

struct TouchSection: View {
    @EnvironmentObject var buds: Earbuds
    var body: some View {
        PanelSection(title: L("Touch controls")) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text(L("Left")).font(.caption).foregroundStyle(.secondary)
                    Text(L("Right")).font(.caption).foregroundStyle(.secondary)
                }
                row(.leftSingle, .rightSingle)
                row(.leftDouble, .rightDouble)
                row(.leftTriple, .rightTriple)
                row(.leftLong, .rightLong)
            }
        }
    }

    private func row(_ l: Gesture, _ r: Gesture) -> some View {
        GridRow {
            Text(L(l.label)).font(.callout)
            picker(l)
            picker(r)
        }
    }

    private func picker(_ g: Gesture) -> some View {
        Picker("", selection: Binding(
            get: { KeyAction(rawValue: buds.keys[g.rawValue] ?? 0) ?? .none },
            set: { buds.setKey(g, $0) }
        )) {
            ForEach(KeyAction.allCases) { Text(L($0.label)).tag($0) }
        }
        .labelsHidden()
        .controlSize(.small)
    }
}

// MARK: - Power

struct PowerSection: View {
    @EnvironmentObject var buds: Earbuds

    private let timers: [(UInt16, String)] = [(0xFFFF, "Off"), (15, "15 min"), (30, "30 min"), (60, "1 hour"), (90, "1.5 hours")]
    private let standby: [(UInt16, String)] = [(5, "5 min"), (10, "10 min"), (30, "30 min"), (60, "1 hour"), (0xFFFF, "Never")]
    private let beeps: [(UInt8, String)] = [(3, "Minimum"), (4, "Medium"), (7, "High"), (9, "Maximum")]

    var body: some View {
        PanelSection(title: L("Power & sounds")) {
            Picker(L("Turn off in"), selection: Binding(
                get: { timers.contains { $0.0 == buds.powerTimer } ? buds.powerTimer! : 0xFFFF },
                set: { buds.setPowerTimer($0) }
            )) {
                ForEach(timers, id: \.0) { Text(L($0.1)).tag($0.0) }
            }
            Picker(L("When disconnected, turn off after"), selection: Binding(
                get: { buds.autoPowerOff ?? 5 },
                set: { buds.setAutoPowerOff($0) }
            )) {
                ForEach(standby, id: \.0) { Text(L($0.1)).tag($0.0) }
            }
            Picker(L("Prompt volume"), selection: Binding(
                get: { buds.promptVolume ?? 7 },
                set: { buds.setPromptVolume($0) }
            )) {
                ForEach(beeps, id: \.0) { Text(L($0.1)).tag($0.0) }
            }
        }
    }
}

// MARK: - Advanced

struct AdvancedSection: View {
    @EnvironmentObject var buds: Earbuds
    @StateObject private var fit = FitTestPlayer()
    @State private var newName = ""

    var body: some View {
        PanelSection(title: L("Advanced")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(fit.playing ? L("Testing…") : L("Fit test")) {
                        buds.startFitTest()
                        fit.play { buds.stopFitTest() }
                    }
                    .disabled(fit.playing)
                    if let r = buds.fitResult {
                        Text("\(L("L")): \(fitLabel(r.left)) · \(L("R")): \(fitLabel(r.right))").font(.caption)
                    }
                }
                HStack {
                    TextField(L("New name"), text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button(L("Rename")) {
                        buds.rename(newName)
                        newName = ""
                    }
                    .disabled(newName.isEmpty)
                }
                HStack {
                    Button(L("Restore defaults")) {
                        if confirm(L("Restore touch controls and equalizer to their defaults?"), L("Restore")) { buds.reset(.resetDefault) }
                    }
                    Button(L("Clear pairings")) {
                        if confirm(L("Clear paired devices? The earbuds will disconnect from everything, including this Mac."), L("Clear")) { buds.reset(.clearPairing) }
                    }
                }
                Button(L("Factory reset"), role: .destructive) {
                    if confirm(L("Reset the earbuds to factory settings?"), L("Reset")) { buds.reset(.factoryReset) }
                }
                DisclosureGroup(L("Diagnostics (BLE traffic)")) {
                    ScrollView {
                        Text(buds.log.suffix(60).joined(separator: "\n"))
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                }
            }
            .controlSize(.small)
        }
    }

    private func fitLabel(_ v: UInt8) -> String {
        switch v {
        case 3: return L("good")
        case 1, 2: return L("poor")
        default: return L("failed")
        }
    }
}

/// Plays a short test sound through the earbuds while they measure the seal.
final class FitTestPlayer: ObservableObject {
    @Published var playing = false
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    init() {
        engine.attach(node)
    }

    func play(done: @escaping () -> Void) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.connect(node, to: engine.mainMixerNode, format: format)
        let seconds = 6.0
        let frames = AVAudioFrameCount(44_100 * seconds)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        // A slow 100 Hz → 1 kHz sweep at moderate volume.
        var phase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / 44_100
            let f = 100 * pow(10, t / seconds)
            phase += 2 * .pi * f / 44_100
            let s = Float(sin(phase) * 0.25)
            buf.floatChannelData![0][i] = s
            buf.floatChannelData![1][i] = s
        }
        do { try engine.start() } catch { return }
        playing = true
        node.scheduleBuffer(buf) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.playing = false
                self?.engine.stop()
                done()
            }
        }
        node.play()
    }
}

/// Modal confirmation; MenuBarExtra windows cannot host sheets reliably.
func confirm(_ message: String, _ ok: String) -> Bool {
    let a = NSAlert()
    a.messageText = message
    a.addButton(withTitle: ok)
    a.addButton(withTitle: L("Cancel"))
    NSApp.activate(ignoringOtherApps: true)
    return a.runModal() == .alertFirstButtonReturn
}

/// Localized UI text. English is the source language; translations live in
/// `Resources/<lang>.lproj/Localizable.strings` (pt-BR, es), and macOS picks
/// one from the user's preferred languages.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}
