import Foundation

/// User-facing desktop size. HiDPI changes the backing pixel density, never the aspect
/// ratio or the logical desktop size. No monitor name or particular resolution is special.
struct VirtualDisplayDesktopMode: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var hiDPI: Bool

    static let maximumPixelDimension = 8192

    var renderSize: (width: Int, height: Int)? {
        let scale = hiDPI ? 2 : 1
        let limit = Self.maximumPixelDimension / scale
        guard (1...limit).contains(width), (1...limit).contains(height) else { return nil }
        return (width * scale, height * scale)
    }
}

struct VirtualDisplayConfiguration: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    // Keep these existing keys in backing pixels for compatibility with older Crisp builds.
    var width: Int
    var height: Int
    var refreshRate: Double
    // Legacy field: makes HiDPI modes available, but does not say which mode was selected.
    var hiDPI: Bool
    var autoCreate: Bool
    var preferredMode: VirtualDisplayDesktopMode?

    init(id: UUID = UUID(), name: String, width: Int, height: Int,
         refreshRate: Double = 60, hiDPI: Bool = true, autoCreate: Bool = true,
         preferredMode: VirtualDisplayDesktopMode? = nil) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
        self.autoCreate = autoCreate
        self.preferredMode = preferredMode
    }

    init?(id: UUID = UUID(), name: String, desktopMode: VirtualDisplayDesktopMode,
          refreshRate: Double = 60, autoCreate: Bool = true) {
        guard let size = desktopMode.renderSize, refreshRate.isFinite, (1...240).contains(refreshRate) else { return nil }
        self.init(id: id, name: name, width: size.width, height: size.height,
                  refreshRate: refreshRate, hiDPI: desktopMode.hiDPI, autoCreate: autoCreate,
                  preferredMode: desktopMode)
    }

    /// Old records have no selected-mode metadata. Preserve their native 1x behavior;
    /// interpreting the old hiDPI capability bit as a preference would halve every desktop.
    var desktopMode: VirtualDisplayDesktopMode {
        preferredMode ?? VirtualDisplayDesktopMode(width: width, height: height, hiDPI: false)
    }

    var targetMode: VirtualDisplayModeSnapshot? {
        guard let size = desktopMode.renderSize, size.width == width, size.height == height,
              !desktopMode.hiDPI || hiDPI,
              refreshRate.isFinite, (1...240).contains(refreshRate) else { return nil }
        return VirtualDisplayModeSnapshot(width: desktopMode.width, height: desktopMode.height,
                                          pixelWidth: width, pixelHeight: height, refreshRate: refreshRate)
    }

    var offeredRefreshRates: [Double] {
        [refreshRate] + [75.0, 60.0, 50.0].filter { $0 != refreshRate }
    }
}

/// Attributes rather than volatile mode IDs: macOS can renumber modes on recreation.
struct VirtualDisplayModeSnapshot: Equatable, Sendable {
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshRate: Double
    var usableForDesktop: Bool = true

    func matches(_ other: Self) -> Bool {
        width == other.width && height == other.height
            && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
            && refreshRate > 0 && other.refreshRate > 0
            && abs(refreshRate - other.refreshRate) < 0.5
    }
}
