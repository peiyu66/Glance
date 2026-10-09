import Testing
@testable import GlanceCore

@Test func probeAcceptsOnce() {
    var p = ProbeCallback(state: "test-state")
    let first = p.accept(target: "/auth/callback?state=test-state&code=probe-only")
    #expect(first)
    let duplicate = p.accept(target: "/auth/callback?state=test-state&code=probe-only")
    #expect(!duplicate)
}
@Test func probeRejectsWrongOrAmbiguousCallbacks() {
    for target in ["/callback?state=s&code=probe-only", "/auth/callback?state=wrong&code=probe-only",
                   "/auth/callback?state=s&code=real-code", "/auth/callback?state=s&state=s&code=probe-only",
                   "http://example.com/auth/callback?state=s&code=probe-only", "/auth/callback?state=s&code=probe-only#fragment"] {
        var p = ProbeCallback(state: "s")
        let rejected = p.accept(target: target)
        #expect(!rejected)
        let valid = p.accept(target: "/auth/callback?state=s&code=probe-only")
        #expect(valid)
    }
}
