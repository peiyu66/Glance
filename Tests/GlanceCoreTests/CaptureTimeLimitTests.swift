import Testing
@testable import GlanceCore

@Test func captureLimitExactBoundaryAndOneShotExpiry() {
    var limit = CaptureTimeLimit()
    #expect({ limit.begin(at: 10) }()); #expect({ limit.deadline == 310 }())
    #expect({ !limit.expireIfNeeded(at: 309.999) }()); #expect({ !limit.expired }())
    #expect({ limit.expireIfNeeded(at: 310) }()); #expect({ limit.expired && limit.deadline == nil }())
    #expect({ !limit.expireIfNeeded(at: 900) }())
}
@Test func repeatedStartsCannotExtendOrEvadeDeadline() {
    var limit = CaptureTimeLimit(); limit.begin(at: 0)
    for t in [1.0, 100, 299, 301] { #expect({ !limit.begin(at: t) }()); #expect({ limit.deadline == 300 }()) }
    #expect({ limit.expireIfNeeded(at: 301) }())
}
@Test func settingsAndBackgroundElapsedTimeDoesNotRestartLimit() {
    var limit = CaptureTimeLimit(); limit.begin(at: 100)
    #expect({ !limit.expireIfNeeded(at: 180) }()); #expect({ !limit.expireIfNeeded(at: 399) }())
    #expect({ limit.deadline == 400 }()); #expect({ limit.expireIfNeeded(at: 1000) }())
}
@Test func explicitPauseOrExpiredRestartCreatesFreshFiveMinutes() {
    var limit = CaptureTimeLimit(); limit.begin(at: 0); limit.manualPause()
    #expect({ !limit.expireIfNeeded(at: 600) }()); #expect({ !limit.expired }())
    #expect({ limit.begin(at: 600) }()); #expect({ limit.deadline == 900 }())
    #expect({ limit.expireIfNeeded(at: 900) }()); #expect({ limit.begin(at: 1200) }())
    #expect({ !limit.expired && limit.deadline == 1500 }())
}
@Test func invalidClockCannotStartCaptureLimit() {
    var limit = CaptureTimeLimit()
    #expect({ !limit.begin(at: .nan) }()); #expect({ !limit.begin(at: .infinity) }()); #expect({ limit.deadline == nil }())
}
