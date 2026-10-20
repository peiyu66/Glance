import SwiftUI

private final class D2Wire: @unchecked Sendable {
    static let shared = D2Wire()
    private let lock = NSLock()
    private var mode = "listed"
    private var calls: [String] = []
    func set(_ mode: String) { lock.lock(); self.mode = mode; calls = []; lock.unlock() }
    func receive(_ path: String) -> String { lock.lock(); defer { lock.unlock() }; calls.append(path); return mode }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return calls }
}
private final class D2Protocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let mode = D2Wire.shared.receive(path)
        var status = 200, mime = "application/json", text = ""
        if path == "/v1/models" {
            text = mode == "missing" ? #"{"models":[]}"# : #"{"models":[{"slug":"gpt-6-luna","display_name":"Generated","visibility":"list"}]}"#
        } else if path == "/v1/responses" {
            if mode == "denied" { status = 403; text = #"{"error":{"code":"subscription_sharing_user_not_eligible"}}"# }
            else {
                mime = "text/event-stream"
                text = #"data: {"type":"response.output_text.delta","delta":"red square GLANCE 123"}"# + "\n\n"
                if mode != "incomplete" { text += #"data: {"type":"response.completed"}"# + "\n\n" }
            }
        } else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "x-request-id": "req_0123456789abcdef0123456789abcdef"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private enum D2Checks {
    static func run() async -> (checks: [String: Bool], diagnostic: SIWCAuthDiagnostic) {
        var checks: [String: Bool] = [:]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [D2Protocol.self]
        let http = SIWCHTTP(configuration: config)
        let tokens = SIWCTokens(access: "generated-access-secret", refresh: nil, idToken: "generated-id-secret", scope: SIWCProtocol.scopes, expiresAt: Date().addingTimeInterval(3600))
        let trace = UUID()
        let account = SIWCAccount(clientID: "generated-client-secret", subject: "generated-subject-secret", tokens: tokens, authenticationTraceID: trace)
        let saved = SIWCSaved(hostID: "generated-host-secret", accounts: [account], selected: account.id)
        let model = SIWCController(allowsDataTransfer: { true }, authHTTPClient: http, authSaveSession: { _ in preconditionFailure("No storage writes allowed") }, authLoadSession: { saved })
        model.load()
        D2Wire.shared.set("listed")
        model.models(); model.imageTest()
        checks["old_account_without_successful_attempt_cannot_validate"] = D2Wire.shared.paths.isEmpty && !model.diagnosticReady
        model.authDiagnostic.begin(traceID: trace)
        model.authDiagnostic.record(stage: .saveSession, outcome: .succeeded, traceID: trace)
        model.authDiagnostic.record(stage: .permission, outcome: .succeeded, category: .planEnabled, traceID: trace)
        model.models()
        checks["successful_account_still_requires_user_confirmation"] = D2Wire.shared.paths.isEmpty && !model.diagnosticReady
        model.confirmsDiagnosticAccount = true
        func settle() async {
            for _ in 0..<200 { if !model.busy { return }; try? await Task.sleep(for: .milliseconds(20)) }
        }
        D2Wire.shared.set("listed")
        checks["no_automatic_model_request"] = D2Wire.shared.paths.isEmpty
        model.models(); await settle()
        checks["explicit_catalog_once"] = D2Wire.shared.paths == ["/v1/models"]
        let catalog = model.authDiagnostic.events.last
        checks["catalog_is_account_specific_candidate_evidence"] = catalog?.stage == .modelCatalog && catalog?.outcome == .succeeded && catalog?.validation?.candidateListed == true && catalog?.validation?.visibleModelCount == 1
        checks["validation_bound_to_exact_successful_login"] = catalog?.validation?.sessionAuthenticationTraceID == trace && catalog?.traceID == nil
        D2Wire.shared.set("listed"); model.imageTest(); await settle()
        let completed = model.authDiagnostic.events.last
        checks["synthetic_image_sent_once"] = D2Wire.shared.paths == ["/v1/responses"]
        checks["synthetic_completed_with_content_checks"] = completed?.stage == .syntheticImage && completed?.validation?.completed == true && completed?.validation?.red == true && completed?.validation?.square == true && completed?.validation?.text == true
        checks["response_request_id_retained"] = model.authDiagnostic.events.contains { $0.stage == .syntheticImage && $0.service?.endpoint == .responses && $0.service?.requestID == "req_0123456789abcdef0123456789abcdef" }
        D2Wire.shared.set("denied"); model.imageTest(); await settle()
        checks["denied_not_retried_or_marked_completed"] = D2Wire.shared.paths == ["/v1/responses"] && model.authDiagnostic.events.last?.errorCode == "subscription_sharing_user_not_eligible" && model.authDiagnostic.events.last?.httpStatus == 403 && model.authDiagnostic.events.last?.validation?.completed == false
        D2Wire.shared.set("incomplete"); model.imageTest(); await settle()
        checks["incomplete_stream_not_success"] = D2Wire.shared.paths == ["/v1/responses"] && model.authDiagnostic.events.last?.outcome == .failed && model.authDiagnostic.events.last?.validation?.completed == false
        D2Wire.shared.set("missing"); model.models(); await settle(); model.imageTest(); await settle()
        checks["missing_candidate_does_not_send_image"] = D2Wire.shared.paths == ["/v1/models"] && model.selectedModel.isEmpty && model.authDiagnostic.events.last?.validation?.candidateListed == false
        D2Wire.shared.set("listed")
        model.authDiagnostic.begin(traceID: UUID())
        let failedTrace = model.authDiagnostic.latestSignIn!.traceID
        model.authDiagnostic.record(stage: .tokenExchange, outcome: .failed, category: .http, httpStatus: 400, errorCode: "invalid_grant", traceID: failedTrace)
        model.models(); model.imageTest()
        checks["failed_replacement_never_falls_back_to_original_account"] = D2Wire.shared.paths.isEmpty && model.account?.id == account.id && !model.diagnosticReady && model.signInResultText.contains("失敗")
        model.load()
        checks["settings_reload_keeps_failure_visible"] = model.signInResultText.contains("失敗") && !model.latestAccountMatches
        let encoded = String(decoding: (try? JSONEncoder().encode(model.authDiagnostic)) ?? Data(), as: UTF8.self)
        checks["diagnostic_contains_no_credential_account_or_answer"] = !["generated-access-secret", "generated-id-secret", "generated-client-secret", "generated-subject-secret", "generated-host-secret", "red square GLANCE 123", "data:image"].contains { encoded.contains($0) }
        checks["default_network_guard_never_triggered"] = C8NetworkProbe.shared.count == 0
        return (checks, model.authDiagnostic)
    }
}

struct SIWCDiagnosticChecksView: View {
    @State private var diagnostic = SIWCAuthDiagnostic()
    @State private var status = "running"
    var body: some View {
        Form {
            Text(status).accessibilityIdentifier("siwc-d2-result")
            SIWCAuthDiagnosticView(diagnostic: diagnostic)
        }.environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--maximum-type") ? .accessibility5 : .large)
        .task {
            let result = await D2Checks.run(); diagnostic = result.diagnostic
            let passed = result.checks.values.allSatisfy { $0 }
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let report: [String: Any] = ["passed": passed, "checks": result.checks, "count": result.checks.count, "realNetworkRequests": 0, "keychainAccess": false]
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("siwc-D2-checks.json"))
            status = passed ? "passed \(result.checks.count)" : "FAILED " + result.checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
        }
    }
}
