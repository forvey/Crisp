import XCTest

final class VirtualDisplayConfigurationTests: XCTestCase {
    func testHiDPIUsesGenericDoubleDensityIncludingPortraitAndCustomSizes() throws {
        for (width, height) in [(3440, 1440), (1920, 1200), (2112, 1320), (1440, 3440), (1234, 777)] {
            let mode = VirtualDisplayDesktopMode(width: width, height: height, hiDPI: true)
            let config = try XCTUnwrap(VirtualDisplayConfiguration(name: "Any name", desktopMode: mode))
            XCTAssertEqual(config.width, width * 2)
            XCTAssertEqual(config.height, height * 2)
            XCTAssertEqual(config.desktopMode, mode)
            XCTAssertEqual(config.targetMode?.width, width)
            XCTAssertEqual(config.targetMode?.height, height)
        }
    }

    func testTurningHiDPIOffKeepsDesktopSizeAndUsesOnePixelPerPoint() throws {
        let on = try XCTUnwrap(VirtualDisplayConfiguration(
            name: "Arbitrary", desktopMode: .init(width: 2560, height: 1600, hiDPI: true)))
        let off = try XCTUnwrap(VirtualDisplayConfiguration(
            id: on.id, name: on.name, desktopMode: .init(width: 2560, height: 1600, hiDPI: false)))
        XCTAssertEqual(on.desktopMode.width, off.desktopMode.width)
        XCTAssertEqual(on.desktopMode.height, off.desktopMode.height)
        XCTAssertEqual(off.width, 2560)
        XCTAssertEqual(off.height, 1600)
        XCTAssertEqual(off.targetMode?.pixelWidth, off.targetMode?.width)
        XCTAssertFalse(off.desktopMode.hiDPI)
    }

    func testLegacyHiDPICapabilityDoesNotImplyPreferredHiDPIMode() throws {
        let data = Data("""
        {"id":"E5BF1040-4FBD-483F-A7D9-37A10EB797F5","name":"Old screen",
         "width":6880,"height":2880,"refreshRate":60,"hiDPI":true,"autoCreate":false}
        """.utf8)
        let config = try JSONDecoder().decode(VirtualDisplayConfiguration.self, from: data)
        XCTAssertNil(config.preferredMode)
        XCTAssertEqual(config.width, 6880)
        XCTAssertEqual(config.desktopMode.width, 6880)
        XCTAssertFalse(config.desktopMode.hiDPI)
        XCTAssertEqual(config.targetMode?.pixelWidth, 6880)
        XCTAssertFalse(config.autoCreate)
    }

    func testLegacyOrdinaryConfigurationRetainsAllSettings() throws {
        let original = VirtualDisplayConfiguration(name: "Legacy", width: 3440, height: 1440,
                                                   refreshRate: 75, hiDPI: false, autoCreate: true)
        let decoded = try JSONDecoder().decode(VirtualDisplayConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.desktopMode.hiDPI)
        XCTAssertEqual(decoded.targetMode?.refreshRate, 75)
    }

    func testSavedDesktopPreferenceSurvivesRepeatedRestartsWithoutDoublingAgain() throws {
        let original = try XCTUnwrap(VirtualDisplayConfiguration(
            name: "Screen", desktopMode: .init(width: 3440, height: 1440, hiDPI: true),
            refreshRate: 60, autoCreate: false))
        var config = original
        for _ in 0..<4 {
            config = try JSONDecoder().decode(VirtualDisplayConfiguration.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(config, original)
            XCTAssertEqual(config.width, 6880)
            XCTAssertEqual(config.desktopMode.width, 3440)
            XCTAssertTrue(config.desktopMode.hiDPI)
        }
    }

    func testSameBackingSizeCanDescribeTwoDifferentDesktopModes() throws {
        let normal = try XCTUnwrap(VirtualDisplayConfiguration(
            name: "Screen", desktopMode: .init(width: 6880, height: 2880, hiDPI: false)))
        let retina = try XCTUnwrap(VirtualDisplayConfiguration(
            name: "Screen", desktopMode: .init(width: 3440, height: 1440, hiDPI: true)))
        XCTAssertEqual(normal.width, retina.width)
        XCTAssertEqual(normal.height, retina.height)
        XCTAssertNotEqual(normal.targetMode, retina.targetMode)
        XCTAssertEqual(normal.desktopMode.width, 6880)
        XCTAssertEqual(retina.desktopMode.width, 3440)
    }

    func testInvalidAndOversizedInputsAreRejectedWithoutIntegerOverflow() {
        for width in [0, -1, 4097, 6880, Int.max, Int.min] {
            XCTAssertNil(VirtualDisplayConfiguration(
                name: "Screen", desktopMode: .init(width: width, height: 1200, hiDPI: true)))
        }
        XCTAssertNil(VirtualDisplayConfiguration(
            name: "Screen", desktopMode: .init(width: 1920, height: 4097, hiDPI: true)))
        XCTAssertNotNil(VirtualDisplayConfiguration(
            name: "Screen", desktopMode: .init(width: 4096, height: 4096, hiDPI: true)))
        XCTAssertNotNil(VirtualDisplayConfiguration(
            name: "Screen", desktopMode: .init(width: 8192, height: 4096, hiDPI: false)))
    }

    func testCorruptPreferenceDoesNotSelectAnUnrelatedMode() {
        var config = VirtualDisplayConfiguration(name: "Screen", width: 3440, height: 1440)
        config.preferredMode = .init(width: 3440, height: 1440, hiDPI: true)
        XCTAssertNil(config.targetMode) // Backing is only 1x, not the requested 2x.
        config.width = 6880
        config.height = 2880
        config.hiDPI = false
        XCTAssertNil(config.targetMode) // Required mode capability is disabled.
    }

    func testRefreshPreferenceIsOfferedFirstWithoutDuplicateRates() throws {
        let config = try XCTUnwrap(VirtualDisplayConfiguration(
            name: "Screen", desktopMode: .init(width: 1920, height: 1200, hiDPI: true), refreshRate: 60))
        XCTAssertEqual(config.offeredRefreshRates, [60, 75, 50])
        XCTAssertEqual(config.targetMode?.refreshRate, 60)
        for rate in [0.0, -60, Double.infinity, Double.nan] {
            XCTAssertNil(VirtualDisplayConfiguration(name: "Screen", desktopMode: config.desktopMode, refreshRate: rate))
        }
    }
}
