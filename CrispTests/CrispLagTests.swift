import Foundation
import XCTest

final class CrispLagTests: XCTestCase {
    func testQualityChartGeneratesOffMainThread() {
        final class ResultBox: @unchecked Sendable {
            var generatedOffMain = false
            var generatedValid = false
        }
        let box = ResultBox()
        let done = expectation(description: "quality chart generated on background queue")
        DispatchQueue.global(qos: .userInitiated).async {
            box.generatedOffMain = !Thread.isMainThread
            let reference = try? LagQualityChart.make(token: 321, scale: 1)
            box.generatedValid = reference?.valid == true
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(box.generatedOffMain)
        XCTAssertTrue(box.generatedValid)
    }

    func testNetworkCollectorStopIsIdempotent() {
        let queue = DispatchQueue(label: "test.lag.network")
        let done = expectation(description: "collector stopped")
        queue.async {
            let collector = LagNetworkCollector(queue: queue, peer: "127.0.0.1")
            let first = collector.stop()
            let second = collector.stop()
            XCTAssertEqual(first.routeState, "unavailable")
            XCTAssertEqual(second.routeState, "unavailable")
            XCTAssertNotNil(first.ended)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testMotionSourceValidatesEmptyAndBoundedFrames() {
        let empty = LagMotionSource(token: 1, frames: [], completed: false, started: 10, ended: 11)
        XCTAssertTrue(empty.valid)

        let ascending = LagMotionSource(
            token: 1,
            frames: [LagMotionFrame(number: 1, stamp: 10.1), LagMotionFrame(number: 2, stamp: 10.2)],
            completed: true,
            started: 10,
            ended: 11
        )
        XCTAssertTrue(ascending.valid)

        let overlong = LagMotionSource(
            token: 1,
            frames: [LagMotionFrame(number: 1, stamp: 10), LagMotionFrame(number: 2, stamp: 30)],
            completed: false,
            started: 10,
            ended: 31
        )
        XCTAssertFalse(overlong.valid)
    }
}
