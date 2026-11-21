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
    private var task: URLSessionWebSocketTask?
    private var wantConnected = false

    init() { setupEngine() }

    private func setupEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            status = "This device has no haptics"; return
        }
        do {
            engine = try CHHapticEngine()
            engine?.isAutoShutdownEnabled = false
            engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
            engine?.stoppedHandler = { [weak self] _ in try? self?.engine?.start() }
            try engine?.start()
        } catch { status = "Haptic error: \(error.localizedDescription)" }
    }

    // Low-sharpness thump + short rumble = bass-like feel
    private func pulse(_ level: Double) {
        guard let engine else { return }
        let i = Float(max(0.25, min(1, level)))
        let thump = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: i),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)], relativeTime: 0)
        let body = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: i * 0.8),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)],
            relativeTime: 0, duration: 0.07)
        do {
            let pattern = try CHHapticPattern(events: [thump, body], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    func connect(_ host: String) {
        disconnect()
        guard let url = URL(string: "ws://\(host)/ws") else { status = "Bad address"; return }
        wantConnected = true
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        status = "Listening for beats..."
        listen(t, host)
    }

    func disconnect() {
        wantConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        status = "Not connected"
    }

    private func listen(_ t: URLSessionWebSocketTask, _ host: String) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .success(let msg):
                if case .string(let s) = msg,
                   let d = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let lv = obj["level"] as? Double {
                    self.pulse(lv)
                    DispatchQueue.main.async { self.level = lv }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.level = 0 }
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
    @StateObject private var client = BassClient()
    @State private var on = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Bass Buzz").font(.largeTitle.bold())
            TextField("PC address, e.g. 192.168.88.16:8080", text: $host)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button(on ? "Stop" : "Start") {
                on.toggle()
                UIApplication.shared.isIdleTimerDisabled = on   // keep screen awake
                on ? client.connect(host) : client.disconnect()
            }
            .font(.title2).padding(.horizontal, 40).padding(.vertical, 14)
            .background(on ? Color.red : Color.purple)
            .foregroundColor(.white).cornerRadius(14)
            ProgressView(value: client.level).tint(.green)
            Text(client.status).foregroundColor(.secondary)
        }
        .padding(24)
    }
}
