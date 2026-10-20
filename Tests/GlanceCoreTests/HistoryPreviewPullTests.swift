import Testing
@testable import GlanceCore

@Test func historyManualScrollFromMiddleReachesTopInOneGesture() {
    var gesture = HistoryPreviewPull(); gesture.begin(canReopen: true)
    expectTop(!gesture.update(distanceFromTop: 600, movingTowardTop: true, isManualScroll: true))
    expectTop(!gesture.update(distanceFromTop: 40, movingTowardTop: true, isManualScroll: true))
    expectTop(gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
    for distance in [-40.0, 0, 15, 0] { expectTop(!gesture.update(distanceFromTop: distance, movingTowardTop: true, isManualScroll: true)) }
}
@Test func historyTopDoesNotRequireOverscrollOrCollapsedStart() {
    // UI collapses once on manual start before checking controller eligibility.
    var gesture = HistoryPreviewPull(); gesture.begin(canReopen: true)
    expectTop(gesture.update(distanceFromTop: 0.5, movingTowardTop: true, isManualScroll: true))
    gesture.end(); gesture.begin(canReopen: true)
    expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: false, isManualScroll: true))
    expectTop(gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
}
@Test func historyManualDecelerationSharesSameOneShotPermission() {
    var gesture = HistoryPreviewPull(); gesture.begin(canReopen: true)
    expectTop(!gesture.update(distanceFromTop: 120, movingTowardTop: true, isManualScroll: true))
    // The scroll view still reports user-caused deceleration after finger release.
    expectTop(gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
    expectTop(!gesture.update(distanceFromTop: -30, movingTowardTop: true, isManualScroll: true))
}
@Test func historyProgrammaticInitializationAndDataChangesDoNotGrantReopen() {
    var gesture = HistoryPreviewPull()
    expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: false))
    gesture.begin(canReopen: true)
    expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: false))
    gesture.invalidateForProgrammaticChange()
    expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
    gesture.end(); gesture.begin(canReopen: true)
    expectTop(gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
}
@Test func historyBusyGestureCannotQueueReopeningAfterWorkFinishes() {
    var gesture = HistoryPreviewPull(); gesture.begin(canReopen: false)
    gesture.begin(canReopen: true)
    expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
    gesture.end(); gesture.begin(canReopen: true)
    expectTop(gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
}
@Test func historyCancelledInvalidOrAwayMotionDoesNotReopen() {
    var gesture = HistoryPreviewPull(); gesture.begin(canReopen: true)
    expectTop(!gesture.update(distanceFromTop: .nan, movingTowardTop: true, isManualScroll: true))
    expectTop(!gesture.update(distanceFromTop: .infinity, movingTowardTop: true, isManualScroll: true))
    expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: false, isManualScroll: true))
    gesture.end()
    expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
}
private func expectTop(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, sourceLocation: sourceLocation)
}

@Test func historyReturnToLatestBlocksActiveDragAndItsDeceleration() {
    var gesture = HistoryPreviewPull(); gesture.newGestureBegan(); gesture.begin(canReopen: true)
    expectTop(!gesture.update(distanceFromTop: 240, movingTowardTop: true, isManualScroll: true))
    gesture.returnToLatest()
    // Programmatic positioning, a lingering drag and its bounce/deceleration
    // all reach the top, but none may inherit the previous permission.
    for manual in [false, true] {
        for distance in [0.0, -35, 6, 0] {
            gesture.begin(canReopen: true)
            expectTop(!gesture.update(distanceFromTop: distance, movingTowardTop: true, isManualScroll: manual))
        }
    }
    gesture.newGestureBegan(); gesture.begin(canReopen: true)
    expectTop(gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
    expectTop(!gesture.update(distanceFromTop: -30, movingTowardTop: true, isManualScroll: true))
}
@Test func historyReturnToLatestWhileIdleCannotBeRearmedByChangedOrCancel() {
    var gesture = HistoryPreviewPull(); gesture.returnToLatest()
    for _ in 0..<3 {
        gesture.begin(canReopen: true)
        expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
        gesture.end() // cancellation/detachment, not a new .began
    }
    gesture.newGestureBegan(); gesture.begin(canReopen: true)
    expectTop(gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
}
@Test func historyRepeatedReturnToLatestNeedsAnotherNewGesture() {
    var gesture = HistoryPreviewPull(); gesture.returnToLatest(); gesture.returnToLatest()
    gesture.newGestureBegan(); gesture.begin(canReopen: true)
    gesture.returnToLatest() // a second press during the new gesture invalidates it
    expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
    gesture.newGestureBegan(); gesture.begin(canReopen: true)
    expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: false, isManualScroll: true))
    expectTop(gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
}
@Test func historyReturnToLatestDoesNotBypassBusyOrDataChangeGuards() {
    var gesture = HistoryPreviewPull(); gesture.returnToLatest()
    gesture.newGestureBegan(); gesture.begin(canReopen: false)
    gesture.begin(canReopen: true)
    expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
    gesture.newGestureBegan(); gesture.begin(canReopen: true)
    gesture.invalidateForProgrammaticChange()
    expectTop(!gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
    gesture.newGestureBegan(); gesture.begin(canReopen: true)
    expectTop(gesture.update(distanceFromTop: 0, movingTowardTop: true, isManualScroll: true))
}
@Test func historyLatestShortcutWaitsUntilFirstCardLeavesTop() {
    var visibility = HistoryLatestVisibility()
    for bottom in [900.0, 100, 2, 0, -4] {
        visibility.update(firstRowBottom: bottom, laterRowAtTop: false, scrollable: true, atTop: false)
        #expect(!visibility.visible)
    }
    visibility.update(firstRowBottom: -9, laterRowAtTop: true, scrollable: true, atTop: false)
    #expect(visibility.visible)
    for bottom in [-4.0, 0, 4] {
        visibility.update(firstRowBottom: bottom, laterRowAtTop: false, scrollable: true, atTop: false)
        #expect(visibility.visible)
    }
    visibility.update(firstRowBottom: 9, laterRowAtTop: false, scrollable: true, atTop: false)
    #expect(!visibility.visible)
}
@Test func historyLatestShortcutHandlesLazyRowsShortContentAndReturn() {
    var visibility = HistoryLatestVisibility()
    visibility.update(firstRowBottom: nil, laterRowAtTop: true, scrollable: true, atTop: false)
    #expect(visibility.visible)
    visibility.update(firstRowBottom: -500, laterRowAtTop: true, scrollable: true, atTop: true)
    #expect(!visibility.visible) // stale geometry after an immediate jump
    visibility.update(firstRowBottom: -20, laterRowAtTop: true, scrollable: false, atTop: false)
    #expect(!visibility.visible) // short list bouncing upward
    visibility.update(firstRowBottom: nil, laterRowAtTop: false, scrollable: true, atTop: false)
    #expect(!visibility.visible) // absent geometry cannot prove older content
}
