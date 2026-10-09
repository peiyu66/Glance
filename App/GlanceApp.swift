import SwiftUI
import Combine

@main struct GlanceApp: App {
    var body: some Scene { WindowGroup {
        if ProcessInfo.processInfo.arguments.contains("--loopback-probe") { ProbeView() }
        else if ProcessInfo.processInfo.arguments.contains("--siwc-validation") { SIWCView() }
        else if ProcessInfo.processInfo.arguments.contains("--mock") { MockView() }
        else { CameraView() }
    } }
}

struct MockView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = RecognitionState()
    @State private var target: String? = nil
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.6), lineWidth: 2)
                .frame(width: 230, height: 230)
            VStack {
                Text("Glance · 本地 Mock").font(.headline)
                Text("尚未連接相機與 Pro").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("正面") { target = "front"; observe() }
                    Button("背面") { target = "back"; observe() }
                    Button("移開") { target = nil; observe() }
                }.buttonStyle(.bordered)
                Spacer()
                if let result = state.visible {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in Text(line) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("recognitionResult")
                }
            }.padding()
        }.preferredColorScheme(.dark)
            .onReceive(tick) { _ in if scenePhase == .active { observe() } }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { state.leaveForeground(); target = nil }
            }
    }
    private func observe() {
        guard let request = state.observe(target, at: ProcessInfo.processInfo.systemUptime) else { return }
        state.complete(request, result: request.target == "front"
            ? RecognitionResult(names: ["茶罐（示範）"], text: ["烏龍茶"], barcodes: ["4710000000000"])
            : RecognitionResult(text: ["成分：茶葉（背面示範）"]))
    }
}
