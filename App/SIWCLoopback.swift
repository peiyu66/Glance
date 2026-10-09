import Foundation
import Network

final class SIWCLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Glance.SIWC.loopback")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var pending: SIWCPending?
    private var cancelled = false
    private let event: @Sendable (Result<(SIWCPending, String, String), Error>) -> Void
    init(event: @escaping @Sendable (Result<(SIWCPending, String, String), Error>) -> Void) { self.event = event }
    func start(clientID: String?, ready: @escaping @Sendable (SIWCPending) -> Void) {
        queue.async { [self] in
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                let listener = try NWListener(using: params); self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, !self.cancelled else { return }
                    if case .ready = state, let port = listener?.port?.rawValue {
                        do {
                            let p = SIWCPending(state: try SIWCProtocol.random(), nonce: try SIWCProtocol.random(), verifier: try SIWCProtocol.random(), port: port, clientID: clientID, deadline: Date().addingTimeInterval(300))
                            self.pending = p; ready(p)
                        } catch { self.event(.failure(error)); self.close() }
                    } else if case .failed = state { self.event(.failure(SIWCError.invalidResponse)); self.close() }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, !self.cancelled, self.connections.count < 4 else { connection.cancel(); return }
                    let id = UUID(); self.connections[id] = connection; connection.start(queue: self.queue)
                    self.receive(connection, id: id, data: Data())
                    self.queue.asyncAfter(deadline: .now() + 5) { self.connections.removeValue(forKey: id)?.cancel() }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 300) {
                    guard !self.cancelled else { return }; self.event(.failure(SIWCError.invalidCallback)); self.close()
                }
            } catch { event(.failure(error)); close() }
        }
    }
    func stop() { queue.async { self.close() } }
    private func close() {
        cancelled = true; listener?.cancel(); listener = nil; pending = nil
        for c in connections.values { c.cancel() }; connections.removeAll()
    }
    private func receive(_ c: NWConnection, id: UUID, data: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] chunk, _, done, error in
            guard let self, !self.cancelled, self.connections[id] != nil else { return }
            var buffer = data; if let chunk { buffer.append(chunk) }
            guard buffer.count <= 16384, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if done { self.connections.removeValue(forKey: id)?.cancel() } else { self.receive(c, id: id, data: buffer) }; return
            }
            let lines = text.components(separatedBy: "\r\n"); let first = (lines.first ?? "").split(separator: " ")
            let hosts = lines.filter { $0.lowercased().hasPrefix("host:") }
            guard first.count == 3, first[0] == "GET", hosts.count == 1, let port = self.listener?.port?.rawValue,
                  hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)", var p = self.pending else {
                self.reply(c, id: id, accepted: false); return
            }
            do {
                let result = try p.callback(target: String(first[1])); self.pending = nil
                self.reply(c, id: id, accepted: true)
                self.event(.success((p, result.code, result.clientID)))
            } catch SIWCError.denied {
                self.pending = nil; self.reply(c, id: id, accepted: true); self.event(.failure(SIWCError.denied))
            } catch { self.reply(c, id: id, accepted: false) }
        }
    }
    private func reply(_ c: NWConnection, id: UUID, accepted: Bool) {
        let body = accepted ? "Return to Glance. The response will be verified locally." : "Invalid callback."
        let header = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data((header + body).utf8), completion: .contentProcessed { [weak self] _ in self?.connections.removeValue(forKey: id)?.cancel() })
    }
}
