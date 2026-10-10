import Foundation
import CryptoKit
import Security

public enum SIWCError: Error, Equatable {
    case invalidCallback, denied, invalidIdentity, invalidResponse, planDisabled, modelUnavailable, incompleteStream
    case sseInvalidUTF8, sseInvalidJSON, sseMissingType, sseSizeLimit, unexpectedContentType
}

public enum SIWCProtocol {
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SIWCError.invalidResponse }
        return encode(Data(bytes))
    }
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ text: String) -> Data? {
        let base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
    public static func challenge(_ verifier: String) -> String { encode(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    public static func hasPlan(_ scopes: String) -> Bool { Set(scopes.split(separator: " ")).contains("chatgpt.tokens.use.direct") }
}

public struct SIWCPending: Sendable {
    public let state: String
    public let nonce: String
    public let verifier: String
    public let redirect: String
    public let clientID: String?
    public let deadline: Date
    private var consumed = false
    public init(state: String, nonce: String, verifier: String, port: UInt16, clientID: String?, deadline: Date) {
        self.state = state; self.nonce = nonce; self.verifier = verifier
        self.redirect = "http://127.0.0.1:\(port)/auth/callback"; self.clientID = clientID; self.deadline = deadline
    }
    public func authorize(hostID: String, idTokenHint: String? = nil) -> URL {
        var fields = ["client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                      "response_type": "code", "redirect_uri": redirect, "scope": SIWCProtocol.scopes,
                      "resource": SIWCProtocol.resource, "state": state, "nonce": nonce,
                      "code_challenge_method": "S256", "code_challenge": SIWCProtocol.challenge(verifier)]
        if clientID == nil { fields["agent_name_hint"] = "Glance" }
        else if let idTokenHint { fields["id_token_hint"] = idTokenHint }
        var url = URLComponents(string: SIWCProtocol.issuer + "/api/accounts/authorize")!
        url.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    public mutating func callback(target: String, now: Date = Date()) throws -> (code: String, clientID: String) {
        guard !consumed, now < deadline, let url = URLComponents(string: target), url.scheme == nil,
              url.host == nil, url.fragment == nil, url.percentEncodedPath == "/auth/callback" else { throw SIWCError.invalidCallback }
        let items = url.queryItems ?? []
        let names = items.map(\.name)
        guard Set(names).count == names.count, items.first(where: { $0.name == "state" })?.value == state else { throw SIWCError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { consumed = true; throw SIWCError.denied }
        let supplied = items.first(where: { $0.name == "client_id" })?.value
        if let clientID, let supplied, supplied != clientID { throw SIWCError.invalidCallback }
        guard let issued = supplied ?? clientID, !issued.isEmpty, issued != "dynamic_agent_client", issued.count <= 256,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.count <= 4096 else { throw SIWCError.invalidCallback }
        consumed = true
        return (code, issued)
    }
    public func codeExchange(code: String, issuedClientID: String) -> Data {
        SIWCProtocol.form(["grant_type": "authorization_code", "client_id": issuedClientID, "code": code,
                           "code_verifier": verifier, "redirect_uri": redirect, "resource": SIWCProtocol.resource])
    }
}

public struct SIWCIdentity: Equatable, Sendable { public let subject: String; public let email: String? }

/// Narrow RS256 verifier using Apple's Security signature implementation, not home-grown cryptography.
public enum SIWCIdentityVerifier {
    public static func verify(_ token: String, jwks: Data, clientID: String, nonce: String?, expectedSubject: String? = nil, now: Date = Date()) throws -> SIWCIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard token.utf8.count <= 32768, parts.count == 3,
              let hd = SIWCProtocol.decode(parts[0]), let pd = SIWCProtocol.decode(parts[1]), let sig = SIWCProtocol.decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: hd) as? [String: Any],
              header["alg"] as? String == "RS256", header["crit"] == nil, let kid = header["kid"] as? String,
              let root = try JSONSerialization.jsonObject(with: jwks) as? [String: Any], let keys = root["keys"] as? [[String: Any]] else { throw SIWCError.invalidIdentity }
        let matching = keys.filter { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && $0["alg"] as? String == "RS256" && $0["use"] as? String == "sig" }
        guard matching.count == 1, let n = matching[0]["n"] as? String, let e = matching[0]["e"] as? String,
              let modulus = SIWCProtocol.decode(n), let exponent = SIWCProtocol.decode(e), modulus.count >= 256, modulus.count <= 1024,
              !exponent.isEmpty, exponent.count <= 8 else { throw SIWCError.invalidIdentity }
        let der = tlv(0x30, integer(modulus) + integer(exponent))
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, sig as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: pd) as? [String: Any],
              claims["iss"] as? String == SIWCProtocol.issuer,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970 - 5,
              let issued = claims["iat"] as? Double, issued <= now.timeIntervalSince1970 + 5 else { throw SIWCError.invalidIdentity }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID), audiences.count == 1 || claims["azp"] as? String == clientID else { throw SIWCError.invalidIdentity }
        if let azp = claims["azp"] as? String, azp != clientID { throw SIWCError.invalidIdentity }
        if let nbf = claims["nbf"] as? Double, nbf > now.timeIntervalSince1970 + 5 { throw SIWCError.invalidIdentity }
        if let nonce, claims["nonce"] as? String != nonce { throw SIWCError.invalidIdentity }
        if let expectedSubject, subject != expectedSubject { throw SIWCError.invalidIdentity }
        return SIWCIdentity(subject: subject, email: claims["email"] as? String)
    }
    private static func integer(_ data: Data) -> Data { tlv(0x02, data.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + data : data) }
    private static func tlv(_ tag: UInt8, _ data: Data) -> Data {
        var length = data.count; var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        let prefix = data.count < 128 ? [UInt8(data.count)] : [0x80 | UInt8(bytes.count)] + bytes
        return Data([tag] + prefix) + data
    }
}

public struct SIWCModel: Codable, Identifiable, Sendable {
    public let slug: String; public let display_name: String; public let visibility: String
    public var id: String { slug }
}
public struct SIWCCatalog: Codable, Sendable { public let models: [SIWCModel] }

public enum SIWCInference {
    public static func body(model: String, catalog: [SIWCModel], png: Data) throws -> Data {
        guard catalog.contains(where: { $0.slug == model && $0.visibility == "list" }), !png.isEmpty else { throw SIWCError.modelUnavailable }
        return try JSONSerialization.data(withJSONObject: ["model": model, "reasoning": ["effort": "none"], "store": false, "stream": true,
            "input": [["role": "user", "content": [["type": "input_text", "text": "Describe only visible shapes and readable text in this synthetic test image. Do not invent barcodes."],
                    ["type": "input_image", "image_url": "data:image/png;base64," + png.base64EncodedString()]]]]])
    }
}
/// Only known machine codes/parameter names may enter persistent diagnostics.
public enum SIWCSafeDiagnostic {
    public static func code(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let known: Set<String> = ["subscription_sharing_user_not_eligible", "subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable", "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported", "subscription_sharing_invalid_user", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context", "subscription_sharing_user_unavailable", "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused", "invalid_client", "invalid_request_error", "invalid_value", "unsupported_value", "unsupported_parameter", "model_not_found", "rate_limit_exceeded", "insufficient_quota", "server_error", "invalid_api_key"]
        return known.contains(raw) ? raw : "unrecognized_error_code"
    }
    public static func parameter(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return ["model", "reasoning.effort", "input", "input_image", "image_url", "store", "stream", "service_tier"].contains(raw) ? raw : "unrecognized_parameter"
    }
}
public struct SIWCStreamFailure: Error, Sendable {
    public let terminal: String
    public let code: String?
    public let parameter: String?
}
public struct SIWCStream {
    /// Observed official direct route can omit Content-Type. Validate the actual
    /// SSE body and completed event; a missing header alone is not a failure.
    public static func acceptsContentType(_ header: String?) -> Bool {
        guard let header else { return true }
        return header.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } == "text/event-stream"
    }
    public private(set) var text = ""
    public private(set) var completed = false
    public private(set) var terminal: String?
    public private(set) var eventCount = 0
    public private(set) var lastEventShape: [String: Bool] = [:]
    private var eventData: [String] = []
    private var eventSize = 0
    private var lineBytes: [UInt8] = []
    private var afterCR = false
    public private(set) var byteCount = 0
    public private(set) var lineCount = 0
    public private(set) var blankLineCount = 0
    public private(set) var commentLineCount = 0
    public private(set) var dataLineCount = 0
    public private(set) var framedEventCount = 0
    /// Counts only: no text, payload, hashes or server identifiers.
    public var safeCounts: [String: Int] {
        ["byteCount": byteCount, "lineCount": lineCount, "blankLineCount": blankLineCount,
         "commentLineCount": commentLineCount, "dataLineCount": dataLineCount,
         "framedEventCount": framedEventCount, "eventCount": eventCount,
         "bufferedLineBytes": lineBytes.count, "bufferedEventBytes": eventSize]
    }
    public init() {}
    /// Preserve SSE's empty lines. Foundation AsyncSequence.lines omits them.
    public mutating func byte(_ byte: UInt8) throws {
        byteCount += 1
        if byte == 10 && afterCR { afterCR = false; return }
        afterCR = false
        if byte == 10 || byte == 13 {
            guard let value = String(bytes: lineBytes, encoding: .utf8) else { throw SIWCError.sseInvalidUTF8 }
            lineBytes.removeAll(keepingCapacity: true)
            try line(value); afterCR = byte == 13
        } else {
            guard lineBytes.count < 1_000_000 else { throw SIWCError.sseSizeLimit }
            lineBytes.append(byte)
        }
    }
    public mutating func line(_ input: String) throws {
        let line = input
        lineCount += 1
        if line.isEmpty { blankLineCount += 1 }
        if line.hasPrefix(":") { commentLineCount += 1 }
        if line.hasPrefix("data:") {
            dataLineCount += 1
            var data = String(line.dropFirst(5)); if data.first == " " { data.removeFirst() }
            eventSize += data.utf8.count + 1
            guard eventSize <= 1_000_000 else { throw SIWCError.sseSizeLimit }
            eventData.append(data)
        } else if line.isEmpty && !eventData.isEmpty {
            let payload = eventData.joined(separator: "\n"); eventData = []; eventSize = 0
            framedEventCount += 1
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8) else { throw SIWCError.sseInvalidUTF8 }
            eventCount += 1
            let object: Any
            do { object = try JSONSerialization.jsonObject(with: data) }
            catch { throw SIWCError.sseInvalidJSON }
            if let value = object as? [String: Any] {
                lastEventShape = ["hasTypeString": value["type"] is String, "hasResponse": value["response"] != nil, "hasObject": value["object"] != nil, "hasError": value["error"] != nil, "hasDelta": value["delta"] != nil]
            }
            guard let event = object as? [String: Any], let type = event["type"] as? String else { throw SIWCError.sseMissingType }
            if ["response.failed", "error", "response.incomplete"].contains(type) {
                terminal = type
                let response = event["response"] as? [String: Any]
                let error = (response?["error"] as? [String: Any]) ?? (event["error"] as? [String: Any]) ?? event
                throw SIWCStreamFailure(terminal: type, code: SIWCSafeDiagnostic.code(error["code"] as? String), parameter: SIWCSafeDiagnostic.parameter(error["param"] as? String))
            }
            if type == "response.output_text.delta" { text += event["delta"] as? String ?? "" }
            if type == "response.completed" { completed = true; terminal = type }
            guard text.utf8.count <= 32768 else { throw SIWCError.sseSizeLimit }
        }
    }
    public mutating func finish() throws -> String {
        // EOF is not an SSE blank-line delimiter. Never synthesize completion
        // from a truncated terminal; retain only buffer counts for diagnosis.
        guard completed else { throw SIWCError.incompleteStream }
        return text
    }
}

/// Shared by the URLSession path and deterministic offline transports. Progress
/// exposes counts/timing/shape only, never model text or response payloads.
public enum SIWCStreamReader {
    @MainActor public static func read(
        nextByte: @MainActor () async throws -> UInt8?,
        progress: ([String: Int], String?, [String: Bool]) -> Void
    ) async throws -> String {
        var parser = SIWCStream()
        let started = ProcessInfo.processInfo.systemUptime
        var milestones: [String: Int] = ["receivedBytes": 0]
        func snapshot() {
            progress(parser.safeCounts.merging(milestones) { _, new in new }, parser.terminal, parser.lastEventShape)
        }
        defer { snapshot() }
        while let byte = try await nextByte() {
            milestones["receivedBytes", default: 0] += 1
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            if milestones["firstByteMS"] == nil { milestones["firstByteMS"] = elapsed }
            milestones["lastByteMS"] = elapsed
            try Task.checkCancellation()
            let previous = parser.eventCount
            try parser.byte(byte)
            if parser.eventCount > previous {
                if milestones["firstEventMS"] == nil { milestones["firstEventMS"] = elapsed }
                milestones["lastEventMS"] = elapsed
            }
            if parser.byteCount == 1 || byte == 10 || byte == 13 || parser.byteCount % 4096 == 0 { snapshot() }
            if parser.completed { break }
        }
        // Cancellation wins even when a transport completes without throwing.
        try Task.checkCancellation()
        return try parser.finish()
    }
}
