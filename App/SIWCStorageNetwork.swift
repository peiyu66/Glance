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
    // Legacy storage compatibility only; W1 never uses this self-attestation as a permission gate.
    var planOnlyConfirmed = false
    var label: String? = nil
    // Random diagnostic correlation only; identity remains in protected storage.
    var authenticationTraceID: UUID? = nil
    var id: String { clientID + ":" + subject }
}
/// Registration metadata only. No identity, scope, authorization code or credentials.
struct SIWCPendingRegistration: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let clientID: String
    let savedAt: Date
    var retry: SIWCRegistrationRetry? = nil // Legacy pending records have no retry permit.
}
enum SIWCSignInChoice: Equatable {
    case newAccount
    case account(String)
    case pending(String)
}
struct SIWCSaved: Codable {
    var hostID: String
    var accounts: [SIWCAccount]
    var selected: String?
    var pendingRegistrations: [SIWCPendingRegistration]
    var recoveryRegistrationID: String? = nil
    init(hostID: String, accounts: [SIWCAccount], selected: String?, pendingRegistrations: [SIWCPendingRegistration] = []) {
        self.hostID = hostID; self.accounts = accounts; self.selected = selected; self.pendingRegistrations = pendingRegistrations
    }
    private enum CodingKeys: String, CodingKey { case hostID, accounts, selected, pendingRegistrations, recoveryRegistrationID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try values.decode(String.self, forKey: .hostID)
        accounts = try values.decode([SIWCAccount].self, forKey: .accounts)
        selected = try values.decodeIfPresent(String.self, forKey: .selected)
        pendingRegistrations = try values.decodeIfPresent([SIWCPendingRegistration].self, forKey: .pendingRegistrations) ?? []
        recoveryRegistrationID = try values.decodeIfPresent(String.self, forKey: .recoveryRegistrationID)
    }
    mutating func assignMissingLabels() {
        var used = Set(accounts.compactMap(\.label) + pendingRegistrations.map(\.label))
        for index in accounts.indices where accounts[index].label == nil {
            var number = 1; while used.contains("連線 \(number)") { number += 1 }
            let label = "連線 \(number)"; accounts[index].label = label; used.insert(label)
        }
    }
}

/// Safe read-only classification for the isolated trial. Never stores raw errors or session contents.
struct SIWCTrialSessionReadError: Error {
    enum Kind: String { case interactionUnavailable = "keychain-interaction-unavailable", accessDenied = "keychain-access-denied", missingEntitlement = "keychain-entitlement-missing", serviceUnavailable = "keychain-service-unavailable", unexpectedStatus = "keychain-other-status", dataMissing = "session-data-missing", decodeFailed = "session-decode-failed" }
    let kind: Kind
    let status: OSStatus
}
enum SIWCTrialSessionRead {
    static func decode(status: OSStatus, data: Data?) throws -> SIWCSaved? {
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            let kind: SIWCTrialSessionReadError.Kind
            switch status {
            case errSecInteractionNotAllowed: kind = .interactionUnavailable
            case errSecAuthFailed: kind = .accessDenied
            case errSecMissingEntitlement: kind = .missingEntitlement
            case errSecNotAvailable: kind = .serviceUnavailable
            default: kind = .unexpectedStatus
            }
            throw SIWCTrialSessionReadError(kind: kind, status: status)
        }
        guard let data else { throw SIWCTrialSessionReadError(kind: .dataMissing, status: status) }
        do { return try JSONDecoder().decode(SIWCSaved.self, from: data) }
        catch { throw SIWCTrialSessionReadError(kind: .decodeFailed, status: status) }
    }
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
    /// Same own-app read query, with sanitized causes retained for the isolated trial only.
    static func loadForTextTrial() throws -> SIWCSaved? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        return try SIWCTrialSessionRead.decode(status: status, data: item as? Data)
    }
    /// Refresh must update the existing own-app item, never create a replacement grant.
    static func saveForTextTrial(_ value: SIWCSaved) throws {
        #if GLANCE_READINESS_DIAGNOSTIC
        throw SIWCReadinessNetworkDisabled()
        #else
        let data = try JSONEncoder().encode(value)
        var q = query; q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        guard status == errSecSuccess else { throw SIWCTrialSessionWriteError(status:status) }
        #endif
    }
    static func save(_ value: SIWCSaved) throws {
        #if GLANCE_READINESS_DIAGNOSTIC
        throw SIWCError.invalidResponse
        #else
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SIWCError.invalidResponse }
        } else if status != errSecSuccess { throw SIWCError.invalidResponse }
        #endif
    }
}

/// Fixed reason plus OSStatus only; never carries a session or raw error string.
struct SIWCTrialSessionWriteError: Error { let status: OSStatus }

/// Shared by ordinary recognition and the isolated four-text trial. No sign-in,
/// registration, retry, token export, or implicit revocation exists in this operation.
@MainActor enum SIWCExistingGrantSession {
    enum Stage: String { case readiness, discovery, claim, refresh, decode, jwks, identity, save, ready }
    enum Failure: String, Error { case refreshMissing = "refresh-credential-missing", refreshTooEarly = "refresh-not-yet-allowed", replacementRefreshMissing = "replacement-refresh-missing" }
    static func usable(account: SIWCAccount, http: SIWCHTTP = .shared, now: @escaping () -> Date = { Date() },
                       validate: () throws -> Void = {}, claimRefresh: () throws -> Void = {},
                       stage: (Stage) -> Void = { _ in }, request: (Stage) -> Void = { _ in },
                       save: (SIWCTokens) throws -> Void) async throws -> SIWCTokens {
        stage(.readiness); try validate()
        guard let old = account.tokens else { throw SIWCError.invalidIdentity }
        if old.expiresAt > now().addingTimeInterval(60) { stage(.ready); return old }
        if let earliest = old.earliestRefreshAt, earliest > now() {
            if old.expiresAt > now() { stage(.ready); return old }
            throw Failure.refreshTooEarly
        }
        guard let refresh = old.refresh, !refresh.isEmpty else { throw Failure.refreshMissing }
        stage(.discovery); try validate(); request(.discovery)
        let config = try await SIWCDiscovery.load(http: http)
        try validate(); stage(.claim); try claimRefresh()
        let body = SIWCProtocol.form(["grant_type":"refresh_token", "client_id":account.clientID, "refresh_token":refresh, "resource":SIWCProtocol.resource])
        stage(.refresh); try validate(); request(.refresh)
        let data = try await http.data(url:config.token_endpoint,body:body,form:true)
        try validate(); stage(.decode)
        let response = try JSONDecoder().decode(SIWCTokenResponse.self,from:data)
        let replacement = try response.tokens(retainedID:old.idToken,retainedScope:old.scope,now:now())
        guard let nextRefresh = replacement.refresh, !nextRefresh.isEmpty else { throw Failure.replacementRefreshMissing }
        if response.id_token != nil {
            stage(.jwks); try validate(); request(.jwks)
            let keys = try await http.data(url:config.jwks_uri)
            try validate(); stage(.identity)
            _ = try SIWCIdentityVerifier.verify(replacement.idToken,jwks:keys,clientID:account.clientID,nonce:nil,expectedSubject:account.subject,now:now())
        }
        stage(.save); try validate(); try Task.checkCancellation(); try save(replacement)
        stage(.ready); return replacement
    }
}

struct SIWCReadinessNetworkDisabled: Error { }

struct SIWCHTTPError: Error {
    let status: Int
    let code: String?
    let requestID: String?
    let parameter: String?
    let bodyShape: String
    var responseDiagnostic: SIWCServiceDiagnostic? = nil
    var errorDescription: SIWCErrorDescriptionDiagnostic? = nil
    var terminalRefresh: Bool { ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "") }
}
@MainActor final class SIWCHTTP: NSObject, URLSessionTaskDelegate {
    static let shared = SIWCHTTP()
    private let configurationOverride: URLSessionConfiguration?
    init(configuration: URLSessionConfiguration? = nil) {
        configurationOverride = configuration
        super.init()
    }
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
        let config = configurationOverride ?? URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func cancelRequests() { session.invalidateAndCancel() }
    func data(url: String, body: Data? = nil, bearer: String? = nil, form: Bool = false, observeHTTP: ((Int) -> Void)? = nil, observeRequest: ((URLRequest) -> Void)? = nil, observeResponse: ((SIWCServiceDiagnostic) -> Void)? = nil) async throws -> Data {
        #if GLANCE_READINESS_DIAGNOSTIC
        throw SIWCReadinessNetworkDisabled()
        #else
        let kind = url.hasSuffix("/models") ? "models" : url.hasSuffix("/token") ? "token-exchange-or-refresh" : url.hasSuffix("/revoke") ? "revocation" : "public-identity-configuration"
        startDiagnostic(kind); defer { finishDiagnostic() }
        let request = try makeRequest(url: url, body: body, bearer: bearer, form: form)
        observeRequest?(request)
        let (data, response) = try await session.data(for: request)
        guard data.count < 2_000_000, let http = response as? HTTPURLResponse else { throw SIWCError.invalidResponse }
        diagnostics["httpStatus"] = http.statusCode
        observeHTTP?(http.statusCode)
        let safeResponse = recordResponse(http); observeResponse?(safeResponse)
        guard (200..<300).contains(http.statusCode) else { throw failure(http, data: data) }
        diagnostics["phase"] = "response-received"
        return data
        #endif
    }

    func stream(body: Data, bearer: String, operation: String = "synthetic-image", cameraRequestID: String? = nil, validateBeforeImageSend: (() throws -> Void)? = nil, observeResponse: ((SIWCServiceDiagnostic) -> Void)? = nil, transportStarted: (() -> Void)? = nil) async throws -> String {
        #if GLANCE_READINESS_DIAGNOSTIC
        throw SIWCReadinessNetworkDisabled()
        #else
        startDiagnostic(operation); diagnostics["cameraRequestID"] = cameraRequestID; defer { finishDiagnostic() }
        var request = try makeRequest(url: SIWCProtocol.resource + "/responses", body: body, bearer: bearer)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        // Token/catalog awaits may have outlived the captured focus generation.
        // This is the final pre-transport boundary; later focus changes retain inflight work.
        try validateBeforeImageSend?()
        transportStarted?()
        let (bytes, response) = try await session.bytes(for: request)
        diagnostics["headersMilliseconds"] = elapsed()
        guard let http = response as? HTTPURLResponse else { throw SIWCError.invalidResponse }
        diagnostics["httpStatus"] = http.statusCode
        let safeResponse = recordResponse(http); observeResponse?(safeResponse)
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
        #endif
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
    private func responseDiagnostic(_ http: HTTPURLResponse) -> SIWCServiceDiagnostic {
        let endpoint: SIWCServiceDiagnostic.Endpoint
        switch http.url?.absoluteString {
        case SIWCProtocol.issuer + "/api/accounts/oauth/token": endpoint = .token
        case SIWCProtocol.resource + "/models": endpoint = .models
        case SIWCProtocol.resource + "/responses": endpoint = .responses
        case SIWCProtocol.issuer + "/.well-known/openid-configuration": endpoint = .discovery
        case SIWCProtocol.issuer + "/.well-known/jwks.json": endpoint = .jwks
        default: endpoint = .other
        }
        return .init(endpoint: endpoint, status: http.statusCode, rawRequestID: http.value(forHTTPHeaderField: "x-request-id"))
    }
    private func recordResponse(_ http: HTTPURLResponse) -> SIWCServiceDiagnostic {
        let safe = responseDiagnostic(http)
        diagnostics["endpointClass"] = safe.endpoint.rawValue
        diagnostics["serviceRequestID"] = safe.requestID
        diagnostics["serviceRequestIDState"] = safe.requestIDState.rawValue
        return safe
    }
    private func failure(_ http: HTTPURLResponse, data: Data) -> SIWCHTTPError {
        let root = data.count <= 65_536 ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
        let error = root?["error"]
        let rawCode = ((error as? [String: Any])?["code"] as? String) ?? (error as? String)
        let object = error as? [String: Any]
        let shape = object != nil ? "error-object" : error is String ? "error-string" : root?["detail"] != nil ? "detail-object" : root != nil ? "other-object" : "non-object"
        let service = responseDiagnostic(http)
        return SIWCHTTPError(status: http.statusCode, code: SIWCSafeDiagnostic.code(rawCode), requestID: service.requestID,
                             parameter: SIWCSafeDiagnostic.parameter(object?["param"] as? String), bodyShape: shape,
                             responseDiagnostic: service,
                             errorDescription: service.endpoint == .token ? .tokenResponse(data) : nil)
    }
}
struct SIWCDiscovery: Decodable {
    let issuer: String; let authorization_endpoint: String; let token_endpoint: String; let jwks_uri: String; let revocation_endpoint: String
    @MainActor static func load(observeHTTP: ((Int) -> Void)? = nil, http: SIWCHTTP = .shared) async throws -> Self {
        let data = try await http.data(url: SIWCProtocol.issuer + "/.well-known/openid-configuration", observeHTTP: observeHTTP)
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
    func tokens(retainedID: String? = nil, retainedScope: String? = nil, now: Date = Date()) throws -> SIWCTokens {
        guard !access_token.isEmpty, token_type.lowercased() == "bearer", expires_in > 0,
              let id = id_token ?? retainedID, !id.isEmpty, let scope = scope ?? retainedScope else { throw SIWCError.invalidResponse }
        return SIWCTokens(access: access_token, refresh: refresh_token, idToken: id, scope: scope,
            expiresAt: now.addingTimeInterval(expires_in), earliestRefreshAt: earliest_refresh_at.map(Date.init(timeIntervalSince1970:)))
    }
}
