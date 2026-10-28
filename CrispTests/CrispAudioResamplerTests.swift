import XCTest

final class CrispAudioResamplerTests: XCTestCase {
    func testContinuousHardwareRateConversionChangesFrameCountAndPreservesAmplitude() throws {
        for rate in [44100.0, 48000.0, 96000.0] {
            let converter = try CrispAudioResampler(from: rate, to: 24000)
            var result: [Float] = []
            for _ in 0..<10 { result += try converter.convert([Float](repeating: 0.25, count: Int(rate / 50))) }
            XCTAssertEqual(Double(result.count), 4800, accuracy: 128)
            XCTAssertTrue(result.dropFirst(128).allSatisfy { abs($0 - 0.25) < 0.01 })
        }
    }

    func testNetwork24kConvertsTo48kVirtualMicrophoneContinuously() throws {
        let converter = try CrispAudioResampler(from: 24000, to: 48000)
        var samples: [Float] = []
        for _ in 0..<10 { samples += try converter.convert([Float](repeating: -0.4, count: 480)) }
        XCTAssertEqual(Double(samples.count), 9600, accuracy: 128)
        XCTAssertTrue(samples.dropFirst(128).allSatisfy { abs($0 + 0.4) < 0.01 })
    }
}
