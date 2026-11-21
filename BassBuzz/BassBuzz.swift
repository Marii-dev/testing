import SwiftUI
import CoreHaptics

@main
struct BassBuzzApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

final class BassClient: ObservableObject {
    @Published var status = "Not connected"
    @Published var level: Double = 0
    private var engine: CHHapticEngine?
    private var bank: [CHHapticAdvancedPatternPlayer] = []   // pre-built beat players (low latency)
    private var rumble: CHHapticAdvancedPatternPlayer?       // continuous bass-following rumble
    private var task: URLSessionWebSocketTask?
    private var wantConnected = false
    private let d = UserDefaults.standard

    init() {
        d.register(defaults: ["gain": 1.0, "sharp": 0.2, "len": 0.07, "sens": 1.35,
                              "high": 150.0, "rumbleOn": true, "rumbleAmt": 0.5])
        setupEngine()
    }

    private func setupEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            status = "This device has no haptics"; return
        }
        do {
            engine = try CHHapticEngine()
            engine?.isAutoShutdownEnabled = false
            engine?.resetHandler = { [weak self] in try? self?.engine?.start(); self?.rebuild() }
            engine?.stoppedHandler = { [weak self] _ in try? self?.engine?.start() }
            try engine?.start()
            rebuild()
        } catch { status = "Haptic error: \(error.localizedDescription)" }
    }

    func rebuild() {
        guard let engine else { return }
        let sharp = Float(d.double(forKey: "sharp")), len = d.double(forKey: "len")
        bank = (1...6).compactMap { n in
            let i = Float(n) / 6
            let thump = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: i),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharp)], relativeTime: 0)
            let body = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: i * 0.85),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharp * 0.5)],
                relativeTime: 0, duration: len)
            return try? engine.makeAdvancedPlayer(with: CHHapticPattern(events: [thump, body], parameters: []))
        }
        let r = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)],
            relativeTime: 0, duration: 30)
        rumble = try? engine.makeAdvancedPlayer(with: CHHapticPattern(events: [r], parameters: []))
        rumble?.loopEnabled = true
    }

    private func pulse(_ level: Double) {
        guard !bank.isEmpty else { return }
        let i = min(1, level * d.double(forKey: "gain"))
        let p = bank[min(bank.count - 1, max(0, Int((i * 6).rounded(.up)) - 1))]
        try? p.stop(atTime: CHHapticTimeImmediate)
        try? p.start(atTime: CHHapticTimeImmediate)
    }

    private func setRumble(_ e: Double) {
        let v = d.bool(forKey: "rumbleOn") ? Float(min(1, e * d.double(forKey: "rumbleAmt") * 2)) : 0
        try? rumble?.sendParameters([CHHapticDynamicParameter(
            parameterID: .hapticIntensityControl, value: v, relativeTime: 0)], atTime: CHHapticTimeImmediate)
    }

    func sendConfig() {
        let cfg: [String: Double] = ["sens": d.double(forKey: "sens"), "low": 20, "high": d.double(forKey: "high")]
        guard let data = try? JSONSerialization.data(withJSONObject: ["cfg": cfg]),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    func connect(_ host: String) {
        disconnect()
        guard let url = URL(string: "ws://\(host)/ws") else { status = "Bad address"; return }
        wantConnected = true
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        status = "Listening for beats..."
        sendConfig()
        try? rumble?.start(atTime: CHHapticTimeImmediate)
        setRumble(0)
        listen(t, host)
    }

    func disconnect() {
        wantConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        try? rumble?.stop(atTime: CHHapticTimeImmediate)
        status = "Not connected"
    }

    private func listen(_ t: URLSessionWebSocketTask, _ host: String) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .success(let msg):
                if case .string(let s) = msg, let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let lv = obj["level"] as? Double { self.pulse(lv) }
                    if let e = obj["e"] as? Double {
                        self.setRumble(e)
                        DispatchQueue.main.async { self.level = e }
                    }
                }
                self.listen(t, host)
            case .failure:
                DispatchQueue.main.async { self.status = "Disconnected - retrying..." }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if self.wantConnected { self.connect(host) }
                }
            }
        }
    }
}

struct ContentView: View {
    @AppStorage("host") private var host = "192.168.88.16:8080"
    @AppStorage("gain") private var gain = 1.0
    @AppStorage("sharp") private var sharp = 0.2
    @AppStorage("len") private var len = 0.07
    @AppStorage("sens") private var sens = 1.35
    @AppStorage("high") private var high = 150.0
    @AppStorage("rumbleOn") private var rumbleOn = true
    @AppStorage("rumbleAmt") private var rumbleAmt = 0.5
    @StateObject private var client = BassClient()
    @State private var on = false

    var body: some View {
        Form {
            Section {
                TextField("PC address", text: $host)
                    .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                Button(on ? "Stop" : "Start") {
                    on.toggle()
                    UIApplication.shared.isIdleTimerDisabled = on
                    on ? client.connect(host) : client.disconnect()
                }
                .foregroundColor(on ? .red : .purple)
                ProgressView(value: client.level).tint(.green)
                Text(client.status).foregroundColor(.secondary)
            }
            Section("Beat hits") {
                slider("Strength", $gain, 0.3...2.0, "%.2fx")
                slider("Sharpness (soft ↔ crisp)", $sharp, 0...1, "%.2f")
                slider("Hit length", $len, 0.03...0.25, "%.2fs")
            }
            Section("Rumble (follows the bass)") {
                Toggle("Continuous rumble", isOn: $rumbleOn)
                slider("Rumble strength", $rumbleAmt, 0.1...1, "%.2f")
            }
            Section("Detection (applied on PC)") {
                slider("Sensitivity (lower = more beats)", $sens, 1.1...2.0, "%.2f")
                slider("Bass range up to", $high, 60...300, "%.0f Hz")
            }
        }
        .onChange(of: sharp) { _ in client.rebuild() }
        .onChange(of: len) { _ in client.rebuild() }
        .onChange(of: sens) { _ in client.sendConfig() }
        .onChange(of: high) { _ in client.sendConfig() }
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ f: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(String(format: f, v.wrappedValue))").font(.subheadline)
            Slider(value: v, in: r)
        }
    }
}
