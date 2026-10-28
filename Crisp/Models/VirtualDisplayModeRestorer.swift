import Foundation

@MainActor
enum VirtualDisplayModeRestorer {
    /// Creation and mode registration are asynchronous. Never substitute a 1x mode for
    /// HiDPI or accept an IPC return value as proof: observe two matching current modes.
    static func restore<Mode>(
        target: VirtualDisplayModeSnapshot,
        current: () -> VirtualDisplayModeSnapshot?,
        available: () -> [Mode],
        describe: (Mode) -> VirtualDisplayModeSnapshot,
        apply: @MainActor (Mode) async -> Bool,
        attempts: Int = 8,
        pause: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(300)) }
    ) async -> Bool {
        var matchingObservations = 0
        for attempt in 0..<max(0, attempts) {
            guard !Task.isCancelled else { return false }
            if let mode = current(), target.matches(mode) {
                matchingObservations += 1
                if matchingObservations == 2 { return true }
            } else {
                matchingObservations = 0
                if let mode = available().first(where: {
                    let snapshot = describe($0)
                    return snapshot.usableForDesktop && target.matches(snapshot)
                }) {
                    // A timeout can leave a real commit in flight. Do not issue another.
                    guard await apply(mode) else { return false }
                }
            }
            if attempt + 1 < attempts {
                do { try await pause() } catch { return false }
            }
        }
        return false
    }
}
