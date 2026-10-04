import XCTest
@testable import ViolinPracticeCore

final class ClickRejectionTests: XCTestCase {

    func testRejectsWithinWindowAfterClick() {
        var rejection = ClickRejection(windowSeconds: 0.025)
        rejection.registerClick(atSampleTime: 1.0)
        XCTAssertTrue(rejection.shouldReject(atSampleTime: 1.0))
        XCTAssertTrue(rejection.shouldReject(atSampleTime: 1.010))
        XCTAssertTrue(rejection.shouldReject(atSampleTime: 1.024))
        XCTAssertTrue(rejection.shouldReject(atSampleTime: 1.025), "window boundary is inclusive")
    }

    func testDoesNotRejectOutsideWindow() {
        var rejection = ClickRejection(windowSeconds: 0.025)
        rejection.registerClick(atSampleTime: 1.0)
        XCTAssertFalse(rejection.shouldReject(atSampleTime: 1.026))
        XCTAssertFalse(rejection.shouldReject(atSampleTime: 1.5))
    }

    func testDoesNotRejectBeforeClick() {
        var rejection = ClickRejection(windowSeconds: 0.025)
        rejection.registerClick(atSampleTime: 1.0)
        XCTAssertFalse(rejection.shouldReject(atSampleTime: 0.99))
        XCTAssertFalse(rejection.shouldReject(atSampleTime: 0.0))
    }

    func testEmptyRejectionNeverRejects() {
        let rejection = ClickRejection()
        XCTAssertFalse(rejection.shouldReject(atSampleTime: 0.0))
        XCTAssertFalse(rejection.shouldReject(atSampleTime: 123.456))
    }

    func testPruneRemovesStaleClicksOnly() {
        var rejection = ClickRejection(windowSeconds: 0.025)
        rejection.registerClick(atSampleTime: 1.0)
        rejection.registerClick(atSampleTime: 5.0)

        // At 5.010 the old click (1.0) is stale; the new one (5.0) is still live.
        rejection.prune(nowSampleTime: 5.010)

        XCTAssertTrue(rejection.shouldReject(atSampleTime: 5.010), "live click still rejects")
        XCTAssertFalse(rejection.shouldReject(atSampleTime: 1.010), "stale click was pruned")
    }

    func testPruneDoesNotChangeInWindowBehavior() {
        var rejection = ClickRejection(windowSeconds: 0.025)
        rejection.registerClick(atSampleTime: 2.0)
        // Nothing stale yet at this point.
        rejection.prune(nowSampleTime: 2.010)
        XCTAssertTrue(rejection.shouldReject(atSampleTime: 2.010))
        XCTAssertTrue(rejection.shouldReject(atSampleTime: 2.020))
        XCTAssertFalse(rejection.shouldReject(atSampleTime: 2.030))
    }
}
