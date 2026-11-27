import XCTest

@MainActor
final class VirtualDisplayActivationGateTests: XCTestCase {
    func testLaunchRestoresOnlyFirstEnabledConfiguration() async {
        let gate = VirtualDisplayActivationGate()
        var restored: [String] = []
        let configs = ["disabled", "MacBook", "UltraWide"]
        await gate.restoreFirst(from: configs, matching: { $0 != "disabled" }) { restored.append($0) }
        XCTAssertEqual(restored, ["MacBook"])
    }

    func testLaunchWithNoEnabledConfigurationCreatesNothing() async {
        let gate = VirtualDisplayActivationGate()
        await gate.restoreFirst(from: ["MacBook", "UltraWide"], matching: { _ in false }) { _ in
            XCTFail("No launch configuration was selected")
        }
    }

    func testManualChoiceDuringLaunchDelayPreventsAutomaticSwitch() async {
        let gate = VirtualDisplayActivationGate()
        gate.noteManualActivity()
        await gate.restoreFirst(from: ["MacBook"], matching: { _ in true }) { _ in
            XCTFail("Delayed restore must not replace the user's selection")
        }
    }

    func testPendingApplicationBlocksLaunchRestoration() async {
        let gate = VirtualDisplayActivationGate()
        gate.applicationStarted()
        await gate.restoreFirst(from: ["MacBook"], matching: { _ in true }) { _ in
            XCTFail("Pending IPC must finish before another display can be created")
        }
        gate.applicationFinished()
    }

    func testCreateBeforeDestroyCreatesBeforeReleasingAndWaitsForTeardown() async {
        let gate = VirtualDisplayActivationGate()
        var events: [String] = []
        var oldDisplayOnline = true
        var waits = 0
        let result = await gate.activate(
            isRetiringClear: { true },
            create: {
                XCTAssertTrue(oldDisplayOnline)
                events.append("create")
                return true
            },
            releasePrevious: { events.append("release") },
            arePreviousReleased: { !oldDisplayOnline },
            afterRelease: { events.append("afterRelease") },
            pause: {
                waits += 1
                events.append("wait")
                if waits == 2 { oldDisplayOnline = false }
            }
        )
        XCTAssertEqual(result, .activated)
        XCTAssertEqual(events, ["create", "release", "wait", "wait", "afterRelease"])
        XCTAssertFalse(gate.isBusy)
    }

    func testCreationFailurePreservesExistingDisplayWithoutReleasing() async {
        let gate = VirtualDisplayActivationGate()
        var released = false
        let result = await gate.activate(
            isRetiringClear: { true },
            create: { false },
            releasePrevious: { released = true },
            arePreviousReleased: { true },
            afterRelease: { XCTFail("Mode restore must not run on failure") }
        )
        XCTAssertEqual(result, .creationFailed)
        XCTAssertFalse(released)
        XCTAssertFalse(gate.isBusy)
    }

    func testWaitsForPreviouslyRetiringDisplayBeforeCreatingReplacement() async {
        let gate = VirtualDisplayActivationGate()
        var events: [String] = []
        var retiringOnline = true
        var waits = 0
        let result = await gate.activate(
            isRetiringClear: { !retiringOnline },
            create: {
                XCTAssertFalse(retiringOnline)
                events.append("create")
                return true
            },
            releasePrevious: { events.append("release") },
            arePreviousReleased: { true },
            pause: {
                waits += 1
                events.append("wait")
                if waits == 2 { retiringOnline = false }
            }
        )
        XCTAssertEqual(result, .activated)
        XCTAssertEqual(events, ["wait", "wait", "create", "release"])
        XCTAssertFalse(gate.isBusy)
    }

    func testRetiringTimeoutDoesNotCreateSecondDisplay() async {
        let gate = VirtualDisplayActivationGate()
        var created = false
        var waits = 0
        let result = await gate.activate(
            isRetiringClear: { false },
            create: { created = true; return true },
            releasePrevious: { XCTFail("Must not release when creation did not run") },
            arePreviousReleased: { true },
            attempts: 3,
            pause: { waits += 1 }
        )
        XCTAssertEqual(result, .releaseTimedOut)
        XCTAssertEqual(waits, 3)
        XCTAssertFalse(created)
        XCTAssertFalse(gate.isBusy)
    }

    func testEnumerationFailureIsNotTreatedAsEmptyDisplayList() async {
        let gate = VirtualDisplayActivationGate()
        var created = false
        let result = await gate.activate(
            isRetiringClear: { nil },
            create: { created = true; return true },
            releasePrevious: {},
            arePreviousReleased: { true }
        )
        XCTAssertEqual(result, .enumerationFailed)
        XCTAssertFalse(created)
    }

    func testRepeatedActivationWhileWaitingIsRejectedWithoutAnotherRelease() async {
        let gate = VirtualDisplayActivationGate()
        let (entered, signal) = AsyncStream<Void>.makeStream()
        var resume: CheckedContinuation<Void, Never>?
        var retiringClear = false
        var releaseCount = 0
        var createCount = 0
        let first = Task {
            await gate.activate(
                isRetiringClear: { retiringClear },
                create: { createCount += 1; return true },
                releasePrevious: { releaseCount += 1 },
                arePreviousReleased: { true },
                pause: {
                    await withCheckedContinuation { resume = $0; signal.yield() }
                    retiringClear = true
                }
            )
        }
        for await _ in entered { break }
        let second = await gate.activate(
            isRetiringClear: { true },
            create: { createCount += 1; return true },
            releasePrevious: { releaseCount += 1 },
            arePreviousReleased: { true }
        )
        XCTAssertEqual(second, .busy)
        XCTAssertEqual(releaseCount, 0)
        XCTAssertEqual(createCount, 0)
        resume?.resume()
        let result = await first.value
        XCTAssertEqual(result, .activated)
        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(releaseCount, 1)
    }

    func testGateStaysLockedWhileCreationIsSuspended() async {
        let gate = VirtualDisplayActivationGate()
        let (entered, signal) = AsyncStream<Void>.makeStream()
        var resume: CheckedContinuation<Bool, Never>?
        let first = Task {
            await gate.activate(
                isRetiringClear: { true },
                create: {
                    await withCheckedContinuation { resume = $0; signal.yield() }
                },
                releasePrevious: {},
                arePreviousReleased: { true }
            )
        }
        for await _ in entered { break }
        let second = await gate.activate(
            isRetiringClear: { true },
            create: { XCTFail("Concurrent creation"); return true },
            releasePrevious: { XCTFail("Concurrent activation must not release the active display") },
            arePreviousReleased: { true }
        )
        XCTAssertEqual(second, .busy)
        resume?.resume(returning: true)
        let result = await first.value
        XCTAssertEqual(result, .activated)
        XCTAssertFalse(gate.isBusy)
    }

    func testTimedOutApplyBlocksRetryUntilRealIPCFinishes() async {
        let gate = VirtualDisplayActivationGate()
        let timeout = await gate.activate(
            isRetiringClear: { true },
            create: {
                gate.applicationStarted()
                return false // The timeout wrapper returned, but the IPC is still running.
            },
            releasePrevious: { XCTFail("Failed creation must not release existing display") },
            arePreviousReleased: { true }
        )
        XCTAssertEqual(timeout, .creationFailed)
        XCTAssertTrue(gate.isBusy)
        let prematureRetry = await gate.activate(
            isRetiringClear: { true },
            create: { XCTFail("Pending IPC can still register a display"); return true },
            releasePrevious: { XCTFail("Pending IPC still owns its display") },
            arePreviousReleased: { true }
        )
        XCTAssertEqual(prematureRetry, .busy)
        gate.applicationFinished()
        XCTAssertFalse(gate.isBusy)

        // A late apply may have registered a screen; finishing the IPC alone is not enough.
        let lateDisplayRetry = await gate.activate(
            isRetiringClear: { false },
            create: { XCTFail("Late display still online"); return true },
            releasePrevious: {},
            arePreviousReleased: { true },
            attempts: 0
        )
        XCTAssertEqual(lateDisplayRetry, .releaseTimedOut)
        let safeRetry = await gate.activate(
            isRetiringClear: { true },
            create: { true },
            releasePrevious: {},
            arePreviousReleased: { true }
        )
        XCTAssertEqual(safeRetry, .activated)
    }

    func testApplyCompletionDoesNotUnlockAnOngoingActivation() async {
        let gate = VirtualDisplayActivationGate()
        let result = await gate.activate(
            isRetiringClear: { true },
            create: {
                gate.applicationStarted()
                gate.applicationFinished()
                XCTAssertTrue(gate.isBusy)
                return true
            },
            releasePrevious: {},
            arePreviousReleased: { true }
        )
        XCTAssertEqual(result, .activated)
        XCTAssertFalse(gate.isBusy)
    }

    func testCancellationBeforeStartingPreservesCurrentDisplay() async {
        let gate = VirtualDisplayActivationGate()
        let task = Task {
            await gate.activate(
                isRetiringClear: { true },
                create: { XCTFail("Cancelled request"); return true },
                releasePrevious: { XCTFail("Cancelled request must preserve current display") },
                arePreviousReleased: { true }
            )
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(gate.isBusy)
    }

    func testCancellationDuringRetiringWaitDoesNotCreateOrRelease() async {
        let gate = VirtualDisplayActivationGate()
        let result = await gate.activate(
            isRetiringClear: { false },
            create: { XCTFail("Cancelled wait"); return true },
            releasePrevious: { XCTFail("Cancelled wait must not release") },
            arePreviousReleased: { true },
            pause: { throw CancellationError() }
        )
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(gate.isBusy)
    }

    func testCreationFailureAllowsSafeRetryAfterward() async {
        let gate = VirtualDisplayActivationGate()
        let failure = await gate.activate(
            isRetiringClear: { true },
            create: { false },
            releasePrevious: { XCTFail("Failed creation must not release") },
            arePreviousReleased: { true }
        )
        XCTAssertEqual(failure, .creationFailed)
        XCTAssertFalse(gate.isBusy)
        let retry = await gate.activate(
            isRetiringClear: { true },
            create: { true },
            releasePrevious: {},
            arePreviousReleased: { true }
        )
        XCTAssertEqual(retry, .activated)
    }

    func testSlowOldDisplayTeardownAfterSuccessfulCreateStillReturnsActivated() async {
        let gate = VirtualDisplayActivationGate()
        var afterReleaseCalled = false
        let result = await gate.activate(
            isRetiringClear: { true },
            create: { true },
            releasePrevious: {},
            arePreviousReleased: { false },
            afterRelease: { afterReleaseCalled = true },
            attempts: 2,
            pause: {}
        )
        XCTAssertEqual(result, .activated)
        XCTAssertTrue(afterReleaseCalled)
        XCTAssertFalse(gate.isBusy)
    }
}
