import XCTest

@MainActor
final class VirtualDisplayModeRestorerTests: XCTestCase {
    private var retina: VirtualDisplayModeSnapshot {
        .init(width: 3440, height: 1440, pixelWidth: 6880, pixelHeight: 2880, refreshRate: 60)
    }
    private var ordinary: VirtualDisplayModeSnapshot {
        .init(width: 3440, height: 1440, pixelWidth: 3440, pixelHeight: 1440, refreshRate: 60)
    }

    func testRestoresHiDPIInsteadOfSameLogicalSizeOrdinaryMode() async {
        let target = retina
        var current = ordinary
        var applied: [VirtualDisplayModeSnapshot] = []
        var wrongRate = target
        wrongRate.refreshRate = 75
        let result = await VirtualDisplayModeRestorer.restore(
            target: target, current: { current }, available: { [self.ordinary, wrongRate, target] },
            describe: { $0 }, apply: { applied.append($0); current = $0; return true }, pause: {}
        )
        XCTAssertTrue(result)
        XCTAssertEqual(applied, [target])
    }

    func testMissingHiDPIModeDoesNotFallBackToOrdinaryOrNativeSize() async {
        let target = retina
        let native = VirtualDisplayModeSnapshot(width: 6880, height: 2880,
                                               pixelWidth: 6880, pixelHeight: 2880, refreshRate: 60)
        let result = await VirtualDisplayModeRestorer.restore(
            target: target, current: { self.ordinary }, available: { [self.ordinary, native] },
            describe: { $0 }, apply: { _ in XCTFail("Must not silently downgrade"); return true }, pause: {}
        )
        XCTAssertFalse(result)
    }

    func testRestoresOrdinaryModeWhenHiDPISwitchedOff() async {
        let target = ordinary
        var current = retina
        let result = await VirtualDisplayModeRestorer.restore(
            target: target, current: { current }, available: { [self.retina, target] },
            describe: { $0 }, apply: { current = $0; return true }, pause: {}
        )
        XCTAssertTrue(result)
        XCTAssertEqual(current, target)
    }

    func testWaitsForModeRegistrationAndVerifiesAfterApplying() async {
        let target = retina
        var current = ordinary
        var waits = 0
        var applications = 0
        let result = await VirtualDisplayModeRestorer.restore(
            target: target, current: { current }, available: { waits >= 2 ? [target] : [] },
            describe: { $0 }, apply: { current = $0; applications += 1; return true },
            pause: { waits += 1 }
        )
        XCTAssertTrue(result)
        XCTAssertEqual(applications, 1)
        XCTAssertGreaterThanOrEqual(waits, 4)
    }

    func testNativeOverrideAfterFirstMatchMustBeCorrectedBeforeSuccess() async {
        let target = retina
        var current = target
        var waits = 0
        var applications = 0
        let result = await VirtualDisplayModeRestorer.restore(
            target: target, current: { current }, available: { [target] }, describe: { $0 },
            apply: { current = $0; applications += 1; return true },
            pause: {
                waits += 1
                if waits == 1 { current = self.ordinary }
            }
        )
        XCTAssertTrue(result)
        XCTAssertEqual(applications, 1)
        XCTAssertEqual(current, target)
    }

    func testSuccessfulIPCWithoutObservedModeChangeIsNotSuccess() async {
        let target = retina
        let result = await VirtualDisplayModeRestorer.restore(
            target: target, current: { self.ordinary }, available: { [target] }, describe: { $0 },
            apply: { _ in true }, pause: {}
        )
        XCTAssertFalse(result)
    }

    func testFailedOrTimedOutCommitIsNotRetriedWhileItMayStillBeRunning() async {
        let target = retina
        var applications = 0
        let result = await VirtualDisplayModeRestorer.restore(
            target: target, current: { self.ordinary }, available: { [target] }, describe: { $0 },
            apply: { _ in applications += 1; return false }, pause: {}
        )
        XCTAssertFalse(result)
        XCTAssertEqual(applications, 1)
    }

    func testStableMatchingModeNeedsNoCommit() async {
        let target = retina
        var observations = 0
        let result = await VirtualDisplayModeRestorer.restore(
            target: target, current: { observations += 1; return target }, available: { [] as [VirtualDisplayModeSnapshot] },
            describe: { $0 }, apply: { _ in XCTFail("Already selected"); return true }, pause: {}
        )
        XCTAssertTrue(result)
        XCTAssertEqual(observations, 2)
    }

    func testUnusableModeIsNeverApplied() async {
        let target = retina
        var unusable = target
        unusable.usableForDesktop = false
        let result = await VirtualDisplayModeRestorer.restore(
            target: target, current: { nil }, available: { [unusable] }, describe: { $0 },
            apply: { _ in XCTFail("Not a desktop mode"); return true }, pause: {}
        )
        XCTAssertFalse(result)
    }

    func testCancellationDuringSettlingDoesNotClaimSuccess() async {
        let target = retina
        let result = await VirtualDisplayModeRestorer.restore(
            target: target, current: { target }, available: { [target] }, describe: { $0 },
            apply: { _ in true }, pause: { throw CancellationError() }
        )
        XCTAssertFalse(result)
    }

    func testModeMatchingChecksBothDimensionsAndDensity() {
        let target = retina
        var wrongHeight = target
        wrongHeight.pixelHeight = 1440
        XCTAssertFalse(target.matches(wrongHeight))
        wrongHeight = target
        wrongHeight.height = 1200
        XCTAssertFalse(target.matches(wrongHeight))
        var fractionalRate = target
        fractionalRate.refreshRate = 59.94
        XCTAssertTrue(target.matches(fractionalRate))
        fractionalRate.refreshRate = 0
        XCTAssertFalse(target.matches(fractionalRate))
    }
}
