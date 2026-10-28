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

    func testWaitsForActualRemovalBeforeCreatingReplacement() async {
        let gate = VirtualDisplayActivationGate()
        var events: [String] = []
        var oldDisplayOnline = true
        var waits = 0
        let result = await gate.activate(
            release: { events.append("release") },
            isReleased: { !oldDisplayOnline },
            create: {
                XCTAssertFalse(oldDisplayOnline)
                events.append("create")
                return true
            },
            pause: {
                waits += 1
                events.append("wait")
                // Dropping the object did not remove it immediately; nor did the first wait.
                if waits == 2 { oldDisplayOnline = false }
            }
        )
        XCTAssertEqual(result, .activated)
        XCTAssertEqual(events, ["release", "wait", "wait", "create"])
        XCTAssertFalse(gate.isBusy)
    }

    func testReleaseTimeoutDoesNotCreateSecondDisplay() async {
        let gate = VirtualDisplayActivationGate()
        var created = false
        var waits = 0
        let result = await gate.activate(
            release: {}, isReleased: { false }, create: { created = true; return true },
            attempts: 3, pause: { waits += 1 }
        )
        XCTAssertEqual(result, .releaseTimedOut)
        XCTAssertEqual(waits, 3)
        XCTAssertFalse(created)
        XCTAssertFalse(gate.isBusy)
    }

    func testManuallyDeactivatedDisplayStillBlocksUntilOffline() async {
        // No owned object remains to release, but the previous framebuffer is still online.
        let gate = VirtualDisplayActivationGate()
        var oldDisplayOnline = true
        var created = false
        let result = await gate.activate(
            release: {}, isReleased: { !oldDisplayOnline },
            create: { created = true; return true },
            pause: { oldDisplayOnline = false }
        )
        XCTAssertEqual(result, .activated)
        XCTAssertTrue(created)
    }

    func testEnumerationFailureIsNotTreatedAsEmptyDisplayList() async {
        let gate = VirtualDisplayActivationGate()
        var created = false
        let result = await gate.activate(
            release: {}, isReleased: { nil }, create: { created = true; return true }
        )
        XCTAssertEqual(result, .enumerationFailed)
        XCTAssertFalse(created)
    }

    func testRepeatedActivationWhileWaitingIsRejectedWithoutAnotherRelease() async {
        let gate = VirtualDisplayActivationGate()
        let (entered, signal) = AsyncStream<Void>.makeStream()
        var resume: CheckedContinuation<Void, Never>?
        var released = false
        var releaseCount = 0
        var createCount = 0
        let first = Task {
            await gate.activate(
                release: { releaseCount += 1 }, isReleased: { released },
                create: { createCount += 1; return true },
                pause: {
                    await withCheckedContinuation { resume = $0; signal.yield() }
                    released = true
                }
            )
        }
        for await _ in entered { break }
        let second = await gate.activate(
            release: { releaseCount += 1 }, isReleased: { true },
            create: { createCount += 1; return true }
        )
        XCTAssertEqual(second, .busy)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(createCount, 0)
        resume?.resume()
        let result = await first.value
        XCTAssertEqual(result, .activated)
        XCTAssertEqual(createCount, 1)
    }

    func testGateStaysLockedWhileCreationIsSuspended() async {
        let gate = VirtualDisplayActivationGate()
        let (entered, signal) = AsyncStream<Void>.makeStream()
        var resume: CheckedContinuation<Bool, Never>?
        let first = Task {
            await gate.activate(release: {}, isReleased: { true }, create: {
                await withCheckedContinuation { resume = $0; signal.yield() }
            })
        }
        for await _ in entered { break }
        let second = await gate.activate(
            release: { XCTFail("Concurrent activation must not release the new display") },
            isReleased: { true }, create: { XCTFail("Concurrent creation"); return true }
        )
        XCTAssertEqual(second, .busy)
        resume?.resume(returning: true)
        let result = await first.value
        XCTAssertEqual(result, .activated)
        XCTAssertFalse(gate.isBusy)
    }

    func testTimedOutApplyBlocksRetryUntilRealIPCFinishes() async {
        let gate = VirtualDisplayActivationGate()
        let timeout = await gate.activate(release: {}, isReleased: { true }, create: {
            gate.applicationStarted()
            return false // The timeout wrapper returned, but the IPC is still running.
        })
        XCTAssertEqual(timeout, .creationFailed)
        XCTAssertTrue(gate.isBusy)
        let prematureRetry = await gate.activate(
            release: { XCTFail("Pending IPC still owns its display") },
            isReleased: { true }, create: { XCTFail("Pending IPC can still register a display"); return true }
        )
        XCTAssertEqual(prematureRetry, .busy)
        gate.applicationFinished()
        XCTAssertFalse(gate.isBusy)

        // A late apply may have registered a screen; finishing the IPC alone is not enough.
        let lateDisplayRetry = await gate.activate(
            release: {}, isReleased: { false }, create: { XCTFail("Late display still online"); return true },
            attempts: 0
        )
        XCTAssertEqual(lateDisplayRetry, .releaseTimedOut)
        let safeRetry = await gate.activate(release: {}, isReleased: { true }, create: { true })
        XCTAssertEqual(safeRetry, .activated)
    }

    func testApplyCompletionDoesNotUnlockAnOngoingActivation() async {
        let gate = VirtualDisplayActivationGate()
        let result = await gate.activate(release: {}, isReleased: { true }, create: {
            gate.applicationStarted()
            gate.applicationFinished()
            XCTAssertTrue(gate.isBusy)
            return true
        })
        XCTAssertEqual(result, .activated)
        XCTAssertFalse(gate.isBusy)
    }

    func testCancellationBeforeStartingPreservesCurrentDisplay() async {
        let gate = VirtualDisplayActivationGate()
        let task = Task {
            await gate.activate(
                release: { XCTFail("Cancelled request must preserve current display") },
                isReleased: { true }, create: { XCTFail("Cancelled request"); return true }
            )
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(gate.isBusy)
    }

    func testCancellationDuringReleaseWaitDoesNotCreate() async {
        let gate = VirtualDisplayActivationGate()
        let result = await gate.activate(
            release: {}, isReleased: { false }, create: { XCTFail("Cancelled wait"); return true },
            pause: { throw CancellationError() }
        )
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(gate.isBusy)
    }

    func testCreationFailureAllowsSafeRetryAfterRelease() async {
        let gate = VirtualDisplayActivationGate()
        let failure = await gate.activate(release: {}, isReleased: { true }, create: { false })
        XCTAssertEqual(failure, .creationFailed)
        XCTAssertFalse(gate.isBusy)
        let retry = await gate.activate(release: {}, isReleased: { true }, create: { true })
        XCTAssertEqual(retry, .activated)
    }
}
