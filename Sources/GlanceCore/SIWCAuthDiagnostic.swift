import Foundation
import CryptoKit

public enum SIWCAuthStage: String, Codable, Sendable {
    case registration, storage, discovery, listener, browser, callback, tokenExchange, tokenDecode, jwks, identity, saveSession, permission, modelCatalog, syntheticImage
    public var title: String {
        switch self {
        case .registration: "準備登入註冊"
        case .storage: "準備本機會話"
        case .discovery: "取得官方登入設定"
        case .listener: "準備本機回呼"
        case .browser: "官方登入視窗"
        case .callback: "接收登入回呼"
        case .tokenExchange: "交換登入授權"
        case .tokenDecode: "解析授權結果"
        case .jwks: "取得官方驗證金鑰"
        case .identity: "驗證身份與登入綁定"
        case .saveSession: "保存本機會話"
        case .permission: "確認方案權限"
        case .modelCatalog: "讀取目前帳號模型目錄"
        case .syntheticImage: "單次合成圖驗證"
        }
    }
}
public enum SIWCAuthOutcome: String, Codable, Sendable {
    case started, response, succeeded, failed, cancelled, ignored, checked
    public var title: String {
        switch self {
        case .started: "開始"
        case .response: "收到 HTTP 回應"
        case .succeeded: "通過"
        case .failed: "未通過"
        case .cancelled: "已取消"
        case .ignored: "已忽略"
        case .checked: "綁定檢查"
        }
    }
}
public enum SIWCAuthCategory: String, Codable, Sendable {
    case http, transport, browser, userCancelled, callbackRejected, oauthDenied, oauthError
    case invalidResponse, identity, storage, timeout, superseded, repeatedReturn, planEnabled, planDisabled, unknown
    case callbackConsumed, callbackExpired, callbackShape, callbackState, callbackClient, callbackMissingCode
    public var title: String {
        switch self {
        case .http: "官方 HTTP 錯誤"
        case .transport: "網路傳輸未完成（沒有 HTTP 狀態不代表 404）"
        case .browser: "系統登入視窗錯誤"
        case .userCancelled: "登入操作已取消"
        case .callbackRejected: "回呼未通過檢查"
        case .oauthDenied: "官方回呼表示未授權（不推定由本人拒絕）"
        case .oauthError: "官方回呼回報錯誤"
        case .invalidResponse: "回應格式未通過"
        case .identity: "簽章或身份綁定未通過"
        case .storage: "本機會話讀寫未完成"
        case .timeout: "登入嘗試逾時"
        case .superseded: "舊嘗試的事件"
        case .repeatedReturn: "重複返回；未再次處理"
        case .planEnabled: "身份及方案權限已通過"
        case .planDisabled: "身份已通過，未授予方案權限"
        case .unknown: "未分類錯誤"
        case .callbackConsumed: "回呼已使用"
        case .callbackExpired: "回呼已過期"
        case .callbackShape: "回呼格式或路徑不符"
        case .callbackState: "回呼狀態綁定不符"
        case .callbackClient: "回呼 client 綁定不符或缺少"
        case .callbackMissingCode: "回呼缺少有效授權碼"
        }
    }
}

/// Versioned, closed vocabulary. Raw descriptions, response bodies and arbitrary
/// strings cannot be represented or serialized by this type.
public struct SIWCErrorDescriptionDiagnostic: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case legacyNotRecorded, absent, presentEmpty, presentSanitized, presentSuppressed, unreadable
    }
    public enum Reason: String, Codable, Sendable {
        case unrecognizedText, sensitiveContent, descriptionTooLong
        case invalidJSON, nonObjectJSON, invalidType, ambiguousFields, bodyTooLarge
    }
    public enum SafeMessage: String, Codable, Sendable, CaseIterable {
        case invalidAuthorizationCode, authorizationCodeExpired, invalidGrant, invalidRequest, accessDenied
        public var text: String {
            switch self {
            case .invalidAuthorizationCode: "Invalid authorization code"
            case .authorizationCodeExpired: "Authorization code has expired"
            case .invalidGrant: "Invalid grant"
            case .invalidRequest: "Invalid request"
            case .accessDenied: "Access denied"
            }
        }
    }
    public let version: Int
    public let state: State
    public let safeMessage: SafeMessage?
    public let reason: Reason?
    private init(_ state: State, safeMessage: SafeMessage? = nil, reason: Reason? = nil) {
        version = 1; self.state = state; self.safeMessage = safeMessage; self.reason = reason
    }
    public static var legacyNotRecorded: Self { .init(.legacyNotRecorded) }
    /// Only for a fresh HTTP token error. A missing key is established only after
    /// bounded JSON parsing succeeds. Non-JSON/incorrect types never imply absence.
    public static func tokenResponse(_ data: Data) -> Self {
        guard data.count <= 65_536 else { return .init(.unreadable, reason: .bodyTooLarge) }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .init(.unreadable, reason: .invalidJSON)
        }
        guard let root = value as? [String: Any] else { return .init(.unreadable, reason: .nonObjectJSON) }
        let nested = root["error"] as? [String: Any]
        let rootPresent = root.keys.contains("error_description")
        let nestedPresent = nested?.keys.contains("error_description") == true
        guard !(rootPresent && nestedPresent) else { return .init(.unreadable, reason: .ambiguousFields) }
        guard rootPresent || nestedPresent else { return .init(.absent) }
        guard let text = (rootPresent ? root["error_description"] : nested?["error_description"]) as? String else {
            return .init(.unreadable, reason: .invalidType)
        }
        return classify(text)
    }
    /// Caller must validate callback state, shape and unique query keys first.
    /// A present key without a value is malformed, distinct from an empty value.
    public static func validatedCallback(present: Bool, value: String?) -> Self {
        guard present else { return .init(.absent) }
        guard let value else { return .init(.unreadable, reason: .invalidType) }
        return classify(value)
    }
    private static func classify(_ raw: String) -> Self {
        guard raw.utf8.count <= 1_024, raw.count <= 512 else {
            return .init(.presentSuppressed, reason: .descriptionTooLong)
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .init(.presentEmpty) }
        // Whole-string matches only: never preserve an arbitrary suffix, identifier,
        // URL or token. Output comes from the fixed enum, never from the input.
        if let message = SafeMessage.allCases.first(where: { $0.text.lowercased() == text.lowercased() }) {
            return .init(.presentSanitized, safeMessage: message)
        }
        let lower = text.lowercased()
        let sensitive = ["@", "://", "bearer ", "token", "secret", "cookie", "code=", "client_id", "verifier", "eyj"]
            .contains(where: lower.contains)
        return .init(.presentSuppressed, reason: sensitive ? .sensitiveContent : .unrecognizedText)
    }
    public var text: String {
        switch state {
        case .legacyNotRecorded: return "錯誤描述：舊版未保存，服務是否提供未知"
        case .absent: return "錯誤描述：已解析本次回應，服務未提供此欄位"
        case .presentEmpty: return "錯誤描述：服務提供空值"
        case .presentSanitized: return "錯誤描述（安全分類）：" + (safeMessage?.text ?? "未知")
        case .presentSuppressed:
            let label = switch reason {
            case .descriptionTooLong: "超出長度上限"
            case .sensitiveContent: "含可能敏感內容"
            default: "不在固定安全文字清單"
            }
            return "錯誤描述：已提供但抑制保存（" + label + "）"
        case .unreadable:
            let label = switch reason {
            case .bodyTooLarge: "回應超出解析上限"
            case .invalidJSON: "不是可解析的 JSON"
            case .nonObjectJSON: "JSON 不是物件"
            case .invalidType: "欄位型別不符"
            case .ambiguousFields: "描述欄位位置不唯一"
            default: "無法判讀"
            }
            return "錯誤描述：無法判讀（" + label + "），不可推定未提供"
        }
    }
}

/// Contains classifications only. Raw callback fields must never enter this value.
public struct SIWCCallbackDiagnostic: Sendable {
    public let accepted: Bool
    public let category: SIWCAuthCategory?
    public let errorCode: String?
    public let errorDescription: SIWCErrorDescriptionDiagnostic?
    public init(accepted: Bool, category: SIWCAuthCategory? = nil, errorCode: String? = nil,
                errorDescription: SIWCErrorDescriptionDiagnostic? = nil) {
        self.accepted = accepted; self.category = category
        self.errorCode = SIWCAuthDiagnostic.safeCode(errorCode)
        self.errorDescription = errorDescription
    }
}

public struct SIWCAuthDiagnostic: Codable, Sendable {
    public static let revision = "D2"
    public struct Event: Codable, Identifiable, Sendable {
        public let id: Int
        public let attempt: Int
        public let recordedAt: Date
        public let stage: SIWCAuthStage
        public let outcome: SIWCAuthOutcome
        public let category: SIWCAuthCategory?
        public let httpStatus: Int?
        public let errorCode: String?
        public let numericCode: Int?
        public let binding: SIWCAuthBindingChecks?
        public let traceID: UUID?
        public let elapsedMilliseconds: Int?
        public let service: SIWCServiceDiagnostic?
        public let validation: SIWCValidationEvidence?
        public let errorDescription: SIWCErrorDescriptionDiagnostic?
        /// Old JSON has no field. Do not retrospectively claim server absence.
        public var errorDescriptionDiagnostic: SIWCErrorDescriptionDiagnostic? {
            if let errorDescription { return errorDescription }
            guard outcome == .failed,
                  (stage == .tokenExchange && category == .http) ||
                  (stage == .callback && (category == .oauthDenied || category == .oauthError)) else { return nil }
            return .legacyNotRecorded
        }
        public var text: String {
            var parts = [stage.title, outcome.title]
            if let httpStatus { parts.append("HTTP \(httpStatus)") }
            if let category { parts.append(category.title) }
            if let errorCode { parts.append(errorCode) }
            if let description = errorDescriptionDiagnostic { parts.append(description.text) }
            if let numericCode { parts.append("系統代碼 \(numericCode)") }
            if let binding { parts.append(binding.text) }
            if let elapsedMilliseconds { parts.append("本次經過 \(elapsedMilliseconds) ms") }
            if let service {
                parts.append("端點：" + service.endpoint.rawValue)
                if let id = service.requestID { parts.append("服務 request ID：" + id) }
            }
            if let validation {
                if let count = validation.visibleModelCount { parts.append("可列模型 \(count) 個") }
                if let listed = validation.candidateListed { parts.append("gpt-6-luna：" + (listed ? "有列出" : "未列出")) }
                if let completed = validation.completed { parts.append(completed ? "已收到完整終止事件" : "未確認完整終止事件") }
            }
            return parts.joined(separator: " · ")
        }
    }
    public struct SignIn: Codable, Sendable {
        public enum Outcome: String, Codable, Sendable { case inProgress, succeeded, failed, cancelled }
        public let traceID: UUID
        public var outcome: Outcome = .inProgress
        public var stage: SIWCAuthStage = .registration
        public var updatedAt: Date = Date()
        public var sameSubjectAsPrevious: Bool?
        public var failure: Event?
    }
    public private(set) var latestSignIn: SignIn?
    public private(set) var attempt = 0
    public private(set) var events: [Event] = []
    private var sequence = 0
    public init() {}
    public mutating func begin(traceID: UUID? = nil) {
        attempt += 1
        latestSignIn = traceID.map { SignIn(traceID: $0) }
    }
    public mutating func recordIdentityComparison(sameSubjectAsPrevious: Bool?) {
        latestSignIn?.sameSubjectAsPrevious = sameSubjectAsPrevious
    }
    public var latestSignInEvents: [Event] {
        if let latestSignIn { return events.filter { $0.traceID == latestSignIn.traceID || $0.validation?.sessionAuthenticationTraceID == latestSignIn.traceID } }
        return events.filter { $0.attempt == attempt }
    }
    public var signInResultText: String {
        guard let latestSignIn else {
            if let terminal = events.last(where: { $0.attempt == attempt && ![.modelCatalog, .syntheticImage].contains($0.stage) && [.failed, .cancelled].contains($0.outcome) }) {
                return "先前登入未完成：" + terminal.text
            }
            return "尚無可核對的最近換帳戶結果。"
        }
        switch latestSignIn.outcome {
        case .inProgress: return "最近更換尚未確認完成。"
        case .succeeded: return "最近更換成功；新會話已保存。"
        case .failed: return "最近更換失敗；停在「\(latestSignIn.stage.title)」。原帳戶若仍有效，可繼續使用。"
        case .cancelled: return "最近更換已取消；未切換帳戶。"
        }
    }
    public mutating func record(stage: SIWCAuthStage, outcome: SIWCAuthOutcome,
                                category: SIWCAuthCategory? = nil, httpStatus: Int? = nil,
                                errorCode: String? = nil, numericCode: Int? = nil, binding: SIWCAuthBindingChecks? = nil, traceID: UUID? = nil,
                                elapsedMilliseconds: Int? = nil, service: SIWCServiceDiagnostic? = nil,
                                validation: SIWCValidationEvidence? = nil,
                                errorDescription: SIWCErrorDescriptionDiagnostic? = nil, at: Date = Date()) {
        if let traceID, latestSignIn?.traceID == traceID, ![.modelCatalog, .syntheticImage].contains(stage), outcome != .ignored {
            latestSignIn?.stage = stage; latestSignIn?.updatedAt = at
            if outcome == .failed { latestSignIn?.outcome = .failed }
            else if outcome == .cancelled { latestSignIn?.outcome = .cancelled }
            else if stage == .permission && outcome == .succeeded && category == .planEnabled { latestSignIn?.outcome = .succeeded }
        }
        sequence += 1
        events.append(Event(id: sequence, attempt: attempt, recordedAt: at, stage: stage, outcome: outcome,
                            category: category, httpStatus: httpStatus.flatMap { (100...599).contains($0) ? $0 : nil },
                            errorCode: Self.safeCode(errorCode), numericCode: numericCode, binding: binding, traceID: traceID,
                            elapsedMilliseconds: elapsedMilliseconds.map { max(0, $0) }, service: service, validation: validation,
                            errorDescription: errorDescription))
        if let traceID, latestSignIn?.traceID == traceID, ![.modelCatalog, .syntheticImage].contains(stage), [.failed, .cancelled].contains(outcome) {
            latestSignIn?.failure = events.last
        }
        if events.count > 64 { events.removeFirst(events.count - 64) }
    }
    public static func safeCode(_ code: String?) -> String? {
        guard let code else { return nil }
        let oauth: Set<String> = ["access_denied", "invalid_request", "invalid_scope", "unauthorized_client", "unsupported_response_type", "server_error", "temporarily_unavailable", "login_required", "interaction_required", "consent_required", "3p_login_workspace_scope_denied"]
        return oauth.contains(code) ? code : SIWCSafeDiagnostic.code(code)
    }
}

public enum SIWCAuthClientSource: String, Codable, Sendable {
    case newRegistration, savedAccount, retainedRetry
    public var title: String { switch self {
    case .newRegistration: "新註冊"
    case .savedAccount: "已保存帳戶"
    case .retainedRetry: "保留的重試client"
    } }
}
/// Fixed schema: values are comparisons only, never the values being compared.
public struct SIWCAuthBindingChecks: Codable, Sendable {
    public var retryAvailable: Bool?
    public var retryBudgetConsumed: Bool?
    public var retryStatePersisted: Bool?
    public var sameAccountWorkspaceConfirmedByUser: Bool?
    public var clientSource: SIWCAuthClientSource?
    public var controllerAttempt: Int?
    public var exchangeOrdinal: Int?
    public var callbackStateValidated: Bool?
    public var authorizationStateMatches: Bool?
    public var authorizationNonceMatches: Bool?
    public var authorizationPKCEMatches: Bool?
    public var authorizationRedirectMatches: Bool?
    public var authorizationClientMatches: Bool?
    public var authorizationContextAvailable: Bool?
    public var tokenClientMatches: Bool?
    public var tokenCodeMatches: Bool?
    public var tokenPKCEMatches: Bool?
    public var tokenRedirectMatches: Bool?
    public var tokenResourceMatches: Bool?
    public var tokenMethodAndFormatMatches: Bool?
    public var registrationCheckpointMatches: Bool?
    public var codePreviouslySubmittedInWindow: Bool?
    public var codeComparisonWindowCount: Int?
    public var authorizationToCallbackMilliseconds: Int?
    public var callbackToExchangeMilliseconds: Int?
    public init() {}
    public var text: String {
        var parts = ["綁定診斷 B2"]
        if let clientSource { parts.append("client來源：" + clientSource.title) }
        if let retryAvailable { parts.append(retryAvailable ? "可由本人確認後續試一次" : "沒有可用續試機會") }
        if let retryBudgetConsumed { parts.append(retryBudgetConsumed ? "續試機會已使用" : "尚未使用續試機會") }
        if let retryStatePersisted { parts.append(retryStatePersisted ? "續試狀態已保存" : "續試狀態保存失敗") }
        if let sameAccountWorkspaceConfirmedByUser { parts.append(sameAccountWorkspaceConfirmedByUser ? "本人確認同帳號與工作區（非服務端驗證）" : "本人尚未確認同帳號與工作區") }
        if let controllerAttempt { parts.append("本頁第\(controllerAttempt)次") }
        if let exchangeOrdinal { parts.append("本次交換第\(exchangeOrdinal)筆") }
        if let value = codePreviouslySubmittedInWindow { parts.append("本控制器最近64筆是否重複授權碼：" + (value ? "是" : "否")) }
        if let value = callbackToExchangeMilliseconds { parts.append("回呼至交換 \(value) ms") }
        for (name,value) in [("回呼state",callbackStateValidated),("授權state",authorizationStateMatches),
            ("授權nonce",authorizationNonceMatches),("授權PKCE",authorizationPKCEMatches),
            ("授權redirect",authorizationRedirectMatches),("授權client",authorizationClientMatches),
            ("授權上下文存在",authorizationContextAvailable),("交換client",tokenClientMatches),("交換code",tokenCodeMatches),("交換PKCE",tokenPKCEMatches),
            ("交換redirect",tokenRedirectMatches),("交換resource",tokenResourceMatches),
            ("POST表單格式",tokenMethodAndFormatMatches),("當次註冊checkpoint",registrationCheckpointMatches)] {
            if let value { parts.append(name + (value ? "一致" : "不一致")) }
        }
        return parts.joined(separator:"；")
    }
}

public enum SIWCAuthBindingInspector {
    private static func query(_ url: URL) -> [String:String]? {
        guard let items=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems,
              Set(items.map(\.name)).count == items.count, items.allSatisfy({$0.value != nil}) else { return nil }
        return Dictionary(uniqueKeysWithValues:items.map{($0.name,$0.value!)})
    }
    /// Interprets form encoding independently of SIWCProtocol.form; rejects duplicate fields.
    private static func form(_ data: Data?) -> [String:String]? {
        guard let data, let text=String(data:data,encoding:.utf8) else { return nil }
        var values:[String:String]=[:]
        for field in text.split(separator:"&",omittingEmptySubsequences:false) {
            let parts=field.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
            guard parts.count==2,
                  let key=String(parts[0]).replacingOccurrences(of:"+",with:" ").removingPercentEncoding,
                  let value=String(parts[1]).replacingOccurrences(of:"+",with:" ").removingPercentEncoding,
                  values[key]==nil else { return nil }
            values[key]=value
        }
        return values
    }
    public static func authorization(url:URL,pending:SIWCPending) -> SIWCAuthBindingChecks {
        let q=query(url);var result=SIWCAuthBindingChecks()
        result.authorizationStateMatches=q?["state"]==pending.state
        result.authorizationNonceMatches=q?["nonce"]==pending.nonce
        result.authorizationPKCEMatches=q?["code_challenge"]==SIWCProtocol.challenge(pending.verifier) && q?["code_challenge_method"]=="S256"
        result.authorizationRedirectMatches=q?["redirect_uri"]==pending.redirect
        result.authorizationClientMatches=q?["client_id"]==(pending.clientID ?? "dynamic_agent_client")
        return result
    }
    public static func exchange(request:URLRequest,authorizationURL:URL?,pending:SIWCPending,code:String,issued:String) -> SIWCAuthBindingChecks {
        let q=authorizationURL.flatMap(query);let body=form(request.httpBody);var result=SIWCAuthBindingChecks()
        result.authorizationContextAvailable = q != nil
        // nil records unavailable context rather than incorrectly asserting equality.
        result.tokenClientMatches=body?["client_id"]==issued && (pending.clientID == nil || issued==pending.clientID)
        result.tokenCodeMatches=body?["code"]==code
        if let q {
            result.tokenPKCEMatches=body?["code_verifier"]==pending.verifier && q["code_challenge"] != nil && body?["code_verifier"].map(SIWCProtocol.challenge)==q["code_challenge"] && q["code_challenge_method"]=="S256"
            result.tokenRedirectMatches=body?["redirect_uri"]==pending.redirect && body?["redirect_uri"]==q["redirect_uri"]
            result.tokenResourceMatches=body?["resource"]==SIWCProtocol.resource && body?["resource"]==q["resource"]
        }
        result.tokenMethodAndFormatMatches=request.httpMethod=="POST" && request.value(forHTTPHeaderField:"Content-Type")=="application/x-www-form-urlencoded" && body?["grant_type"]=="authorization_code" && request.url?.absoluteString==SIWCProtocol.issuer+"/api/accounts/oauth/token"
        return result
    }
}


/// Only known endpoints and strictly shaped service correlation IDs may leave the HTTP layer.
/// No response body, URL, auth parameters, account/client identifiers or arbitrary headers.
public struct SIWCServiceDiagnostic: Codable, Sendable, Equatable {
    public enum Endpoint: String, Codable, Sendable { case token, models, responses, discovery, jwks, other }
    public enum RequestIDState: String, Codable, Sendable { case absent, retained, omittedUnrecognized }
    public let endpoint: Endpoint
    public let status: Int
    public let requestID: String?
    public let requestIDState: RequestIDState
    public init(endpoint: Endpoint, status: Int, rawRequestID: String?) {
        self.endpoint = endpoint; self.status = status
        self.requestID = Self.safeRequestID(rawRequestID)
        requestIDState = rawRequestID == nil ? .absent : requestID == nil ? .omittedUnrecognized : .retained
    }
    public static func safeRequestID(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 68 else { return nil }
        // Service-generated req_<32 hex> and UUID are correlation values, never credentials.
        if raw.range(of: #"^req_[0-9a-fA-F]{32}$"#, options: .regularExpression) != nil { return raw }
        if raw.count == 36, let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw.lowercased() { return raw }
        return nil
    }
}

/// A bounded, memory-only equality probe. Salt/digests are never Codable or written to disk.
/// A negative result covers only this controller's last 64 observed submissions, not prior launches.
public struct SIWCAuthCodeObservation: Sendable {
    private let salt = UUID().uuidString
    private var recent: [Data] = []
    public init() {}
    public mutating func observe(_ code: String) -> (previouslySubmitted: Bool, comparedCount: Int) {
        let digest = Data(SHA256.hash(data: Data((salt + "\0" + code).utf8)))
        let result = (recent.contains(digest), recent.count)
        recent.append(digest)
        if recent.count > 64 { recent.removeFirst(recent.count - 64) }
        return result
    }
}

/// Explicit model-list / generated-image actions only. No answer text or dynamic model names.
public struct SIWCValidationEvidence: Codable, Sendable {
    public let operationID: UUID
    public var sessionAuthenticationTraceID: UUID?
    public var visibleModelCount: Int?
    public var candidateListed: Bool?
    public var completed: Bool?
    public var red: Bool?
    public var square: Bool?
    public var text: Bool?
    public init(operationID: UUID) { self.operationID = operationID }
}
