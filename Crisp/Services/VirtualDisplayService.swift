import CoreGraphics
import Foundation

// CGVirtualDisplay and CGVirtualDisplaySettings are ObjC objects without Sendable
// conformance, but we only use them sequentially (create on main → pass to background
// for apply → use result on main), so @unchecked Sendable is safe here.
extension CGVirtualDisplayDescriptor: @unchecked @retroactive Sendable {}
extension CGVirtualDisplay: @unchecked @retroactive Sendable {}
extension CGVirtualDisplaySettings: @unchecked @retroactive Sendable {}

/// Manages virtual display configurations and creates CGVirtualDisplay instances
/// using the private CGVirtualDisplay API declared in the bridging header.
@MainActor
final class VirtualDisplayService: ObservableObject, @unchecked Sendable {
    static let shared = VirtualDisplayService()
    private init() {
        loadConfigs()
    }

    // MARK: - Config Model

    typealias VirtualDisplayConfig = VirtualDisplayConfiguration

    // MARK: - State

    @Published var configs: [VirtualDisplayConfig] = []

    @Published private(set) var activeConfigIDs: Set<UUID> = []
    @Published private(set) var lastError: String?
    @Published var restoreAtLaunch: Bool = false

    private lazy var activationGate = VirtualDisplayActivationGate { [weak self] in
        self?.objectWillChange.send()
    }
    var isSwitching: Bool { activationGate.isBusy }
    private var isShuttingDown = false

    /// Strong references to live CGVirtualDisplay objects; releasing an entry destroys it.
    private var activeDisplayObjects: [UUID: CGVirtualDisplay] = [:]
    private var activeSerialSalts: [UUID: UInt32] = [:]
    // Keep IDs after releasing their objects: metadata such as the vendor can disappear
    // before a retiring framebuffer actually leaves the online list.
    private var retiringDisplayIDs: Set<CGDirectDisplayID> = []
    private var pendingCreations: Set<UUID> = []
    private var lastUsedConfigID: UUID?

    private let configsKey = "crisp.VirtualDisplayConfigs"
    private let restoreAtLaunchKey = "crisp.VirtualDisplayRestoreAtLaunch"
    private let lastActiveConfigIDKey = "crisp.VirtualDisplayLastActiveID"

    /// Vendor ID stamped on every Crisp virtual display's descriptor, and the race-free
    /// signature filtered on: CGDisplayVendorNumber reports it the instant the display is online.
    static let crispVirtualVendorID: UInt32 = 0xEEEE

    // MARK: - Queries

    func isActive(_ configID: UUID) -> Bool {
        activeConfigIDs.contains(configID)
    }

    func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        // Vendor ID first: it's live the instant the display is online, so a freshly created
        // one is filtered on the first refresh. The object set below is a backstop.
        if CGDisplayVendorNumber(displayID) == Self.crispVirtualVendorID { return true }
        return activeDisplayObjects.values.contains { $0.displayID == displayID }
    }

    // MARK: - Create / Destroy

    /// Creates a virtual display from the config. Descriptor build and CGVirtualDisplay init
    /// run on the main actor (the API requires it); only `apply` runs off-main, since it can
    /// block on WindowServer IPC. See docs/display-notes.md (VirtualDisplayService.create).
    @discardableResult
    func create(config: VirtualDisplayConfig) async -> Bool {
        activationGate.noteManualActivity()
        return await activate(config: config)
    }

    @discardableResult
    func activatePreferredOrFirst() async -> Bool {
        guard let target = preferredConfigToActivate() else { return false }
        return await create(config: target)
    }

    func clearError() {
        lastError = nil
    }

    func setRestoreAtLaunch(_ enabled: Bool) {
        restoreAtLaunch = enabled
        UserDefaults.standard.set(enabled, forKey: restoreAtLaunchKey)
    }

    private func preferredConfigToActivate() -> VirtualDisplayConfig? {
        if let id = lastUsedConfigID, let match = configs.first(where: { $0.id == id }) {
            return match
        }
        if let id = persistedLastActiveConfigID(), let match = configs.first(where: { $0.id == id }) {
            return match
        }
        return configs.first
    }

    private func activate(config: VirtualDisplayConfig, recreate: Bool = false) async -> Bool {
        guard !isSwitching, !isShuttingDown else { return false }
        lastError = nil
        // Validate before creating or touching a working display, including doubled backing sizes.
        guard config.targetMode != nil else {
            lastError = String(localized: "Invalid virtual display size or refresh rate. Please edit this configuration.")
            return false
        }
        // Re-selecting an already-correct screen is a no-op. A changed or failed mode
        // must be restored rather than clearing its warning and claiming success.
        if !recreate, activeConfigIDs == [config.id], currentModeMatches(config) { return true }

        let serialSalt: UInt32 = activeDisplayObjects[config.id] != nil ? ((activeSerialSalts[config.id] ?? 0) ^ 1) : 0
        var createdDisplay: (vd: CGVirtualDisplay, displayID: CGDirectDisplayID)?

        let result = await activationGate.activate(
            isRetiringClear: { self.retiringDisplaysCleared(excluding: self.ownedOnlineDisplayIDs()) },
            create: {
                guard let created = await self.createAndConfirmOnline(config: config, serialSalt: serialSalt) else {
                    return false
                }
                createdDisplay = created
                return true
            },
            releasePrevious: {
                guard let created = createdDisplay else { return }
                self.promoteCreatedDisplay(created.vd, for: config.id, serialSalt: serialSalt)
            },
            arePreviousReleased: {
                let exclude: Set<CGDirectDisplayID> = createdDisplay.map { [$0.displayID] } ?? []
                return self.retiringDisplaysCleared(excluding: exclude)
            },
            afterRelease: {
                guard let created = createdDisplay else { return }
                if !(await self.applyPreferredMode(config, on: created.displayID)) {
                    // Keep a successfully created screen reachable if mode selection fails. Persist
                    // the configuration and show a durable warning instead of silently claiming HiDPI
                    // worked or destroying the only screen used by a remote session.
                    self.lastError = String(
                        localized: "The display is active, but its saved mode could not be applied. Edit and save to retry."
                    )
                }
            }
        )
        switch result {
        case .activated:
            return true
        case .releaseTimedOut:
            lastError = String(localized: "The previous virtual display is still being released. Please try again.")
        case .enumerationFailed:
            lastError = String(localized: "Unable to verify that the previous virtual display has been released.")
        case .busy, .cancelled, .creationFailed:
            break
        }
        return false
    }

    private func promoteCreatedDisplay(_ virtualDisplay: CGVirtualDisplay, for configID: UUID, serialSalt: UInt32) {
        for (oldConfigID, oldVD) in activeDisplayObjects {
            if oldVD !== virtualDisplay && oldVD.displayID != kCGNullDirectDisplay {
                retiringDisplayIDs.insert(oldVD.displayID)
            }
            if oldConfigID != configID {
                activeSerialSalts.removeValue(forKey: oldConfigID)
            }
        }
        activeDisplayObjects = [configID: virtualDisplay]
        activeConfigIDs = [configID]
        activeSerialSalts[configID] = serialSalt
        lastUsedConfigID = configID
        saveLastActiveConfigID(configID)
    }

    private func createAndConfirmOnline(
        config: VirtualDisplayConfig,
        serialSalt: UInt32
    ) async -> (vd: CGVirtualDisplay, displayID: CGDirectDisplayID)? {
        guard !Task.isCancelled, !isShuttingDown else { return nil }
        // Registration pops macOS's own "what to show" picker, which steals key focus and
        // would trip the panel's auto-dismiss; harmless at launch since the panel isn't open then.
        PanelOpenGuard.suppressAutoDismiss = true
        let suppressGeneration = PanelOpenGuard.suppressGeneration
        defer {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if PanelOpenGuard.suppressGeneration == suppressGeneration {
                    PanelOpenGuard.suppressAutoDismiss = false
                }
            }
        }

        guard let descriptor = buildDescriptor(for: config, serialSalt: serialSalt),
              let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            lastError = String(localized: "Failed to create virtual display. Please try again.")
            return nil
        }

        let settings = buildSettings(for: config)
        let vd = virtualDisplay
        let attemptToken = UUID()
        pendingCreations.insert(attemptToken)
        activationGate.applicationStarted()
        let applyResult: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            let result = vd.apply(settings)
            let displayID = vd.displayID
            // The timeout only stops awaiting. Keep new activations blocked until the
            // real apply returns, and track its displayID only if this attempt was abandoned.
            Task { @MainActor in
                self.activationGate.applicationFinished()
                let isAbandoned = !self.pendingCreations.contains(attemptToken)
                    && !self.activeDisplayObjects.values.contains(where: { $0 === vd })
                if isAbandoned && displayID != kCGNullDirectDisplay {
                    self.retiringDisplayIDs.insert(displayID)
                }
            }
            return result
        }
        pendingCreations.remove(attemptToken)

        let displayID = virtualDisplay.displayID
        guard applyResult, !Task.isCancelled, !isShuttingDown, displayID != kCGNullDirectDisplay else {
            if displayID != kCGNullDirectDisplay { retiringDisplayIDs.insert(displayID) }
            if !Task.isCancelled, !isShuttingDown, lastError == nil {
                lastError = String(localized: "Failed to create virtual display. Please try again.")
            }
            return nil
        }

        guard await waitForDisplayOnline(displayID) else {
            retiringDisplayIDs.insert(displayID)
            if !Task.isCancelled, !isShuttingDown {
                lastError = String(localized: "The new virtual display did not come online in time. Your previous display was kept.")
            }
            return nil
        }

        return (virtualDisplay, displayID)
    }

    private func buildDescriptor(for config: VirtualDisplayConfig, serialSalt: UInt32) -> CGVirtualDisplayDescriptor? {
        let w = config.width
        let h = config.height
        // CGVirtualDisplay(descriptor:) requires the main thread (returns nil off it).
        let descriptor = CGVirtualDisplayDescriptor()
        // Size from a fixed PPI so macOS defaults to the native resolution instead of a
        // scaled Retina mode. See docs/display-notes.md (VirtualDisplayService.create).
        let ppi: Double = 110.0
        descriptor.sizeInMillimeters = CGSize(
            width: Double(w) / ppi * 25.4,
            height: Double(h) / ppi * 25.4
        )
        descriptor.maxPixelsWide = UInt32(w)
        descriptor.maxPixelsHigh = UInt32(h)
        descriptor.name = config.name.isEmpty ? String(localized: "Crisp Virtual") : config.name
        descriptor.vendorID = Self.crispVirtualVendorID  // must be non-zero or init returns nil
        // Must be unique per config AND stable across recreations (macOS keys per-display
        // settings, including "what to show", on this identity). Both halves from the config UUID.
        let ident = config.id.uuid
        descriptor.productID = UInt32(ident.0) << 24 | UInt32(ident.1) << 16 | UInt32(ident.2) << 8 | UInt32(ident.3)
        let baseSerial = UInt32(ident.4) << 24 | UInt32(ident.5) << 16 | UInt32(ident.6) << 8 | UInt32(ident.7)
        descriptor.serialNum = baseSerial ^ serialSalt
        return descriptor
    }

    private func buildSettings(for config: VirtualDisplayConfig) -> CGVirtualDisplaySettings {
        let w = config.width
        let h = config.height
        let hiDPI = config.hiDPI
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI

        var modes: [CGVirtualDisplayMode] = []
        let refreshRates = config.offeredRefreshRates
        for rate in refreshRates {
            modes.append(CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: rate))
        }
        if hiDPI {
            let hw = w / 2, hh = h / 2
            if hw >= 1, hh >= 1 {
                for rate in refreshRates {
                    modes.append(CGVirtualDisplayMode(width: UInt(hw), height: UInt(hh), refreshRate: rate))
                }
            }
            let qw = w / 4, qh = h / 4
            if qw >= 1, qh >= 1 {
                for rate in refreshRates {
                    modes.append(CGVirtualDisplayMode(width: UInt(qw), height: UInt(qh), refreshRate: rate))
                }
            }
        }
        settings.modes = modes
        return settings
    }

    private func waitForDisplayOnline(_ displayID: CGDirectDisplayID) async -> Bool {
        for attempt in 0..<30 {
            guard !Task.isCancelled, !isShuttingDown else { return false }
            if let online = Self.onlineDisplayIDSet(), online.contains(displayID) {
                return true
            }
            if attempt < 29 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return false
    }

    private func applyPreferredMode(_ config: VirtualDisplayConfig, on displayID: CGDirectDisplayID) async -> Bool {
        guard let target = config.targetMode else { return false }
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return await VirtualDisplayModeRestorer.restore(
            target: target,
            current: { CGDisplayCopyDisplayMode(displayID).map(Self.snapshot) },
            available: { CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? [] },
            describe: Self.snapshot,
            apply: { mode in
                guard !self.isShuttingDown else { return false }
                self.activationGate.applicationStarted()
                return await ResolutionService.applyModeSync(mode, on: displayID, didComplete: {
                    Task { @MainActor in self.activationGate.applicationFinished() }
                })
            }
        )
    }

    private static func snapshot(_ mode: CGDisplayMode) -> VirtualDisplayModeSnapshot {
        VirtualDisplayModeSnapshot(width: mode.width, height: mode.height,
                                   pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                                   refreshRate: mode.refreshRate, usableForDesktop: mode.isUsableForDesktopGUI())
    }

    private func currentModeMatches(_ config: VirtualDisplayConfig) -> Bool {
        guard let displayID = activeDisplayObjects[config.id]?.displayID,
              let target = config.targetMode,
              let mode = CGDisplayCopyDisplayMode(displayID) else { return false }
        return target.matches(Self.snapshot(mode))
    }

    func destroyAll() {
        isShuttingDown = true
        releaseAllDisplays(clearPersistedActive: false)
    }

    func destroyAllActive() {
        activationGate.noteManualActivity()
        guard !isSwitching else { return }
        lastError = nil
        releaseAllDisplays(clearPersistedActive: true)
    }

    private func releaseAllDisplays(clearPersistedActive: Bool) {
        retiringDisplayIDs.formUnion(activeDisplayObjects.values.map(\.displayID).filter { $0 != kCGNullDirectDisplay })
        activeDisplayObjects.removeAll()
        activeConfigIDs.removeAll()
        activeSerialSalts.removeAll()
        if clearPersistedActive {
            saveLastActiveConfigID(nil)
        }
    }

    @discardableResult
    func destroy(configID: UUID) -> Bool {
        activationGate.noteManualActivity()
        guard !isSwitching else { return false }
        guard let displayID = activeDisplayObjects[configID]?.displayID else {
            return false
        }

        if displayID != kCGNullDirectDisplay {
            retiringDisplayIDs.insert(displayID)
        }
        activeDisplayObjects.removeValue(forKey: configID)
        activeConfigIDs.remove(configID)
        activeSerialSalts.removeValue(forKey: configID)
        if persistedLastActiveConfigID() == configID {
            saveLastActiveConfigID(nil)
        }

        return true
    }

    // MARK: - Config Management

    @discardableResult
    func addAndCreate(_ config: VirtualDisplayConfig) async -> Bool {
        guard !configs.contains(where: { $0.id == config.id }) else {
            return await create(config: config)
        }
        // Create first; only persist on success to avoid stale config if process crashes.
        if await create(config: config) {
            configs.append(config)
            saveConfigs()
            return true
        }
        return false
    }

    func removeConfig(id: UUID) {
        activationGate.noteManualActivity()
        guard !isSwitching else { return }
        _ = destroy(configID: id)
        configs.removeAll { $0.id == id }
        if lastUsedConfigID == id {
            lastUsedConfigID = configs.first?.id
        }
        if persistedLastActiveConfigID() == id {
            saveLastActiveConfigID(nil)
        }
        saveConfigs()
    }

    /// Name updates in place; resolution/HiDPI/refresh changes require recreating the
    /// live CGVirtualDisplay via Create-Before-Destroy. Only persists to UserDefaults
    /// after the new display succeeds so a failed edit never corrupts saved config.
    @discardableResult
    func updateConfig(_ updated: VirtualDisplayConfig) async -> Bool {
        activationGate.noteManualActivity()
        guard !isSwitching else { return false }
        guard updated.targetMode != nil else {
            lastError = String(localized: "Invalid virtual display size or refresh rate. Please edit this configuration.")
            return false
        }
        guard let idx = configs.firstIndex(where: { $0.id == updated.id }) else { return false }
        let old = configs[idx]

        let geometryChanged = old.width != updated.width
            || old.height != updated.height
            || old.hiDPI != updated.hiDPI
            || old.refreshRate != updated.refreshRate
            || old.preferredMode != updated.preferredMode
        if isActive(updated.id) {
            if geometryChanged || !currentModeMatches(updated) {
                guard await activate(config: updated, recreate: true) else {
                    return false
                }
                if let currentIdx = configs.firstIndex(where: { $0.id == updated.id }) {
                    configs[currentIdx] = updated
                    saveConfigs()
                }
                return true
            }
            lastError = nil
        }
        configs[idx] = updated
        saveConfigs()
        return true
    }

    private func ownedOnlineDisplayIDs() -> Set<CGDirectDisplayID> {
        Set(activeDisplayObjects.values.map(\.displayID).filter { $0 != kCGNullDirectDisplay })
    }

    private static func onlineDisplayIDSet() -> Set<CGDirectDisplayID>? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return Set(ids.prefix(Int(count)))
    }

    /// Checks whether retiring screens (from prior teardown or crash survivors) are gone.
    /// Excludes currently owned active displays so Create-Before-Destroy can coexist briefly.
    private func retiringDisplaysCleared(excluding ownedIDs: Set<CGDirectDisplayID>) -> Bool? {
        guard let online = Self.onlineDisplayIDSet() else { return nil }
        guard !online.isEmpty else {
            retiringDisplayIDs.removeAll()
            return true
        }
        retiringDisplayIDs.formIntersection(online)
        let hasStrayVirtual = online.contains { id in
            guard CGDisplayVendorNumber(id) == Self.crispVirtualVendorID else { return false }
            guard !ownedIDs.contains(id) else { return false }
            guard !MirroredModeService.isMirrorVirtual(id) else { return false }
            guard CGDisplaySerialNumber(id) != 0xB11C else { return false }
            return true
        }
        return retiringDisplayIDs.isEmpty && !hasStrayVirtual
    }

    // MARK: - Persistence

    private func persistedLastActiveConfigID() -> UUID? {
        UserDefaults.standard.string(forKey: lastActiveConfigIDKey).flatMap(UUID.init)
    }

    private func saveLastActiveConfigID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: lastActiveConfigIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastActiveConfigIDKey)
        }
    }

    private func loadConfigs() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: configsKey),
           let decoded = try? JSONDecoder().decode([VirtualDisplayConfig].self, from: data) {
            configs = decoded
        }

        // One-time migration from per-config autoCreate to global restore-last-active.
        if defaults.object(forKey: restoreAtLaunchKey) == nil {
            let legacyTarget = configs.first(where: { $0.autoCreate })?.id
            restoreAtLaunch = legacyTarget != nil
            defaults.set(restoreAtLaunch, forKey: restoreAtLaunchKey)
            if let legacyTarget, persistedLastActiveConfigID() == nil {
                saveLastActiveConfigID(legacyTarget)
            }
        } else {
            restoreAtLaunch = defaults.bool(forKey: restoreAtLaunchKey)
        }

        var targetID = persistedLastActiveConfigID()
        if let id = targetID, !configs.contains(where: { $0.id == id }) {
            saveLastActiveConfigID(nil)
            targetID = nil
        }
        lastUsedConfigID = targetID ?? configs.first?.id

        // Delay lets WindowServer stabilise before restoring the last active virtual display.
        if !CommandLine.arguments.contains("--skip-virtual-display-restore"),
           restoreAtLaunch,
           let restoreID = targetID {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !self.isShuttingDown else { return }
                await self.activationGate.restoreFirst(from: self.configs, matching: { $0.id == restoreID }) { config in
                    _ = await self.activate(config: config)
                }
            }
        }
    }

    private func saveConfigs() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: configsKey)
    }
}
