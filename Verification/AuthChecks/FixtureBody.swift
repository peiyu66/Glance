

// Appended in the same source file to exercise actual private controller methods.
import AppKit
final class AuthFixtureWire: @unchecked Sendable {
    static let shared=AuthFixtureWire()
    private let lock=NSLock()
    private var requests:[URLRequest]=[]
    private var responses:[String:Data]=[:]
    private var tokenErrorBody:Data?
    private var tokenDelay:TimeInterval=0
    func setTokenDelay(_ value:TimeInterval) { lock.lock();tokenDelay=value;lock.unlock() }
    func delay()->TimeInterval { lock.lock();defer{lock.unlock()};return tokenDelay }
    func setResponses(_ values:[String:Data]) { lock.lock();responses=values;lock.unlock() }
    func response(_ path:String)->Data? { lock.lock();defer{lock.unlock()};return responses[path] }
    func setTokenErrorBody(_ data:Data?) { lock.lock();tokenErrorBody=data;lock.unlock() }
    func errorBody()->Data? { lock.lock();defer{lock.unlock()};return tokenErrorBody }
    func append(_ r:URLRequest) { lock.lock();requests.append(r);lock.unlock() }
    func snapshot()->[URLRequest] { lock.lock();defer{lock.unlock()};return requests }
}
final class AuthFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        var r=request
        if r.httpBody == nil, let stream=r.httpBodyStream {
            stream.open();defer{stream.close()};var data=Data();var buffer=[UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(contentsOf:buffer.prefix(n)) }
            r.httpBody=data
        }
        AuthFixtureWire.shared.append(r)
        let path=r.url?.path ?? ""
        if path == "/api/accounts/oauth/token", let data = AuthFixtureWire.shared.errorBody() {
            let response=HTTPURLResponse(url:r.url!,statusCode:400,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json", "x-request-id":"req_0123456789abcdef0123456789abcdef"])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self);return
        }
        if let data = AuthFixtureWire.shared.response(path) {
            if path == "/api/accounts/oauth/token" { Thread.sleep(forTimeInterval:AuthFixtureWire.shared.delay()) }
            let response=HTTPURLResponse(url:r.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json", "x-request-id":"req_0123456789abcdef0123456789abcdef"])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self);return
        }
        let value:[String:Any];let status:Int
        if path=="/.well-known/openid-configuration" {
            status=200;value=["issuer":SIWCProtocol.issuer,"authorization_endpoint":SIWCProtocol.issuer+"/api/accounts/authorize","token_endpoint":SIWCProtocol.issuer+"/api/accounts/oauth/token","jwks_uri":SIWCProtocol.issuer+"/.well-known/jwks.json","revocation_endpoint":SIWCProtocol.issuer+"/api/accounts/oauth/revoke"]
        } else if path=="/api/accounts/oauth/token" {
            status=400;value=["error":"invalid_grant","error_description":"generated fixture only"]
        } else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        let response=HTTPURLResponse(url:r.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json", "x-request-id":"req_0123456789abcdef0123456789abcdef"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor extension SIWCController {
    func contractAttempt(number:Int,code:String,issued:String,signedSubject:String?=nil,invalidNonce:Bool=false,scope:String=SIWCProtocol.scopes) async throws -> (SIWCPending,URL,SIWCAuthClientSource) {
        try prepareRegistrationAttempt(); let tx=UUID();attempt=tx;busy=true;prepareAuthDiagnostics()
        discovery=try await SIWCDiscovery.load(http:authHTTPClient)
        let selection=authClientSelection()
        var pending=SIWCPending(state:try SIWCProtocol.random(),nonce:try SIWCProtocol.random(),verifier:try SIWCProtocol.random(),port:UInt16(54320+number),clientID:selection.id,deadline:Date().addingTimeInterval(300))
        let url=pending.authorize(hostID:saved!.hostID)
        recordAuthorizationBindings(url:url,pending:pending)
        var callbackFields=["state":pending.state,"code":code]
        if selection.id == nil { callbackFields["client_id"]=issued }
        let callback="/auth/callback?"+String(decoding:SIWCProtocol.form(callbackFields),as:UTF8.self)
        let returned=try pending.callback(target:callback)
        authCallbackAt = ProcessInfo.processInfo.systemUptime
        if let signedSubject {
            let signer = try AuthSuccessSigningFixture()
            let token = try signer.token(["sub":signedSubject,"aud":returned.clientID,"nonce":invalidNonce ? "generated-wrong-nonce" : pending.nonce])
            let response = try JSONSerialization.data(withJSONObject:["access_token":"generated-access", "refresh_token":"generated-refresh", "id_token":token, "token_type":"Bearer", "expires_in":3600, "scope":scope])
            AuthFixtureWire.shared.setResponses(["/api/accounts/oauth/token":response,"/.well-known/jwks.json":signer.jwks])
        }
        defer { AuthFixtureWire.shared.setResponses([:]) }
        await exchange(pending:pending,code:returned.code,issued:returned.clientID,selected:nil,transaction:tx)
        return (pending,url,selection.source)
    }
    func contractDenial() throws {
        try prepareRegistrationAttempt();attempt=UUID();busy=true;prepareAuthDiagnostics()
        loopbackReturned(.failure(SIWCLoopbackDenial(diagnostic:.init(accepted:false,category:.oauthDenied,errorCode:"access_denied"))),selected:nil,transaction:attempt)
    }
    func contractDescriptionDenial(_ value: String?, includeField: Bool = true) throws {
        try prepareRegistrationAttempt(); attempt=UUID(); busy=true; prepareAuthDiagnostics()
        var pending = SIWCPending(state:"generated-description-state", nonce:"generated-description-nonce",
                                  verifier:"generated-description-verifier", port:54321, clientID:nil,
                                  deadline:Date().addingTimeInterval(300))
        var fields = ["state":pending.state, "error":"access_denied"]
        if includeField { fields["error_description"] = value ?? "" }
        var detail:SIWCCallbackDiagnostic?
        do { _ = try pending.callback(target:"/auth/callback?" + String(decoding:SIWCProtocol.form(fields),as:UTF8.self), diagnostic:{detail=$0}) }
        catch SIWCError.denied {
            loopbackReturned(.failure(SIWCLoopbackDenial(diagnostic:try fixtureRequire(detail))),selected:nil,transaction:attempt)
            return
        }
        throw SIWCError.invalidResponse
    }
    func contractState()->(retry:String?,source:SIWCAuthClientSource,active:Bool,exchangeCount:Int,controllerCount:Int) {
        (nil,authClientSelection().source,authActive,authExchangeOrdinal,authControllerAttempt)
    }
}
@main struct AuthBindingFixtureMain {
    @MainActor static func main() async throws {
        precondition(ProcessInfo.processInfo.arguments.contains("--siwc-auth-fixture"))
        var checks:[String:Bool]=[:]
        func check(_ name:String,_ value:Bool){checks[name]=value}
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[AuthFixtureURLProtocol.self]
        let http=SIWCHTTP(configuration:config);var storageWrites=0
        let model=SIWCController(authHTTPClient:http,authSaveSession:{ _ in storageWrites+=1 })
        model.saved=SIWCSaved(hostID:"generated-host-marker",accounts:[],selected:nil)
        let issued="generated-issued-client-marker", code1="generated-code-one+ /?=&%",code2="generated-code-two+ /?=&%"
        let first=try await model.contractAttempt(number:1,code:code1,issued:issued)
        check("first_uses_dynamic",first.2 == .newRegistration)
        check("S1_issued_metadata_preserved_after_http400",model.pendingRegistrations.first?.clientID==issued)
        check("real_endAttempt_clears_busy_active",!model.busy && !model.contractState().active)
        check("S1_failure_never_reuses_pending_for_next_replacement",model.contractState().source == .newRegistration && model.contractState().retry == nil)
        let second=try await model.contractAttempt(number:2,code:code2,issued:issued)
        check("S1_second_replacement_always_dynamic",second.2 == .newRegistration && second.0.clientID==nil)
        check("fresh_pending_state_nonce_pkce",first.0.state != second.0.state && first.0.nonce != second.0.nonce && first.0.verifier != second.0.verifier)
        check("controller_attempt_counter",model.contractState().controllerCount==2)
        check("one_exchange_per_attempt",model.contractState().exchangeCount==1)
        check("metadata_checkpoint_on_rejected_exchange",storageWrites==2 && model.saved?.accounts.isEmpty==true && model.saved?.pendingRegistrations.count==2)
        let wire=AuthFixtureWire.shared.snapshot();let tokens=wire.filter{$0.url?.path=="/api/accounts/oauth/token"}
        check("actual_urlsession_intercepted_four_requests",wire.count==4 && tokens.count==2)
        let failures=model.authDiagnostic.events.filter{$0.stage == .tokenExchange && $0.outcome == .failed}
        check("both_real_http_errors_classified",failures.count==2 && failures.allSatisfy{$0.httpStatus==400 && $0.errorCode=="invalid_grant"})
        let bindings=model.authDiagnostic.events.compactMap(\.binding)
        let sources=bindings.compactMap(\.clientSource)
        check("S1_source_diagnostics_always_new_registration",sources == [.newRegistration,.newRegistration])
        let exchangeBindings=bindings.filter{$0.exchangeOrdinal != nil}
        check("actual_transport_bindings_all_match",exchangeBindings.count==2 && exchangeBindings.allSatisfy{$0.tokenClientMatches==true && $0.tokenCodeMatches==true && $0.tokenPKCEMatches==true && $0.tokenRedirectMatches==true && $0.tokenResourceMatches==true && $0.tokenMethodAndFormatMatches==true})
        check("real_controller_stops_before_identity_save",!model.authDiagnostic.events.contains{[SIWCAuthStage.tokenDecode,.jwks,.identity,.saveSession].contains($0.stage)})
        let query1=URLComponents(url:first.1,resolvingAgainstBaseURL:false)!.queryItems!,query2=URLComponents(url:second.1,resolvingAgainstBaseURL:false)!.queryItems!
        check("S1_replacement_has_app_name_and_no_identity_hints",query2.contains{$0.name=="agent_name_hint"} && !query2.contains{["id_token_hint","login_hint"].contains($0.name)})
        check("host_stays_same",query1.first{$0.name=="ext_agent_host_id"}?.value==query2.first{$0.name=="ext_agent_host_id"}?.value)
        // Inspect bytes actually received by URLProtocol, not only the pre-transport model.
        for (i,item) in [first,second].enumerated() {
            let b=SIWCAuthBindingInspector.exchange(request:tokens[i],authorizationURL:item.1,pending:item.0,code:i==0 ? code1:code2,issued:issued)
            check("wire_\(i)_exact_contract",b.tokenCodeMatches==true && b.tokenClientMatches==true && b.tokenPKCEMatches==true && b.tokenRedirectMatches==true && b.tokenResourceMatches==true && b.tokenMethodAndFormatMatches==true)
        }
        // Negative controls prove false values are detectable without logging inputs.
        for (field,expected) in [("client_id","client"),("code","code"),("code_verifier","pkce"),("redirect_uri","redirect"),("resource","resource")] {
            var values=["grant_type":"authorization_code","client_id":issued,"code":code2,"code_verifier":second.0.verifier,"redirect_uri":second.0.redirect,"resource":SIWCProtocol.resource]
            values[field]="generated-wrong-value"
            var request=tokens[1];request.httpBody=SIWCProtocol.form(values)
            let b=SIWCAuthBindingInspector.exchange(request:request,authorizationURL:second.1,pending:second.0,code:code2,issued:issued)
            let flags=["client":b.tokenClientMatches,"code":b.tokenCodeMatches,"pkce":b.tokenPKCEMatches,"redirect":b.tokenRedirectMatches,"resource":b.tokenResourceMatches]
            check("detect_wrong_\(field)",flags[expected] == false)
        }
        var wrongMethod=tokens[1];wrongMethod.httpMethod="GET"
        check("detect_wrong_method",SIWCAuthBindingInspector.exchange(request:wrongMethod,authorizationURL:second.1,pending:second.0,code:code2,issued:issued).tokenMethodAndFormatMatches==false)
        for (field,label) in [("state","state"),("nonce","nonce"),("redirect_uri","redirect"),("code_challenge","pkce"),("client_id","client")] {
            var bad=URLComponents(url:second.1,resolvingAgainstBaseURL:false)!
            bad.queryItems=bad.queryItems!.map{$0.name==field ? URLQueryItem(name:field,value:"generated-wrong-value"):$0}
            let b=SIWCAuthBindingInspector.authorization(url:bad.url!,pending:second.0)
            let flags=["state":b.authorizationStateMatches,"nonce":b.authorizationNonceMatches,"redirect":b.authorizationRedirectMatches,"pkce":b.authorizationPKCEMatches,"client":b.authorizationClientMatches]
            check("detect_authorization_\(field)_mismatch",flags[label] == false)
        }
        let missingContext=SIWCAuthBindingInspector.exchange(request:tokens[1],authorizationURL:nil,pending:second.0,code:code2,issued:issued)
        check("missing_context_not_reported_as_match",missingContext.authorizationContextAvailable==false && missingContext.tokenPKCEMatches==nil && missingContext.tokenRedirectMatches==nil)
        var missing=URLComponents(url:second.1,resolvingAgainstBaseURL:false)!
        missing.queryItems=missing.queryItems!.filter{$0.name != "code_challenge"}
        var missingVerifier=tokens[1];missingVerifier.httpBody=SIWCProtocol.form(["grant_type":"authorization_code"])
        check("two_missing_fields_cannot_match",SIWCAuthBindingInspector.exchange(request:missingVerifier,authorizationURL:missing.url!,pending:second.0,code:code2,issued:issued).tokenPKCEMatches==false)
        var duplicated=tokens[1];var duplicateBody=tokens[1].httpBody!;duplicateBody.append(Data("&client_id=generated-duplicate".utf8));duplicated.httpBody=duplicateBody
        check("duplicate_form_fields_rejected",SIWCAuthBindingInspector.exchange(request:duplicated,authorizationURL:second.1,pending:second.0,code:code2,issued:issued).tokenClientMatches==false)
        for (name,value) in try await runLoopbackFormChecks(http:http) { check(name,value) }
        let third = try await model.contractAttempt(number:3,code:code2,issued:issued)
        let exchanges = model.authDiagnostic.events.filter { $0.stage == .tokenExchange && $0.outcome == .checked }
        check("D2_new_code_not_seen_before",exchanges.first?.binding?.codePreviouslySubmittedInWindow == false)
        check("D2_repeated_code_detected_across_attempts",exchanges.last?.binding?.codePreviouslySubmittedInWindow == true)
        check("D2_trace_differs_per_registration_attempt",exchanges.first?.traceID != nil && exchanges.first?.traceID != exchanges.last?.traceID)
        check("D2_registration_checkpoint_matches",exchanges.allSatisfy { $0.binding?.registrationCheckpointMatches == true })
        check("D2_monotonic_timing_present",exchanges.allSatisfy { $0.elapsedMilliseconds != nil && $0.binding?.callbackToExchangeMilliseconds != nil })
        check("D2_service_request_id_on_token_response",model.authDiagnostic.events.contains { $0.stage == .tokenExchange && $0.outcome == .response && $0.service?.requestID == "req_0123456789abcdef0123456789abcdef" && $0.service?.endpoint == .token })
        check("D2_new_registration_strategy_unchanged",third.2 == .newRegistration)
        let encoded=try JSONEncoder().encode(model.authDiagnostic);let text=String(decoding:encoded,as:UTF8.self)
        check("diagnostics_contain_no_raw_binding_values",![issued,code1,code2,first.0.state,first.0.nonce,first.0.verifier,second.0.state,second.0.nonce,second.0.verifier,"generated-host-marker","http://127.0.0.1","https://auth.openai.com"].contains{text.contains($0)})
        // Optional binding field preserves old on-disk D1 records.
        var old=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        old["events"]=(old["events"] as! [[String:Any]]).map { e in var e=e;for key in ["binding","traceID","elapsedMilliseconds","service","validation"] { e.removeValue(forKey:key) };return e }
        let restored=try JSONDecoder().decode(SIWCAuthDiagnostic.self,from:JSONSerialization.data(withJSONObject:old))
        check("old_D1_records_remain_decodable",restored.events.count==model.authDiagnostic.events.count && restored.events.allSatisfy{$0.binding==nil})
        for (name,value) in try await runSingleAccountSuccessChecks(http:http) { check(name,value) }
        for (name,value) in try await runErrorDescriptionChecks(http:http) { check(name,value) }
        let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"checks":checks,"count":checks.count,"networkRequests":0,"transportInterceptedRequests":wire.count,"keychainAccess":false,"scope":"Actual production controller selection, exchange, HTTP serialization, URLSession error handling and endAttempt; URLProtocol generates responses. Browser/listener UI, Keychain and iOS lifecycle not executed. Does not prove live bindings or server cause."]
        let output=ProcessInfo.processInfo.arguments.last!
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:output))
        print("Auth binding controller checks: \(checks.filter{$0.value}.count)/\(checks.count)")
        for (name,ok) in checks.sorted(by:{$0.key<$1.key}) where !ok { print("FAILED: \(name)") }
        exit(checks.values.allSatisfy{$0} ? 0:1)
    }
}

// Synthetic data only: actual TCP listener -> callback -> production controller
// return handler -> exchange -> real URLSession intercepted by URLProtocol.
import Darwin

private func callbackHTTP(port: UInt16, target: String, hostOverride: String? = nil) async throws -> Int {
    try await Task.detached {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SIWCError.invalidResponse }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw SIWCError.invalidResponse }
        let host = hostOverride ?? "127.0.0.1:\(port)"
        let bytes = Data("GET \(target) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
        let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == bytes.count else { throw SIWCError.invalidResponse }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { throw SIWCError.invalidResponse }
        let line = String(decoding: buffer.prefix(count), as: UTF8.self).components(separatedBy: "\r\n")[0]
        guard let status = Int(line.split(separator: " ")[1]) else { throw SIWCError.invalidResponse }
        return status
    }.value
}

@MainActor extension SIWCController {
    fileprivate func startFixtureLoopback() async throws -> SIWCPending {
        try prepareRegistrationAttempt(); let tx = UUID(); attempt = tx; busy = true; prepareAuthDiagnostics()
        discovery = try await SIWCDiscovery.load(http: authHTTPClient)
        let callbackListener = SIWCLoopback(diagnostic: { [weak self] detail in
            Task { @MainActor in self?.authCallback(detail, transaction: tx) }
        }) { [weak self] result in
            Task { @MainActor in self?.loopbackReturned(result, selected: nil, transaction: tx) }
        }
        listener = callbackListener
        let pending = await withCheckedContinuation { continuation in
            callbackListener.start(clientID: "generated-loopback-client") { pending in continuation.resume(returning: pending) }
        }
        currentPending = pending
        recordAuthorizationBindings(url: pending.authorize(hostID: "generated-loopback-host"), pending: pending)
        return pending
    }
}

@MainActor func runLoopbackFormChecks(http: SIWCHTTP) async throws -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let cases = [("bare-plus", "synthetic+code", "synthetic code"),
                 ("escaped-plus", "synthetic%2Bcode", "synthetic+code"),
                 ("decode-once", "synthetic%252Bcode", "synthetic%2Bcode"),
                 ("escaped-space", "synthetic%20code", "synthetic code"),
                 ("reserved", "synthetic%26%3D%25code", "synthetic&=%code"),
                 ("base64url", "synthetic_A-b.123", "synthetic_A-b.123")]
    for (index, fixture) in cases.enumerated() {
        var storageWrites = 0
        let model = SIWCController(authHTTPClient: http, authSaveSession: { _ in storageWrites += 1 })
        model.saved = SIWCSaved(hostID: "generated-loopback-host", accounts: [], selected: nil)
        let before = AuthFixtureWire.shared.snapshot().count
        let pending = try await model.startFixtureLoopback()
        let port = UInt16(URLComponents(string: pending.redirect)!.port!)
        let prefix = "/auth/callback?state=" + pending.state
        if index == 0 {
            let rejected = [
                ("state", "/auth/callback?state=wrong&code=synthetic"),
                ("encoded-state", prefix + "&%73tate=" + pending.state + "&code=synthetic"),
                ("encoded-code", prefix + "&code=a&%63ode=b"),
                ("duplicate-client", prefix + "&code=a&client_id=generated-loopback-client&client%5Fid=generated-loopback-client"),
                ("client-mismatch", prefix + "&code=a&client_id=wrong"),
                ("form-duplicate", prefix + "&code=a&x+y=1&x%20y=2"),
                ("encoded-path", "/auth%2Fcallback?state=" + pending.state + "&code=a")]
            for (name, target) in rejected {
                let status = try await callbackHTTP(port: port, target: target)
                checks["loopback_reject_" + name] = status == 400 && AuthFixtureWire.shared.snapshot().count == before + 1
            }
            let status = try await callbackHTTP(port: port, target: prefix + "&code=a", hostOverride: "example.invalid")
            checks["loopback_reject_host"] = status == 400 && AuthFixtureWire.shared.snapshot().count == before + 1
        }
        // The listener emits success immediately, so its controller may close the
        // socket before the HTTP response finishes. The definitive check is the
        // actual exchange request, not whether this synthetic browser saw 200.
        _ = try? await callbackHTTP(port: port, target: prefix + "&code=" + fixture.1)
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
        let requests = Array(AuthFixtureWire.shared.snapshot().dropFirst(before))
        let tokens = requests.filter { $0.url?.path == "/api/accounts/oauth/token" }
        let fields = tokens.first?.httpBody.map { body in
            String(decoding: body, as: UTF8.self).split(separator: "&").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let key = String(parts[0]).removingPercentEncoding,
                      let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return nil }
                return (key, value)
            }
        } ?? []
        let code = fields.first { $0.0 == "code" }?.1
        checks["loopback_" + fixture.0 + "_exact_wire_code"] = tokens.count == 1 && code == fixture.2
        checks["loopback_" + fixture.0 + "_binding_preserved"] = fields.first { $0.0 == "client_id" }?.1 == "generated-loopback-client" && fields.first { $0.0 == "code_verifier" }?.1 == pending.verifier && fields.first { $0.0 == "redirect_uri" }?.1 == pending.redirect
        checks["loopback_" + fixture.0 + "_saves_only_pending_metadata"] = !model.busy && storageWrites == 1 && model.saved?.accounts.isEmpty == true && model.pendingRegistrations.count == 1 && model.authDiagnostic.events.contains { $0.stage == .tokenExchange && $0.outcome == .failed && $0.errorCode == "invalid_grant" }
        let text = String(decoding: try JSONEncoder().encode(model.authDiagnostic), as: UTF8.self)
        checks["loopback_" + fixture.0 + "_no_sensitive_diagnostic"] = ![pending.state, pending.verifier, fixture.2, pending.redirect, "generated-loopback-client"].contains { text.contains($0) }
        model.cancel()
    }
    return checks
}


private func fixtureRequire<T>(_ value: T?) throws -> T {
    guard let value else { throw SIWCError.invalidResponse }; return value
}

@MainActor private func runErrorDescriptionChecks(http: SIWCHTTP) async throws -> [String:Bool] {
    var checks:[String:Bool]=[:]
    typealias Description = SIWCErrorDescriptionDiagnostic
    func body(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed) }
    let cases:[(String,Data,Description.State,Description.Reason?,Description.SafeMessage?)] = [
        ("absent",try body(["error":"invalid_grant"]),.absent,nil,nil),
        ("empty",try body(["error":"invalid_grant","error_description":" \n"]),.presentEmpty,nil,nil),
        ("safe",try body(["error":"invalid_grant","error_description":"Invalid authorization code"]),.presentSanitized,nil,.invalidAuthorizationCode),
        ("email",try body(["error":"invalid_grant","error_description":"generated-private@example.invalid"]),.presentSuppressed,.sensitiveContent,nil),
        ("url",try body(["error":"invalid_grant","error_description":"https://example.invalid/?code=generated-secret"]),.presentSuppressed,.sensitiveContent,nil),
        ("secret",try body(["error":"invalid_grant","error_description":"Bearer generated-private-token"]),.presentSuppressed,.sensitiveContent,nil),
        ("unknown",try body(["error":"invalid_grant","error_description":"generated unknown diagnostic"]),.presentSuppressed,.unrecognizedText,nil),
        ("long",try body(["error":"invalid_grant","error_description":String(repeating:"z",count:513)]),.presentSuppressed,.descriptionTooLong,nil),
        ("null",try body(["error":"invalid_grant","error_description":NSNull()]),.unreadable,.invalidType,nil),
        ("malformed",Data("{".utf8),.unreadable,.invalidJSON,nil),
        ("nonobject",try body([]),.unreadable,.nonObjectJSON,nil),
        ("nested",try body(["error":["code":"invalid_grant","error_description":"Invalid grant"]]),.presentSanitized,nil,.invalidGrant),
        ("ambiguous",try body(["error_description":"Invalid grant","error":["error_description":"Access denied"]]),.unreadable,.ambiguousFields,nil),
        ("oversize",Data(repeating:32,count:65_537),.unreadable,.bodyTooLarge,nil)
    ]
    let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
    let tokens=SIWCTokens(access:"generated-pro-access",refresh:"generated-pro-refresh",idToken:"generated-pro-id",scope:SIWCProtocol.scopes,expiresAt:Date().addingTimeInterval(3600))
    let pro=SIWCAccount(clientID:"generated-pro-client",subject:"generated-pro-subject",email:nil,tokens:tokens,planOnlyConfirmed:true,label:"連線 1")
    let historical=SIWCAccount(clientID:"generated-history-client",subject:"generated-history-subject",email:nil,tokens:tokens,planOnlyConfirmed:true,label:"連線 2")
    var disk=SIWCSaved(hostID:"generated-preserved-host",accounts:[pro,historical],selected:pro.id)
    let accountBytes=try encoder.encode(disk.accounts)
    let model=SIWCController(authHTTPClient:http,authSaveSession:{disk=$0},authLoadSession:{disk})
    model.load()
    defer { AuthFixtureWire.shared.setTokenErrorBody(nil) }
    for (index,item) in cases.enumerated() {
        AuthFixtureWire.shared.setTokenErrorBody(item.1)
        _ = try await model.contractAttempt(number:100+index,code:"generated-description-code-\(index)",issued:"generated-description-client")
        let diagnostic=model.authDiagnostic.latestSignIn?.failure?.errorDescription
        checks["E1_HTTP_" + item.0] = diagnostic?.version == 1 && diagnostic?.state == item.2 && diagnostic?.reason == item.3 && diagnostic?.safeMessage == item.4
        let restored=try JSONDecoder().decode(SIWCAuthDiagnostic.self,from:encoder.encode(model.authDiagnostic))
        checks["E1_persisted_" + item.0] = restored.latestSignIn?.failure?.errorDescription == diagnostic && restored.events.last?.errorDescription == diagnostic && restored.latestSignIn?.failure?.httpStatus == 400
    }
    AuthFixtureWire.shared.setTokenErrorBody(nil)
    checks["E1_HTTP_failures_preserve_Pro_and_history"] = try model.selectedID == pro.id && disk.selected == pro.id && encoder.encode(disk.accounts) == accountBytes && !model.busy
    let callbackCases:[(String,String?,Bool,Description.State,Description.Reason?)] = [
        ("absent",nil,false,.absent,nil), ("empty","",true,.presentEmpty,nil),
        ("safe","Access denied",true,.presentSanitized,nil),
        ("secret","Bearer generated-private-token",true,.presentSuppressed,.sensitiveContent),
        ("unknown","generated unknown diagnostic",true,.presentSuppressed,.unrecognizedText)
    ]
    let beforeCallback=AuthFixtureWire.shared.snapshot().count
    for item in callbackCases {
        try model.contractDescriptionDenial(item.1,includeField:item.2)
        let restored=try JSONDecoder().decode(SIWCAuthDiagnostic.self,from:encoder.encode(model.authDiagnostic))
        checks["E1_callback_" + item.0] = restored.latestSignIn?.failure?.stage == .callback &&
            restored.latestSignIn?.failure?.errorDescription?.state == item.3 &&
            restored.latestSignIn?.failure?.errorDescription?.reason == item.4
    }
    checks["E1_callback_denials_never_exchange_and_preserve_Pro_history"] = try AuthFixtureWire.shared.snapshot().count == beforeCallback && encoder.encode(disk.accounts) == accountBytes && model.selectedID == pro.id
    // Encode exactly the production persisted type, including latestSignIn's terminal copy.
    let serialized=try encoder.encode(model.authDiagnostic)
    let text=String(decoding:serialized,as:UTF8.self)
    checks["E1_no_description_or_credentials_leak"] = !["generated-private", "example.invalid", "generated-secret", "generated unknown diagnostic",
                                                      "generated-pro-access", "generated-pro-refresh", "generated-pro-id",
                                                      "generated-description-state", "generated-description-verifier"].contains(where:text.contains)
    let lastFailure=model.authDiagnostic.latestSignIn?.failure
    for _ in 0..<70 { model.authDiagnostic.record(stage:.syntheticImage,outcome:.succeeded) }
    let rotated=try JSONDecoder().decode(SIWCAuthDiagnostic.self,from:encoder.encode(model.authDiagnostic))
    checks["E1_latest_failure_survives_64_event_rotation"] = rotated.events.count == 64 && rotated.latestSignIn?.failure?.errorDescription == lastFailure?.errorDescription && rotated.latestSignIn?.failure?.id == lastFailure?.id
    var legacy=try JSONSerialization.jsonObject(with:serialized) as! [String:Any]
    legacy["events"]=(legacy["events"] as! [[String:Any]]).map { e in var e=e;e.removeValue(forKey:"errorDescription");return e }
    var signIn=legacy["latestSignIn"] as! [String:Any]
    var failure=signIn["failure"] as! [String:Any]; failure.removeValue(forKey:"errorDescription")
    signIn["failure"]=failure;legacy["latestSignIn"]=signIn
    let old=try JSONDecoder().decode(SIWCAuthDiagnostic.self,from:JSONSerialization.data(withJSONObject:legacy))
    checks["E1_legacy_missing_field_is_unknown_not_absent"] = old.latestSignIn?.failure?.errorDescriptionDiagnostic?.state == .legacyNotRecorded && old.latestSignIn?.failure?.text.contains("服務是否提供未知") == true
    return checks
}

private struct AuthSuccessSigningFixture {
    let key: SecKey
    let jwks: Data
    init() throws {
        key = try fixtureRequire(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try fixtureRequire(SecKeyCopyPublicKey(key))
        let der = try fixtureRequire(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var i = 0
        func field() -> Data {
            i += 1; var length = Int(der[i]); i += 1
            if length & 128 != 0 { let count = length & 127; length = 0; for _ in 0..<count { length = (length << 8) | Int(der[i]); i += 1 } }
            let result = der[i..<(i+length)]; i += length; return Data(result)
        }
        let sequence = field(); var integers: [Data] = []; var j = 0
        while j < sequence.count {
            j += 1; var length = Int(sequence[j]); j += 1
            if length & 128 != 0 { let count = length & 127; length = 0; for _ in 0..<count { length = length << 8 | Int(sequence[j]); j += 1 } }
            var data = Data(sequence[j..<(j+length)]); j += length
            while data.first == 0 { data.removeFirst() }; integers.append(data)
        }
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test-key", "kty": "RSA", "alg": "RS256", "use": "sig", "n": SIWCProtocol.encode(integers[0]), "e": SIWCProtocol.encode(integers[1])]]])
    }
    func token(_ overrides: [String: Any] = [:], alg: String = "RS256") throws -> String {
        var claims: [String: Any] = ["iss": SIWCProtocol.issuer, "sub": "test-sub", "aud": "test-client", "nonce": "test-nonce", "iat": Date().timeIntervalSince1970 - 5, "exp": Date().timeIntervalSince1970 + 3600]
        for (key,value) in overrides { claims[key] = value }
        let header = try JSONSerialization.data(withJSONObject: ["alg": alg, "kid": "test-key"])
        let payload = try JSONSerialization.data(withJSONObject: claims)
        let signed = SIWCProtocol.encode(header) + "." + SIWCProtocol.encode(payload)
        let signature = try fixtureRequire(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil)) as Data
        return signed + "." + SIWCProtocol.encode(signature)
    }
}
@MainActor func runSingleAccountSuccessChecks(http: SIWCHTTP) async throws -> [String:Bool] {
    var checks:[String:Bool]=[:]
    let oldTokens = SIWCTokens(access:"generated-preserved-access",refresh:"generated-preserved-refresh",idToken:"generated-preserved-id",scope:SIWCProtocol.scopes,expiresAt:Date().addingTimeInterval(3600))
    let old = SIWCAccount(clientID:"generated-old-client",subject:"generated-old-sub",email:nil,tokens:oldTokens,planOnlyConfirmed:true,label:"連線 1")
    let legacy = SIWCAccount(clientID:"generated-legacy-client",subject:"generated-legacy-sub",email:nil,tokens:oldTokens,planOnlyConfirmed:true,label:"連線 2")
    let pending = SIWCPendingRegistration(id:"generated-pending-id",label:"連線 3",clientID:"generated-pending-client",savedAt:Date())
    var disk = SIWCSaved(hostID:"generated-preserved-host",accounts:[old,legacy],selected:old.id,pendingRegistrations:[pending])
    let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
    let originalAccount = try encoder.encode(old), originalLegacy = try encoder.encode(legacy)
    var saveCount=0; var failNewIdentity=false; var activeBeforeSave:[String]=[]
    var model:SIWCController!
    model=SIWCController(authHTTPClient:http,authSaveSession:{ next in
        activeBeforeSave.append(model.selectedID)
        if failNewIdentity && next.selected != disk.selected { throw SIWCError.invalidResponse }
        disk=next;saveCount+=1
    },authLoadSession:{ disk })
    model.load()
    checks["S1_M1_migration_read_only_keeps_selected_credentials_and_pending"] = saveCount == 0 && model.selectedID == old.id && disk.accounts.count == 2 && disk.pendingRegistrations == [pending] && model.account?.planOnlyConfirmed == true
    checks["S1_legacy_active_and_pending_never_supply_replacement_client"] = model.contractState().source == .newRegistration && model.contractState().retry == nil
    _ = try await model.contractAttempt(number:20,code:"generated-success-code",issued:"generated-new-client",signedSubject:"generated-new-sub")
    let newID="generated-new-client:generated-new-sub"
    checks["S1_verified_identity_switches_active_only_after_atomic_save"] = model.selectedID == newID && disk.selected == newID && activeBeforeSave == [old.id,old.id] && saveCount == 2
    checks["S1_success_preserves_archived_credentials_and_host"] = try encoder.encode(disk.accounts.first{$0.id==old.id}!) == originalAccount && encoder.encode(disk.accounts.first{$0.id==legacy.id}!) == originalLegacy && disk.hostID == "generated-preserved-host"
    checks["S1_success_removes_only_its_completed_pending"] = disk.pendingRegistrations == [pending] && model.pendingRegistrations == [pending]
    checks["S1_success_requires_actual_signature_validation_and_plan_permission"] = model.authDiagnostic.events.contains{$0.stage == .identity && $0.outcome == .succeeded} && model.authDiagnostic.events.contains{$0.stage == .saveSession && $0.outcome == .succeeded} && model.authenticated && model.planEnabled
    checks["W1_new_authorization_ready_with_legacy_confirmation_false"] = model.planAccessReady && disk.accounts.first{$0.id==newID}?.planOnlyConfirmed == false
    checks["D3_success_correlates_saved_account_and_latest_attempt"] = model.latestAccountMatches && model.authDiagnostic.latestSignIn?.outcome == .succeeded && model.account?.authenticationTraceID != nil && !model.diagnosticReady
    model.confirmsDiagnosticAccount = true
    checks["D3_explicit_confirmation_enables_only_current_success"] = model.diagnosticReady
    let beforeReload=saveCount; model.load()
    checks["D3_settings_reload_preserves_success_and_correlation"] = model.latestAccountMatches
    checks["W1_reload_never_writes_legacy_confirmation"] = model.planAccessReady && model.account?.planOnlyConfirmed == false && saveCount == beforeReload
    model.catalog = [SIWCModel(slug:"generated-unavailable",display_name:"Generated unavailable",visibility:"list")]
    do { _ = try await model.recognize(jpeg:Data([1])); checks["W1_recognize_reaches_model_validation_without_confirmation"] = false }
    catch { checks["W1_recognize_reaches_model_validation_without_confirmation"] = error as? SIWCError == .modelUnavailable && !model.busy }
    model.catalog = []
    let accepted = try encoder.encode(model.account!)
    _ = try await model.contractAttempt(number:21,code:"generated-http400",issued:"generated-failed-client")
    checks["S1_HTTP400_preserves_current_credentials_and_legacy_value"] = try model.selectedID == newID && disk.selected == newID && encoder.encode(model.account!) == accepted && model.account?.planOnlyConfirmed == false
    checks["D3_failed_replacement_visible_and_blocks_previous_account"] = model.signInResultText.contains("失敗") && !model.latestAccountMatches && !model.diagnosticReady && model.authDiagnostic.latestSignIn?.outcome == .failed
    model.cancel()
    checks["S1_cancel_preserves_active_and_ends_attempt"] = try !model.busy && model.selectedID == newID && encoder.encode(model.account!) == accepted
    _ = try await model.contractAttempt(number:22,code:"generated-nonce-mismatch",issued:"generated-nonce-client",signedSubject:"generated-nonce-sub",invalidNonce:true)
    checks["S1_identity_failure_preserves_current"] = try model.selectedID == newID && disk.accounts.count == 3 && encoder.encode(model.account!) == accepted && !model.busy
    _ = try await model.contractAttempt(number:23,code:"generated-missing-plan",issued:"generated-no-plan-client",signedSubject:"generated-no-plan-sub",scope:"openid profile email")
    checks["S1_missing_plan_permission_preserves_current"] = try model.selectedID == newID && disk.accounts.count == 3 && encoder.encode(model.account!) == accepted && model.authDiagnostic.events.contains{$0.attempt == model.authDiagnostic.attempt && $0.category == .planDisabled}
    failNewIdentity=true
    _ = try await model.contractAttempt(number:24,code:"generated-save-failure",issued:"generated-save-failure-client",signedSubject:"generated-save-failure-sub")
    checks["S1_final_storage_failure_preserves_current_memory_and_disk"] = try model.selectedID == newID && disk.selected == newID && disk.accounts.count == 3 && encoder.encode(model.account!) == accepted && !model.busy
    checks["S1_storage_failure_never_reports_saved"] = !model.authDiagnostic.events.contains{$0.attempt == model.authDiagnostic.attempt && $0.stage == .saveSession && $0.outcome == .succeeded}
    try model.contractDenial()
    checks["S1_official_denial_preserves_active_credentials"] = try model.selectedID == newID && encoder.encode(model.account!) == accepted && !model.busy && model.authDiagnostic.events.contains{$0.attempt == model.authDiagnostic.attempt && $0.category == .oauthDenied}
    failNewIdentity=false
    let beforeLate=AuthFixtureWire.shared.snapshot().filter{$0.url?.path == "/api/accounts/oauth/token"}.count
    AuthFixtureWire.shared.setTokenDelay(0.3)
    let late=Task { try await model.contractAttempt(number:26,code:"generated-late-success",issued:"generated-late-client",signedSubject:"generated-late-sub") }
    for _ in 0..<100 where AuthFixtureWire.shared.snapshot().filter({$0.url?.path == "/api/accounts/oauth/token"}).count == beforeLate { try await Task.sleep(for:.milliseconds(10)) }
    let inFlight = AuthFixtureWire.shared.snapshot().filter{$0.url?.path == "/api/accounts/oauth/token"}.count > beforeLate
    model.cancel();_ = try await late.value;AuthFixtureWire.shared.setTokenDelay(0)
    checks["S1_cancel_during_exchange_rejects_late_HTTP200"] = try inFlight && model.selectedID == newID && disk.selected == newID && encoder.encode(model.account!) == accepted && !model.busy && !model.authDiagnostic.events.contains{$0.attempt == model.authDiagnostic.attempt && $0.stage == .identity}
    let reloaded=SIWCController(authHTTPClient:http,authSaveSession:{_ in checks["S1_reload_no_write"]=false},authLoadSession:{ disk })
    checks["S1_reload_no_write"]=true;reloaded.load()
    checks["S1_restart_restores_only_current_and_requires_new_replacement_auth"] = try reloaded.selectedID == newID && encoder.encode(reloaded.account!) == accepted && reloaded.contractState().source == .newRegistration
    let failedStore=SIWCController(authHTTPClient:http,authSaveSession:{_ in throw SIWCError.invalidResponse},authLoadSession:{disk})
    failedStore.load();let beforeWire=AuthFixtureWire.shared.snapshot().count
    _ = try await failedStore.contractAttempt(number:25,code:"generated-pending-save-fail",issued:"generated-unsaved-client")
    checks["S1_checkpoint_save_failure_stops_before_token_and_preserves_current"] = try AuthFixtureWire.shared.snapshot().count == beforeWire+1 && failedStore.selectedID == newID && encoder.encode(failedStore.account!) == accepted && !failedStore.busy
    let failedLoad=SIWCController(authHTTPClient:http,authSaveSession:{_ in checks["S1_load_failure_no_write"]=false},authLoadSession:{ throw SIWCError.invalidResponse })
    checks["S1_load_failure_no_write"]=true;failedLoad.saved=disk;failedLoad.selectedID=newID;failedLoad.load();failedLoad.beginNewAccount()
    checks["S1_load_failure_blocks_replacement_without_reset"] = !failedLoad.busy && failedLoad.saved?.accounts.count == 3 && failedLoad.selectedID == newID
    var oldSchema = try JSONSerialization.jsonObject(with:encoder.encode(disk)) as! [String:Any]
    oldSchema.removeValue(forKey:"pendingRegistrations")
    oldSchema["accounts"] = (oldSchema["accounts"] as! [[String:Any]]).map { item in var value=item;value.removeValue(forKey:"label");return value }
    let decoded=try JSONDecoder().decode(SIWCSaved.self,from:JSONSerialization.data(withJSONObject:oldSchema))
    checks["S1_pre_M1_schema_remains_readable_without_deletion"] = decoded.selected == newID && decoded.accounts.count == 3 && decoded.pendingRegistrations.isEmpty && decoded.hostID == disk.hostID
    checks["S1_no_saved_registration_becomes_replacement_shortcut"] = model.contractState().source == .newRegistration && reloaded.contractState().source == .newRegistration
    return checks
}
