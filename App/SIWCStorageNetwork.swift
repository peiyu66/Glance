import Foundation
import Security

struct SIWCTokens: Codable, Sendable {
    var access: String
    var refresh: String?
    var idToken: String
    var scope: String
    var expiresAt: Date
    var earliestRefreshAt: Date?
}
struct SIWCAccount: Codable, Identifiable, Sendable {
    var clientID: String
    var subject: String
    var email: String?
    var tokens: SIWCTokens?
    var planOnlyConfirmed = false
    var id: String { clientID + ":" + subject }
}
struct SIWCSaved: Codable {
    var hostID: String
    var accounts: [SIWCAccount]
    var selected: String?
}

enum SIWCKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.peiyu.Glance.SIWC", kSecAttrAccount as String: "accounts-v1",
        kSecAttrSynchronizable as String: false] }
    static func load() throws -> SIWCSaved? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SIWCError.invalidResponse }
        return try JSONDecoder().decode(SIWCSaved.self, from: data)
    }
    static func save(_ value: SIWCSaved) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SIWCError.invalidResponse }
        } else if status != errSecSuccess { throw SIWCError.invalidResponse }
    }
}

struct SIWCHTTPError: Error {
    let status: Int
    let code: String?
    let requestID: String?
    let parameter: String?
    let bodyShape: String
    var terminalRefresh: Bool { ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "") }
}
@MainActor final class SIWCHTTP: NSObject, URLSessionTaskDelegate {
    static let shared = SIWCHTTP()
    private(set) var diagnostics: [String: Any] = [:]
    private var startedAt = 0.0
    private func startDiagnostic(_ operation: String) {
        startedAt = ProcessInfo.processInfo.systemUptime
        diagnostics = ["operation": operation, "phase": "request-started",
            "operationID": UUID().uuidString, "startedAt": ISO8601DateFormatter().string(from: Date()),
            "requestTimeoutSeconds": 30, "resourceTimeoutSeconds": 120]
    }
    func prepareCameraRequest(_ id: String?) {
        startDiagnostic("camera-preparation"); diagnostics["cameraRequestID"] = id
    }
    func markStage(_ phase: String) { diagnostics["phase"] = phase }
    private func elapsed() -> Int { Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000) }
    private func finishDiagnostic() {
        diagnostics["elapsedMilliseconds"] = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
    }
    func recordFailure(_ error: Error) {
        let ns = error as NSError
        diagnostics["errorDomainClass"] = [NSCocoaErrorDomain, NSURLErrorDomain].contains(ns.domain) ? ns.domain : "application"
        diagnostics["errorNumericCode"] = ns.code
        diagnostics["failureStage"] = diagnostics["phase"]
        diagnostics["phase"] = "stopped"
        if let http = error as? SIWCHTTPError {
            diagnostics["httpStatus"] = http.status; diagnostics["errorCategory"] = "http"
            diagnostics["errorCode"] = http.code; diagnostics["errorParameter"] = http.parameter
            diagnostics["bodyShape"] = http.bodyShape
        } else if let stream = error as? SIWCStreamFailure {
            diagnostics["terminalEvent"] = stream.terminal; diagnostics["errorCategory"] = "stream-terminal"
            diagnostics["errorCode"] = stream.code; diagnostics["errorParameter"] = stream.parameter
        } else if error is CancellationError { diagnostics["errorCategory"] = "cancelled" }
        else if let network = error as? URLError, network.code == .cancelled {
            diagnostics["errorCategory"] = "cancelled"; diagnostics["transportCode"] = network.code.rawValue
        }
        else if let network = error as? URLError {
            diagnostics["errorCategory"] = "transport"; diagnostics["transportCode"] = network.code.rawValue
        } else if error as? SIWCError == .incompleteStream { diagnostics["errorCategory"] = "stream-without-completion" }
        else if let validation = error as? SIWCError {
            let kind: String
            switch validation {
            case .sseInvalidUTF8: kind = "sse-invalid-utf8"
            case .sseInvalidJSON: kind = "sse-invalid-json"
            case .sseMissingType: kind = "sse-missing-type"
            case .sseSizeLimit: kind = "sse-size-limit"
            case .unexpectedContentType: kind = "unexpected-content-type"
            default: kind = "validation"
            }
            diagnostics["errorCategory"] = kind
        } else { diagnostics["errorCategory"] = "decoding" }
        if startedAt > 0 { finishDiagnostic() }
    }
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func data(url: String, body: Data? = nil, bearer: String? = nil, form: Bool = false) async throws -> Data {
        let kind = url.hasSuffix("/models") ? "models" : url.hasSuffix("/token") ? "token-exchange-or-refresh" : url.hasSuffix("/revoke") ? "revocation" : "public-identity-configuration"
        startDiagnostic(kind); defer { finishDiagnostic() }
        let request = try makeRequest(url: url, body: body, bearer: bearer, form: form)
        let (data, response) = try await session.data(for: request)
        guard data.count < 2_000_000, let http = response as? HTTPURLResponse else { throw SIWCError.invalidResponse }
        diagnostics["httpStatus"] = http.statusCode
        guard (200..<300).contains(http.statusCode) else { throw failure(http, data: data) }
        diagnostics["phase"] = "response-received"
        return data
    }
    func stream(body: Data, bearer: String, operation: String = "synthetic-image", cameraRequestID: String? = nil) async throws -> String {
        startDiagnostic(operation); diagnostics["cameraRequestID"] = cameraRequestID; defer { finishDiagnostic() }
        var request = try makeRequest(url: SIWCProtocol.resource + "/responses", body: body, bearer: bearer)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        diagnostics["headersMilliseconds"] = elapsed()
        guard let http = response as? HTTPURLResponse else { throw SIWCError.invalidResponse }
        diagnostics["httpStatus"] = http.statusCode
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count >= 16384 { break } }
            throw failure(http, data: body)
        }
        diagnostics["phase"] = "response-headers"
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        let mime = contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        diagnostics["contentTypeClass"] = ["text/event-stream", "application/json", "text/plain"].contains(mime ?? "") ? mime : mime == nil ? "missing" : "other"
        guard SIWCStream.acceptsContentType(contentType) else {
            var sample = Data()
            for try await byte in bytes {
                if sample.isEmpty { diagnostics["firstDataMilliseconds"] = elapsed() }
                sample.append(byte); if sample.count >= 16384 { break }
            }
            let root = (try? JSONSerialization.jsonObject(with: sample)) as? [String: Any]
            diagnostics["nonStreamBodyShape"] = root?["error"] != nil ? "error-object" : root?["detail"] != nil ? "detail-object" : root?["output"] != nil ? "response-object" : root != nil ? "other-object" : "non-object"
            diagnostics["nonStreamLooksLikeSSE"] = sample.starts(with: Data("data:".utf8)) || sample.starts(with: Data("event:".utf8))
            if let error = root?["error"] as? [String: Any] { diagnostics["errorCode"] = SIWCSafeDiagnostic.code(error["code"] as? String) }
            throw SIWCError.unexpectedContentType
        }
        diagnostics["phase"] = "stream-open"
        let readStartedMS = elapsed()
        var iterator = bytes.makeAsyncIterator()
        let text = try await SIWCStreamReader.read(nextByte: { try await iterator.next() }) { counts, terminal, shape in
            diagnostics["streamCounts"] = counts
            diagnostics["receivedBytes"] = counts["receivedBytes"]
            diagnostics["eventCount"] = counts["eventCount"]
            diagnostics["lastEventShape"] = shape
            diagnostics["terminalEvent"] = terminal
            for (local, overall) in [("firstByteMS", "firstDataMilliseconds"), ("lastByteMS", "lastDataMilliseconds"),
                                     ("firstEventMS", "firstEventMilliseconds"), ("lastEventMS", "lastEventMilliseconds")] {
                if let time = counts[local] { diagnostics[overall] = readStartedMS + time }
            }
            if terminal != nil { diagnostics["terminalMilliseconds"] = elapsed() }
        }
        diagnostics["phase"] = "completed"
        return text
    }

    private func makeRequest(url: String, body: Data?, bearer: String?, form: Bool = false) throws -> URLRequest {
        guard let endpoint = URL(string: url), endpoint.scheme == "https", endpoint.user == nil, endpoint.password == nil,
              endpoint.port == nil, endpoint.query == nil, endpoint.fragment == nil,
              ["auth.openai.com", "api.openai.com"].contains(endpoint.host) else { throw SIWCError.invalidResponse }
        var r = URLRequest(url: endpoint); r.cachePolicy = .reloadIgnoringLocalCacheData
        r.httpMethod = body == nil ? "GET" : "POST"; r.httpBody = body
        if let body, !body.isEmpty { r.setValue(form ? "application/x-www-form-urlencoded" : "application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer { r.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        return r
    }
    private func failure(_ http: HTTPURLResponse, data: Data) -> SIWCHTTPError {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = root?["error"]
        let rawCode = ((error as? [String: Any])?["code"] as? String) ?? (error as? String)
        let object = error as? [String: Any]
        let shape = object != nil ? "error-object" : error is String ? "error-string" : root?["detail"] != nil ? "detail-object" : root != nil ? "other-object" : "non-object"
        return SIWCHTTPError(status: http.statusCode, code: SIWCSafeDiagnostic.code(rawCode), requestID: http.value(forHTTPHeaderField: "x-request-id"), parameter: SIWCSafeDiagnostic.parameter(object?["param"] as? String), bodyShape: shape)
    }
}
struct SIWCDiscovery: Decodable {
    let issuer: String; let authorization_endpoint: String; let token_endpoint: String; let jwks_uri: String; let revocation_endpoint: String
    static func load() async throws -> Self {
        let data = try await SIWCHTTP.shared.data(url: SIWCProtocol.issuer + "/.well-known/openid-configuration")
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.issuer == SIWCProtocol.issuer,
              value.authorization_endpoint == SIWCProtocol.issuer + "/api/accounts/authorize",
              value.token_endpoint == SIWCProtocol.issuer + "/api/accounts/oauth/token",
              value.jwks_uri == SIWCProtocol.issuer + "/.well-known/jwks.json",
              URL(string: value.revocation_endpoint)?.host == "auth.openai.com" else { throw SIWCError.invalidResponse }
        return value
    }
}
struct SIWCTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let token_type: String
    let expires_in: Double
    let scope: String?
    let earliest_refresh_at: Double?
    func tokens(retainedID: String? = nil, retainedScope: String? = nil) throws -> SIWCTokens {
        guard !access_token.isEmpty, token_type.lowercased() == "bearer", expires_in > 0,
              let id = id_token ?? retainedID, !id.isEmpty, let scope = scope ?? retainedScope else { throw SIWCError.invalidResponse }
        return SIWCTokens(access: access_token, refresh: refresh_token, idToken: id, scope: scope,
            expiresAt: Date().addingTimeInterval(expires_in), earliestRefreshAt: earliest_refresh_at.map(Date.init(timeIntervalSince1970:)))
    }
}
