import SwiftUI
import Network
import Observation
import AuthenticationServices

/// All mutable network state belongs to queue. Only synthetic, non-secret data is handled.
final class ProbeServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Glance.loopbackProbe")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var validator: ProbeCallback?
    private var expiry: TimeInterval = 0
    private var port: UInt16 = 0
    private let event: @Sendable (String) -> Void
    init(event: @escaping @Sendable (String) -> Void) { self.event = event }
    func stop() { queue.async { self.close() } }
    private func close() {
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll(); validator = nil
    }
    func start(delay: Int, ready: @escaping @Sendable (URL) -> Void) {
        queue.async { [self] in
            close()
            let state = UUID().uuidString
            validator = ProbeCallback(state: state)
            expiry = ProcessInfo.processInfo.systemUptime + 90
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            do {
                let server = try NWListener(using: parameters)
                listener = server
                server.stateUpdateHandler = { [weak self, weak server] status in
                    guard let self, self.listener === server else { return }
                    switch status {
                    case .ready:
                        guard let port = server?.port?.rawValue else { return }
                        self.port = port
                        self.event("listener-ready")
                        ready(URL(string: "http://127.0.0.1:\(port)/probe?delay=\(delay)")!)
                    case .failed: self.event("listener-failed"); self.close()
                    default: break
                    }
                }
                server.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    guard self.connections.count < 8 else { connection.cancel(); return }
                    let id = UUID(); self.connections[id] = connection
                    connection.start(queue: self.queue)
                    self.receive(connection, id: id, data: Data(), state: state, delay: delay)
                    self.queue.asyncAfter(deadline: .now() + 5) {
                        self.connections.removeValue(forKey: id)?.cancel()
                    }
                }
                server.start(queue: queue)
            } catch { event("listener-failed"); close() }
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, data: Data, state: String, delay: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var buffer = data
            if let chunk { buffer.append(chunk) }
            guard buffer.count <= 8192, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
            guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                if complete { self.connections.removeValue(forKey: id)?.cancel() }
                else { self.receive(connection, id: id, data: buffer, state: state, delay: delay) }
                return
            }
            let lines = request.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            let hosts = lines.filter { $0.lowercased().hasPrefix("host:") }
            guard first.count == 3, first[0] == "GET", hosts.count == 1,
                  hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(self.port)" else {
                self.reply(connection, id: id, status: "400 Bad Request", body: "Invalid probe request."); return
            }
            guard ProcessInfo.processInfo.systemUptime < self.expiry else {
                self.event("timeout"); self.reply(connection, id: id, status: "410 Gone", body: "Probe expired.", finish: true); return
            }
            let target = String(first[1])
            if target == "/probe?delay=\(delay)" {
                self.event("browser-page-loaded")
                let callback = "/auth/callback?state=\(state)&code=probe-only"
                let html = """
                <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
                <title>Glance local probe</title><h1>Glance: local test only</h1>
                <p>No OpenAI login, account or token is involved.</p>
                <p>Stay in the browser. Synthetic callback in \(delay) seconds.</p>
                <script>setTimeout(()=>location.href='\(callback)', \(delay * 1000));</script>
                """
                self.reply(connection, id: id, status: "200 OK", body: html)
            } else if self.validator?.accept(target: target) == true {
                self.event("callback-accepted")
                self.reply(connection, id: id, status: "200 OK", body: "<h1>Local callback received</h1><p>Return to Glance. This is not an OAuth login.</p>", finish: true)
            } else {
                self.event("request-rejected")
                self.reply(connection, id: id, status: "400 Bad Request", body: "Rejected. Local probe only.")
            }
        }
    }
    private func reply(_ connection: NWConnection, id: UUID, status: String, body: String, finish: Bool = false) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + bodyData, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.connections.removeValue(forKey: id)?.cancel()
            if finish { self.close() }
        })
    }
}

@MainActor @Observable final class ProbeModel: NSObject, ASWebAuthenticationPresentationContextProviding {
    var events: [String] = []
    var running = false
    private var server: ProbeServer?
    private var started: TimeInterval = 0
    private var timer: Timer?
    private var delay = 2
    private var browser = "external"
    private var deadline: TimeInterval = 90
    private var cancelAfter: TimeInterval?
    private var runID = UUID()
    private var webSession: ASWebAuthenticationSession?
    private var originalIdleTimer = false

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func start(delay: Int, browser: String = "external", deadline: TimeInterval = 90, cancelAfter: TimeInterval? = nil) {
        cancel(record: false)
        let attempt = UUID(); runID = attempt
        self.delay = delay; self.browser = browser; self.deadline = deadline; self.cancelAfter = cancelAfter
        events = []; started = ProcessInfo.processInfo.systemUptime; running = true
        originalIdleTimer = UIApplication.shared.isIdleTimerDisabled
        // Only keeps this foreground experiment visible; it is not background execution.
        if browser == "authentication" { UIApplication.shared.isIdleTimerDisabled = true }
        record("probe-started")
        let server = ProbeServer { [weak self] event in
            Task { @MainActor in
                guard let self, self.runID == attempt else { return }
                self.record(event)
                if ["callback-accepted", "timeout", "listener-failed"].contains(event) {
                    self.running = false; self.timer?.invalidate()
                    UIApplication.shared.isIdleTimerDisabled = self.originalIdleTimer
                    // Give the local HTTP response a chance to finish before dismissing the browser.
                    try? await Task.sleep(for: .milliseconds(250))
                    guard self.runID == attempt else { return }
                    self.webSession?.cancel(); self.webSession = nil
                }
            }
        }
        self.server = server
        server.start(delay: delay) { [weak self] url in
            Task { @MainActor in
                guard let self, self.runID == attempt else { return }
                if browser == "authentication" {
                    // No invented custom scheme: the HTTP listener consumes the callback.
                    // nil is allowed by Apple's older initializer; this is an experiment, not a support guarantee.
                    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
                        Task { @MainActor in
                            guard let self, self.runID == attempt, self.running else { return }
                            self.record(error == nil ? "authentication-window-ended" : "authentication-window-cancelled-or-error")
                            self.cancel(record: false)
                        }
                    }
                    session.presentationContextProvider = self
                    // Synthetic local page needs no existing browser cookies or account session.
                    session.prefersEphemeralWebBrowserSession = true
                    self.webSession = session
                    let didStart = session.start()
                    self.record(didStart ? "authentication-window-started" : "authentication-window-start-failed")
                    if !didStart { self.cancel(record: false) }
                } else {
                    UIApplication.shared.open(url) { opened in
                        Task { @MainActor in
                            guard self.runID == attempt else { return }
                            self.record(opened ? "system-browser-opened" : "browser-open-failed")
                        }
                    }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkExpiry() }
        }
    }
    func phase(_ phase: ScenePhase) {
        guard started > 0 else { return }
        record(phase == .active ? "app-active" : phase == .background ? "app-background" : "app-inactive")
        checkExpiry()
    }
    private func checkExpiry() {
        guard running else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if elapsed >= deadline { record("timeout"); cancel(record: false) }
        else if let cancelAfter, elapsed >= cancelAfter { cancel() }
    }
    func cancel(record shouldRecord: Bool = true) {
        if shouldRecord && running { record("cancelled") }
        runID = UUID()
        server?.stop(); server = nil; running = false; timer?.invalidate(); timer = nil
        webSession?.cancel(); webSession = nil
        UIApplication.shared.isIdleTimerDisabled = originalIdleTimer
    }
    private func record(_ event: String) {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
        events.append(String(format: "%.1fs %@", elapsed, event))
        // Deliberately contains no URL, query, state, device ID, account or token.
        let report: [String: Any] = ["kind": "synthetic-loopback-only", "browser": browser,
                                    "delaySeconds": delay, "deadlineSeconds": deadline, "events": events]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: documents.appendingPathComponent("probe-report.json"), options: .atomic)
        }
    }
}

struct ProbeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = ProbeModel()
    @State private var autoStarted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Glance · 本機回呼探針").font(.title2.bold())
            Text("沒有登入、帳戶或 token。測試頁開啟後請停留；系統認證視窗成功後會自動關閉。")
            HStack {
                Button("外部 2 秒") { model.start(delay: 2) }
                Button("外部 45 秒") { model.start(delay: 45) }
            }.buttonStyle(.bordered)
            HStack {
                Button("系統認證 2 秒") { model.start(delay: 2, browser: "authentication") }
                Button("系統認證 45 秒") { model.start(delay: 45, browser: "authentication") }
            }.buttonStyle(.bordered)
            Button("取消") { model.cancel() }.buttonStyle(.bordered)
            ScrollView { Text(model.events.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
            Text("只證明合成回呼；不代表官方 Pro 登入已通過。").font(.caption)
        }.padding().onChange(of: scenePhase) { _, phase in model.phase(phase) }
            .task {
                guard !autoStarted else { return }; autoStarted = true
                let args = ProcessInfo.processInfo.arguments
                func value(_ key: String) -> String? { args.first(where: { $0.hasPrefix(key + "=") })?.split(separator: "=").last.map(String.init) }
                if let delay = Int(value("--probe-delay") ?? ""), [2, 45].contains(delay) {
                    let browser = value("--probe-browser") == "authentication" ? "authentication" : "external"
                    let deadline: TimeInterval = value("--probe-timeout") == "3" ? 3 : 90
                    let cancelAfter: TimeInterval? = value("--probe-cancel-after") == "2" ? 2 : nil
                    try? await Task.sleep(for: .seconds(1))
                    model.start(delay: delay, browser: browser, deadline: deadline, cancelAfter: cancelAfter)
                }
            }.onDisappear { model.cancel() }
    }
}
