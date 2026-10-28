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

    /// Re-query the actual display list after each wait; neither dropping an object nor
    /// receiving a removal notification proves WindowServer has finished releasing it.
    func activate(
        release: () -> Void,
        isReleased: () -> Bool?,
        create: @MainActor () async -> Bool,
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

        release()
        for attempt in 0...max(0, attempts) {
            guard !Task.isCancelled else { return .cancelled }
            guard let released = isReleased() else { return .enumerationFailed }
            if released {
                return await create() ? .activated : .creationFailed
            }
            guard attempt < attempts else { return .releaseTimedOut }
            do {
                try await pause()
            } catch {
                return .cancelled
            }
        }
        return .releaseTimedOut
    }
}
