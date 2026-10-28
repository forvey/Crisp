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

    private lazy var activationGate = VirtualDisplayActivationGate { [weak self] in
        self?.objectWillChange.send()
    }
    var isSwitching: Bool { activationGate.isBusy }
    private var isShuttingDown = false

    /// Strong references to live CGVirtualDisplay objects; releasing an entry destroys it.
    private var activeDisplayObjects: [UUID: CGVirtualDisplay] = [:]
    // Keep IDs after releasing their objects: metadata such as the vendor can disappear
    // before a retiring framebuffer actually leaves the online list.
    private var retiringDisplayIDs: Set<CGDirectDisplayID> = []

    private let configsKey = "crisp.VirtualDisplayConfigs"

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

    private func activate(config: VirtualDisplayConfig, recreate: Bool = false) async -> Bool {
        guard !isSwitching, !isShuttingDown else { return false }
        lastError = nil
        // Validate before releasing a working display, including doubled backing sizes.
        guard config.targetMode != nil else {
            lastError = String(localized: "Invalid virtual display size or refresh rate. Please edit this configuration.")
            return false
        }
        // Re-selecting an already-correct screen is a no-op. A changed or failed mode
        // must be restored rather than clearing its warning and claiming success.
        if !recreate, activeConfigIDs == [config.id], currentModeMatches(config) { return true }
        let result = await activationGate.activate(
            release: { self.releaseAllDisplays() },
            isReleased: { self.previousDisplaysReleased() },
            create: { await self.createDisplay(config: config) }
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

    private func createDisplay(config: VirtualDisplayConfig) async -> Bool {
        guard !Task.isCancelled, !isShuttingDown else { return false }
        // Registration pops macOS's own "what to show" picker, which steals key focus and
        // would trip the panel's auto-dismiss; harmless at launch since the panel isn't open then.
        PanelOpenGuard.suppressAutoDismiss = true
        defer {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                PanelOpenGuard.suppressAutoDismiss = false
            }
        }

        let w = config.width
        let h = config.height
        let hiDPI = config.hiDPI

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
        descriptor.serialNum = UInt32(ident.4) << 24 | UInt32(ident.5) << 16 | UInt32(ident.6) << 8 | UInt32(ident.7)
        // DO NOT set queue or color primaries: not needed, and may interfere with creation.

        guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            return false
        }

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

        // Blocks on WindowServer IPC.
        let vd = virtualDisplay
        let s = settings
        activationGate.applicationStarted()
        let applyResult: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            let result = vd.apply(s)
            let displayID = vd.displayID
            // The timeout only stops awaiting. Keep new activations blocked until the
            // real apply returns, even if its display has not appeared in the list yet.
            Task { @MainActor in
                if displayID != kCGNullDirectDisplay { self.retiringDisplayIDs.insert(displayID) }
                self.activationGate.applicationFinished()
            }
            return result
        }
        guard applyResult, !Task.isCancelled, !isShuttingDown else { return false }
        guard virtualDisplay.displayID != kCGNullDirectDisplay else { return false }

        activeDisplayObjects[config.id] = virtualDisplay
        activeConfigIDs.insert(config.id)

        if !(await applyPreferredMode(config, on: virtualDisplay.displayID)) {
            // Keep a successfully created screen reachable if mode selection fails. Persist
            // the configuration and show a durable warning instead of silently claiming HiDPI
            // worked or destroying the only screen used by a remote session.
            lastError = String(localized: "The display is active, but its saved mode could not be applied. Edit and save to retry.")
        }
        return true
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
        releaseAllDisplays()
    }

    private func releaseAllDisplays() {
        retiringDisplayIDs.formUnion(activeDisplayObjects.values.map(\.displayID))
        activeDisplayObjects.removeAll()
        activeConfigIDs.removeAll()
    }

    @discardableResult
    func destroy(configID: UUID) -> Bool {
        activationGate.noteManualActivity()
        guard !isSwitching else { return false }
        guard let displayID = activeDisplayObjects[configID]?.displayID else {
            return false
        }

        retiringDisplayIDs.insert(displayID)
        activeDisplayObjects.removeValue(forKey: configID)
        activeConfigIDs.remove(configID)

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
        destroy(configID: id)
        configs.removeAll { $0.id == id }
        saveConfigs()
    }

    /// Name/autoCreate update in place; resolution/HiDPI changes are baked into the live
    /// CGVirtualDisplay, so those destroy and recreate it.
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
        configs[idx] = updated
        saveConfigs()

        let geometryChanged = old.width != updated.width
            || old.height != updated.height
            || old.hiDPI != updated.hiDPI
            || old.refreshRate != updated.refreshRate
            || old.preferredMode != updated.preferredMode
        if isActive(updated.id) {
            if geometryChanged || !currentModeMatches(updated) {
                return await activate(config: updated, recreate: true)
            }
            lastError = nil
        }
        return true
    }

    /// Includes manually deactivated screens still tearing down and crash survivors.
    /// Other Crisp services' virtual helpers are not destroyed here; if one is still
    /// registered, fail closed rather than create an overlapping virtual framebuffer.
    private func previousDisplaysReleased() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else {
            retiringDisplayIDs.removeAll()
            return true
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        let online = Set(ids.prefix(Int(count)))
        retiringDisplayIDs.formIntersection(online)
        return retiringDisplayIDs.isEmpty
            && !online.contains { CGDisplayVendorNumber($0) == Self.crispVirtualVendorID }
    }

    // MARK: - Persistence

    private func loadConfigs() {
        guard let data = UserDefaults.standard.data(forKey: configsKey),
              let decoded = try? JSONDecoder().decode([VirtualDisplayConfig].self, from: data)
        else { return }
        configs = decoded

        // Delay lets WindowServer stabilise before re-creating autoCreate virtual displays.
        // An in-place update can preserve a native Screen Sharing display even
        // when a saved virtual profile has autoCreate enabled. This argument
        // affects this launch only and never rewrites the user's profiles.
        if !CommandLine.arguments.contains("--skip-virtual-display-restore"), configs.contains(where: { $0.autoCreate }) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                // Manual changes during the launch delay take precedence. Old configs
                // may have multiple autoCreate flags; restore only the first, without
                // cycling through them or silently changing any saved configuration.
                guard !self.isShuttingDown else { return }
                await self.activationGate.restoreFirst(from: self.configs, matching: { $0.autoCreate }) { config in
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
