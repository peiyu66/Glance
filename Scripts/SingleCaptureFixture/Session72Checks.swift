// Appended to the isolated SIWCView copy. Every URL is intercepted; no Keychain.
private final class Session72Wire: @unchecked Sendable {
    static let shared = Session72Wire()
    private let lock = NSLock()
    private var count = 0
    var refreshes: Int { lock.lock(); defer { lock.unlock() }; return count }
    func reset() { lock.lock(); count = 0; lock.unlock() }
    func response(_ url: URL) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        if url.path == "/.well-known/openid-configuration" {
            let base = SIWCProtocol.issuer
            let value = ["issuer":base,"authorization_endpoint":base+"/api/accounts/authorize","token_endpoint":base+"/api/accounts/oauth/token","jwks_uri":base+"/.well-known/jwks.json","revocation_endpoint":base+"/oauth/revoke"]
            return (200, try! JSONSerialization.data(withJSONObject:value))
        }
        if url.path == "/api/accounts/oauth/token" {
            count += 1
            return (200,Data(#"{"access_token":"synthetic-next-access","refresh_token":"synthetic-next-refresh","token_type":"Bearer","expires_in":3600}"#.utf8))
        }
        if url.path.hasSuffix("/models") {
            return (200,Data(#"{"models":[{"slug":"gpt-6-luna","display_name":"synthetic","visibility":"list"}]}"#.utf8))
        }
        return (599, Data()) // fail closed for every unplanned endpoint
    }
}
private final class Session72Protocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Session72Wire.shared.response(request.url!)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension SIWCController {
@MainActor static func runSession72Checks() async -> [String:Bool] {
    var checks:[String:Bool] = [:]
    let epoch = UUID()
    func make(_ seconds: Double, earliest: Bool = false) -> SIWCController {
        let tokens = SIWCTokens(access:"synthetic-old-access", refresh:"synthetic-old-refresh", idToken:"synthetic-id", scope:SIWCProtocol.scopes, expiresAt:Date().addingTimeInterval(seconds), earliestRefreshAt:earliest ? Date().addingTimeInterval(600) : nil)
        let account = SIWCAccount(clientID:"synthetic-client", subject:"synthetic-subject", tokens:tokens)
        var memory = SIWCSaved(hostID:"synthetic-host", accounts:[account], selected:account.id)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Session72Protocol.self]
        let model = SIWCController(dataTransferRevision:{epoch}, allowsDataTransfer:{true}, authHTTPClient:SIWCHTTP(configuration:config), authSaveSession:{memory=$0}, authLoadSession:{memory}, reviewHTTPClient:{SIWCHTTP(configuration:config)})
        // No load() filesystem cleanup: simulate the already-loaded in-memory session.
        model.saved = memory; model.selectedID = account.id
        return model
    }
    for seconds in [-1.0, 0, 1, 30, 59, 60, 61, 3600] {
        Session72Wire.shared.reset(); let model = make(seconds)
        do {
            let tokens = try await model.usableTokens(validate:{})
            checks["session72_boundary_\(seconds)"] = tokens.access == (seconds <= 60 ? "synthetic-next-access" : "synthetic-old-access") && model.refreshCount == (seconds <= 60 ? 1 : 0)
        } catch { checks["session72_boundary_\(seconds)"] = false }
    }
    do {
        let model = make(30, earliest:true)
        let tokens = try await model.usableTokens(validate:{})
        checks["session72_early_refresh_reuses_valid"] = tokens.access == "synthetic-old-access" && model.refreshCount == 0
        let expired = make(-1, earliest:true)
        do { _ = try await expired.usableTokens(validate:{}); checks["session72_expired_early_rejected"] = false }
        catch { checks["session72_expired_early_rejected"] = error is SIWCExistingGrantSession.Failure }
    } catch { checks["session72_earliest"] = false }
    do {
        Session72Wire.shared.reset(); let model = make(30)
        let first = Task { try await model.usableTokens(validate:{}) }
        let second = Task { try await model.usableTokens(validate:{}) }
        let a = try await first.value; let b = try await second.value
        checks["session72_concurrent_rotation_once"] = a.access == b.access && model.refreshCount == 1 && Session72Wire.shared.refreshes == 1
        let cancelled = Task { try await model.usableTokens(validate:{ throw CancellationError() }) }
        do { _ = try await cancelled.value; checks["session72_cancel_before_request"] = false }
        catch { checks["session72_cancel_before_request"] = error is CancellationError && model.refreshCount == 1 }
    } catch { checks["session72_concurrency"] = false }
    for changeAccount in [false, true] {
        Session72Wire.shared.reset(); let model = make(30)
        model.sessionLocked = true
        let queued = Task { try await model.usableTokens(validate:{}) }
        for _ in 0..<100 where model.sessionWaiters.isEmpty { await Task.yield() }
        guard !model.sessionWaiters.isEmpty else { queued.cancel(); checks["session72_queue_created"] = false; continue }
        if changeAccount { model.selectedID = "synthetic-different-account" } else { queued.cancel() }
        model.sessionWaiters.removeFirst().resume()
        do { _ = try await queued.value; checks["session72_queue_\(changeAccount)"] = false }
        catch { checks["session72_queue_\(changeAccount)"] = error is CancellationError && Session72Wire.shared.refreshes == 0 && !model.sessionLocked }
    }
    // Exercise the actual continuation entry; stop at willSend, before any model transport.
    for earliest in [false,true] {
        let model = make(30, earliest:earliest)
        if earliest { model.catalog = [SIWCModel(slug:"gpt-6-luna",display_name:"synthetic",visibility:"list")] }
        var admitted = false
        do {
            _ = try await model.reviewWikipedia(input:Data(#"{"input_version":3,"stage_one":{},"raw_stage_one_json":null,"sources":[]}"#.utf8), validate:{}, willSend:{ admitted = true; throw CancellationError() }, transportStarted:{})
        } catch {}
        checks["session72_continuation_\(earliest)"] = !model.catalog.isEmpty && admitted && model.refreshCount == (earliest ? 0 : 1)
    }
    return checks
}

}
