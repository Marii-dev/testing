import SwiftUI
import CoreHaptics
import AVFoundation

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
    private var tapBank: [CHHapticAdvancedPatternPlayer] = []  // ASMR taps/clicks
    private var slide: CHHapticAdvancedPatternPlayer?          // ASMR slide/scrape texture
    private var task: URLSessionWebSocketTask?
    private var wantConnected = false
    private var running = false
    private let d = UserDefaults.standard

    init() {
        d.register(defaults: ["gain": 1.0, "sharp": 0.2, "len": 0.07, "sens": 1.35,
                              "high": 150.0, "rumbleOn": true, "rumbleAmt": 0.5,
                              "fx": 0, "asens": 1.6, "asmrAmt": 0.7])
        setupEngine()
    }

    private func setupEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            status = "This device has no haptics"; return
        }
        do {
            engine = try CHHapticEngine()
            engine?.isAutoShutdownEnabled = false
            engine?.playsHapticsOnly = true   // no audio, so the mic session can't interrupt it
            engine?.resetHandler = { [weak self] in try? self?.engine?.start(); self?.rebuild() }
            engine?.stoppedHandler = { [weak self] r in
                DispatchQueue.main.async { self?.status = "Haptic engine stopped (reason \(r.rawValue)), restarting..." }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let self else { return }
                    try? self.engine?.start()
                    self.rebuild()                       // players must be rebuilt after a stop
                    if self.running { self.startLoops() }
                }
            }
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
        tapBank = (1...4).compactMap { n in
            let ev = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(n) / 4),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)], relativeTime: 0)
            return try? engine.makeAdvancedPlayer(with: CHHapticPattern(events: [ev], parameters: []))
        }
        let sl = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)],
            relativeTime: 0, duration: 30)
        slide = try? engine.makeAdvancedPlayer(with: CHHapticPattern(events: [sl], parameters: []))
        slide?.loopEnabled = true
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

    // MARK: - Phone mic mode (listens to music playing on this iPhone)
    private let audio = AVAudioEngine()
    private var lp1: Float = 0, lp2: Float = 0
    private var avg: Float = 0, peak: Float = 1e-4, cool = 0, tickN = 0, sr: Float = 48000

    func startMic() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] ok in
            guard let self else { return }
            guard ok else { DispatchQueue.main.async { self.status = "Microphone access denied" }; return }
            do {
                let s = AVAudioSession.sharedInstance()
                try s.setCategory(.playAndRecord, mode: .measurement,
                                  options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
                try s.setAllowHapticsAndSystemSoundsDuringRecording(true)   // iOS mutes haptics while recording otherwise
                try s.setPreferredIOBufferDuration(0.005)
                try s.setActive(true)
                self.engine?.stop(completionHandler: nil)
                try self.engine?.start()
                self.rebuild()
                let input = self.audio.inputNode
                let fmt = input.outputFormat(forBus: 0)
                self.sr = Float(fmt.sampleRate)
                let a = 1 - exp(-2 * Float.pi * Float(self.d.double(forKey: "high")) / self.sr)
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 512, format: fmt) { [weak self] buf, _ in
                    self?.process(buf, a)
                }
                try self.audio.start()
                self.running = true
                self.startLoops()
                DispatchQueue.main.async { self.status = "Listening via microphone..." }
            } catch {
                DispatchQueue.main.async { self.status = "Mic error: \(error.localizedDescription)" }
            }
        }
    }

    func stopMic() {
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        running = false
        stopLoops()
        status = "Not connected"
    }

    private func process(_ buf: AVAudioPCMBuffer, _ a: Float) {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in 0..<n {                       // two-pole low-pass = bass only
            lp1 += a * (ch[i] - lp1)
            lp2 += a * (lp1 - lp2)
            sum += lp2 * lp2
        }
        let e = (sum / Float(n)).squareRoot()
        peak = max(peak * 0.9995, e)
        avg += 0.05 * (e - avg)
        if cool > 0 { cool -= 1 }
        tickN += 1
        if tickN % 2 == 0 {
            let r = min(1, e / peak)
            setRumble(Double(r * r))
            DispatchQueue.main.async { self.level = Double(r) }
        }
        if cool == 0, e > 0.0003, e > avg * Float(d.double(forKey: "sens")) {
            pulse(Double(min(1, max(0.35, powf(e / peak, 0.7)))))
            cool = max(1, Int(0.09 * sr / Float(n)))
        }
    }

    private func tap(_ level: Double) {
        guard !tapBank.isEmpty else { return }
        let i = min(1, level * d.double(forKey: "asmrAmt"))
        let p = tapBank[min(tapBank.count - 1, max(0, Int((i * 4).rounded(.up)) - 1))]
        try? p.stop(atTime: CHHapticTimeImmediate)
        try? p.start(atTime: CHHapticTimeImmediate)
    }

    private func setSlide(_ e: Double) {
        let v = Float(min(1, e * d.double(forKey: "asmrAmt") * 0.5))
        try? slide?.sendParameters([CHHapticDynamicParameter(
            parameterID: .hapticIntensityControl, value: v, relativeTime: 0)], atTime: CHHapticTimeImmediate)
    }

    private func startLoops() {
        try? rumble?.start(atTime: CHHapticTimeImmediate)
        try? slide?.start(atTime: CHHapticTimeImmediate)
        setRumble(0); setSlide(0)
    }

    private func stopLoops() {
        try? rumble?.stop(atTime: CHHapticTimeImmediate)
        try? slide?.stop(atTime: CHHapticTimeImmediate)
    }

    func sendConfig() {
        setRumble(0); setSlide(0)   // clear anything stuck when the effect changes
        let cfg: [String: Double] = ["sens": d.double(forKey: "sens"), "low": 20, "high": d.double(forKey: "high"),
                                     "mode": d.double(forKey: "fx"), "asens": d.double(forKey: "asens")]
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
        running = true
        startLoops()
        listen(t, host)
    }

    func disconnect() {
        wantConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        running = false
        stopLoops()
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
                    if let t = obj["t"] as? Double { self.tap(t) }
                    if let sv = obj["s"] as? Double {
                        self.setSlide(sv)
                        DispatchQueue.main.async { self.level = sv }
                    }
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
    @AppStorage("mode") private var mode = 0
    @AppStorage("fx") private var fx = 0
    @AppStorage("asens") private var asens = 1.6
    @AppStorage("asmrAmt") private var asmrAmt = 0.7
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
                Picker("Source", selection: $mode) {
                    Text("PC audio").tag(0)
                    Text("This phone (mic)").tag(1)
                }
                .pickerStyle(.segmented).disabled(on)
                if mode == 0 {
                    TextField("PC address", text: $host)
                        .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                }
                Button(on ? "Stop" : "Start") {
                    on.toggle()
                    UIApplication.shared.isIdleTimerDisabled = on && mode == 0
                    if on { if mode == 0 { client.connect(host) } else { client.startMic() } }
                    else { if mode == 0 { client.disconnect() } else { client.stopMic() } }
                }
                .foregroundColor(on ? .red : .purple)
                ProgressView(value: client.level).tint(.green)
                Text(client.status).foregroundColor(.secondary)
            }
            Section("Effect (PC mode)") {
                Picker("Effect", selection: $fx) {
                    Text("Bass").tag(0)
                    Text("ASMR").tag(1)
                    Text("Both").tag(2)
                }
                .pickerStyle(.segmented)
                slider("ASMR sensitivity (lower = more taps)", $asens, 1.1...3.0, "%.2f")
                slider("ASMR strength", $asmrAmt, 0.2...1.5, "%.2fx")
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
        .onChange(of: fx) { _ in client.sendConfig() }
        .onChange(of: asens) { _ in client.sendConfig() }
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ f: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(String(format: f, v.wrappedValue))").font(.subheadline)
            Slider(value: v, in: r)
        }
    }
}
