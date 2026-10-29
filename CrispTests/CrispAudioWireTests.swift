import XCTest

final class CrispAudioWireTests: XCTestCase {
    func testExactContractBytes() {
        XCTAssertEqual(CrispAudioWire.port, 49555)
        XCTAssertEqual(CrispAudioWire.encode(.microphone(true)), Data([0, 0, 0, 2, 3, 1]))
        XCTAssertEqual(CrispAudioWire.encode(.microphoneUse(.inUse)), Data([0, 0, 0, 2, 4, 2]))
        XCTAssertEqual(CrispAudioWire.encode(.probe(2)), Data([0, 0, 0, 2, 5, 2]))
        XCTAssertEqual(Array(CrispAudioWire.encode(.pcm(CrispAudioWire.silence)).prefix(5)), [0, 0, 3, 193, 2])
    }

    func testEveryByteSplitAndConcatenatedFramesPreserveOrder() throws {
        let messages: [CrispAudioWire.Message] = [.hello, .microphoneUse(.unavailable), .microphoneUse(.idle),
            .microphoneUse(.inUse), .microphone(true), .pcm(Data(repeating: 42, count: 960)), .microphone(false)]
        let stream = messages.reduce(Data()) { $0 + CrispAudioWire.encode($1) }
        var decoder = CrispAudioWire.Decoder()
        var output: [CrispAudioWire.Message] = []
        for byte in stream { output += try decoder.receive(Data([byte])) }
        XCTAssertEqual(output, messages)
        var joined = CrispAudioWire.Decoder()
        XCTAssertEqual(try joined.receive(stream), messages)
    }

    func testBadLengthsKindsVersionsAndPayloadsAreRejected() {
        let invalid = [Data([0, 0, 0, 0]), Data([0, 0, 4, 1]), Data([255, 255, 255, 255]),
                       Data([0, 0, 0, 1, 99]), Data([0, 0, 0, 2, 3, 2]),
                       Data([0, 0, 0, 2, 4, 3]), Data([0, 0, 0, 1, 4]),
                       CrispAudioWire.encode(.pcm(Data([0]))),
                       Data([0, 0, 0, 5, 1]) + Data("old!".utf8)]
        for bytes in invalid {
            var decoder = CrispAudioWire.Decoder()
            XCTAssertThrowsError(try decoder.receive(bytes))
        }
        // A v1 peer cannot report real input use. Reject it rather than
        // silently restoring the previous always-on microphone behavior.
        var oldHello = CrispAudioWire.encode(.hello)
        oldHello.replaceSubrange(5..<oldHello.count, with: Data("SSE-CRISP-AUDIO/1 PCM_S16LE 24000 1 480".utf8))
        var oldDecoder = CrispAudioWire.Decoder()
        XCTAssertThrowsError(try oldDecoder.receive(oldHello))
        for suffix: UInt8 in [0, 10] {
            var bytes = CrispAudioWire.hello
            bytes[bytes.startIndex] = suffix
            var frame = CrispAudioWire.encode(.hello)
            frame.replaceSubrange(5..<frame.count, with: bytes)
            var decoder = CrispAudioWire.Decoder()
            XCTAssertThrowsError(try decoder.receive(frame))
        }
    }

    func testFirstMessageMustBeHelloAndHelloCannotRepeat() throws {
        var session = CrispAudioSession()
        XCTAssertThrowsError(try session.receive(.pcm(CrispAudioWire.silence), now: 0))
        XCTAssertThrowsError(try session.receive(.microphone(true), now: 0))
        XCTAssertThrowsError(try session.receive(.microphoneUse(.inUse), now: 0))
        XCTAssertThrowsError(try session.receive(.probeReply(Data("{}".utf8)), now: 0))
        XCTAssertEqual(try session.receive(.hello, now: 0), .replyHello)
        XCTAssertThrowsError(try session.receive(.hello, now: 0))
        // Only HAL-backed server state can enable demand, never a client message.
        XCTAssertThrowsError(try session.receive(.microphoneUse(.inUse), now: 0))
    }

    func testMicrophoneGatingDisconnectAndReconnect() throws {
        var session = CrispAudioSession()
        _ = try session.receive(.hello, now: 0)
        XCTAssertNil(try session.receive(.pcm(CrispAudioWire.silence), now: 0))
        XCTAssertEqual(try session.receive(.microphone(true), now: 1), .microphone(true))
        XCTAssertEqual(try session.receive(.pcm(CrispAudioWire.silence), now: 1), .microphonePCM(CrispAudioWire.silence))
        _ = try session.receive(.microphone(false), now: 1)
        XCTAssertNil(try session.receive(.pcm(CrispAudioWire.silence), now: 1))
        session.disconnect()
        _ = try session.receive(.hello, now: 2)
        XCTAssertFalse(session.microphoneEnabled)
        XCTAssertNil(try session.receive(.pcm(CrispAudioWire.silence), now: 2))
    }

    func testClosedMicrophoneDoesNotExpireAndOpenMicrophoneHas200msWatchdog() throws {
        var session = CrispAudioSession()
        _ = try session.receive(.hello, now: 0)
        XCTAssertFalse(session.microphoneExpired(now: 10000))
        _ = try session.receive(.microphone(true), now: 100)
        XCTAssertFalse(session.microphoneExpired(now: 100.1))
        XCTAssertTrue(session.microphoneExpired(now: 100.21))
        _ = try session.receive(.pcm(CrispAudioWire.silence), now: 100.22)
        XCTAssertFalse(session.microphoneExpired(now: 100.23))
    }

    func testReaderStartingAfterLongIdleGetsAFullWatchdogWindow() throws {
        // Permission can stay enabled while nobody reads. Starting a reader
        // later must not immediately classify that idle time as lost audio.
        var session = CrispAudioSession()
        _ = try session.receive(.hello, now: 0)
        _ = try session.receive(.microphone(true), now: 1)
        session.microphoneUseStarted(now: 100)
        XCTAssertFalse(session.microphoneExpired(now: 100.1))
        XCTAssertTrue(session.microphoneExpired(now: 100.21))
        _ = try session.receive(.microphone(false), now: 101)
        session.microphoneUseStarted(now: 102)
        XCTAssertFalse(session.microphoneExpired(now: 10000))
    }

    func testPCM16LittleEndianAndFiniteSaturation() {
        let raw = Data([0, 128, 255, 127, 0, 0, 0, 64])
        XCTAssertEqual(CrispAudioPCM.floats(raw), [-1, 32767.0 / 32768.0, 0, 0.5])
        XCTAssertEqual(CrispAudioPCM.bytes([-1, 1, .nan, 0.5]), raw)
        XCTAssertEqual(CrispAudioPCM.bytes([-2, 2]), Data([0, 128, 255, 127]))
    }
}
