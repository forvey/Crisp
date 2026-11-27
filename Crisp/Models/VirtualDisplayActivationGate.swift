import Foundation

/// Serializes virtual-display creation across the async WindowServer teardown. A timeout
/// in an IPC wrapper does not cancel that IPC, so pending applications also hold the gate.
@MainActor
final class VirtualDisplayActivationGate {
    enum Result: Equatable {
        case activated, busy, releaseTimedOut, enumerationFailed, cancelled, creationFailed
    }

    private var running = false
    private var pendingApplications = 0
    private var hasManualActivity = false
    private let stateWillChange: () -> Void

    var isBusy: Bool { running || pendingApplications > 0 }

    init(stateWillChange: @escaping () -> Void = {}) {
        self.stateWillChange = stateWillChange
    }

    func noteManualActivity() {
        hasManualActivity = true
    }

    /// Old preferences may contain several launch selections. Restore only one, and
    /// never overwrite a user's choice made during the delayed launch restoration.
    func restoreFirst<Configuration>(
        from configurations: [Configuration],
        matching shouldRestore: (Configuration) -> Bool,
        activate: @MainActor (Configuration) async -> Void
    ) async {
        guard !hasManualActivity, !isBusy, !Task.isCancelled,
              let config = configurations.first(where: shouldRestore) else { return }
        await activate(config)
    }

    func applicationStarted() {
        stateWillChange()
        pendingApplications += 1
    }

    func applicationFinished() {
        stateWillChange()
        pendingApplications -= 1
    }

    /// Create-Before-Destroy activation: wait for any previously retiring virtual
    /// display to leave the online list, create and verify the replacement online,
    /// then release the previous active virtual display so a failed creation never
    /// leaves a headless Mac without a display.
    func activate(
        isRetiringClear: () -> Bool?,
        create: @MainActor () async -> Bool,
        releasePrevious: () -> Void,
        arePreviousReleased: () -> Bool?,
        afterRelease: (@MainActor () async -> Void)? = nil,
        attempts: Int = 30,
        pause: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async -> Result {
        guard !isBusy else { return .busy }
        guard !Task.isCancelled else { return .cancelled }
        stateWillChange()
        running = true
        defer {
            stateWillChange()
            running = false
        }

        for attempt in 0...max(0, attempts) {
            guard !Task.isCancelled else { return .cancelled }
            guard let clear = isRetiringClear() else { return .enumerationFailed }
            if clear { break }
            guard attempt < attempts else { return .releaseTimedOut }
            do {
                try await pause()
            } catch {
                return .cancelled
            }
        }

        guard !Task.isCancelled else { return .cancelled }
        guard await create() else {
            return Task.isCancelled ? .cancelled : .creationFailed
        }

        releasePrevious()
        for _ in 0..<max(0, attempts) {
            guard !Task.isCancelled else { break }
            if arePreviousReleased() == true { break }
            do {
                try await pause()
            } catch {
                break
            }
        }
        await afterRelease?()
        return .activated
    }
}
