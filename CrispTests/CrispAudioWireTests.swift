import Network
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

    func testAuthChallengeAndProofRoundTripAndRejection() {
        let clientNonce = CrispAudioAuth.randomNonceHex()
        let serverNonce = CrispAudioAuth.randomNonceHex()
        XCTAssertEqual(clientNonce.count, CrispAudioAuth.nonceHexLength)
        XCTAssertEqual(serverNonce.count, CrispAudioAuth.nonceHexLength)

        let initFrame = CrispAudioAuth.makeInitFrame(clientNonce: clientNonce)
        XCTAssertEqual(CrispAudioAuth.parseInit(Data(initFrame.dropFirst(4))), clientNonce)
        XCTAssertNil(CrispAudioAuth.parseInit(Data("SSE-CRISP-AUTH/1 short".utf8)))

        let challengeFrame = CrispAudioAuth.makeChallengeFrame(serverNonce: serverNonce)
        XCTAssertEqual(CrispAudioAuth.parseChallenge(Data(challengeFrame.dropFirst(4))), serverNonce)

        let proofFrame = CrispAudioAuth.makeProofFrame(
            sharedKey: "shared-secret",
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        let proofPayload = Data(proofFrame.dropFirst(4))
        XCTAssertTrue(CrispAudioAuth.verifyProof(
            proofPayload,
            sharedKey: "shared-secret",
            clientNonce: clientNonce,
            serverNonce: serverNonce
        ))
        XCTAssertFalse(CrispAudioAuth.verifyProof(
            proofPayload,
            sharedKey: "wrong-secret",
            clientNonce: clientNonce,
            serverNonce: serverNonce
        ))
        XCTAssertFalse(CrispAudioAuth.verifyProof(
            proofPayload,
            sharedKey: "",
            clientNonce: clientNonce,
            serverNonce: serverNonce
        ))
        XCTAssertFalse(CrispAudioAuth.verifyProof(
            Data("SSE-CRISP-PROOF/1 deadbeef".utf8),
            sharedKey: "shared-secret",
            clientNonce: clientNonce,
            serverNonce: serverNonce
        ))
    }

    func testServerAuthGateAndBackwardCompatibility() {
        final class StubBackend: CrispAudioBackend, @unchecked Sendable {
            var onFailure: @Sendable (String) -> Void = { _ in }
            var onMicrophoneUse: @Sendable (CrispAudioWire.MicrophoneUse) -> Void = { _ in }
            func halHealth() -> CrispHALDriverStatus { .ready }
            func validate() throws {}
            func start() throws {}
            func stop() {}
            func setMicrophone(_ enabled: Bool) throws {}
            func microphonePCM(_ bytes: Data) {}
            func downlinkPCM() -> Data { CrispAudioWire.silence }
        }

        let legacyReady = expectation(description: "legacy server listening")
        let legacyAccepted = expectation(description: "legacy hello accepted")
        let legacyServer = CrispAudioServer(backend: StubBackend(), sharedKey: { nil }) { state in
            if state.listening { legacyReady.fulfill() }
        }
        legacyReady.assertForOverFulfill = false
        legacyServer.start(port: 49567, loopbackOnly: true)
        wait(for: [legacyReady], timeout: 3)

        let legacyQueue = DispatchQueue(label: "test.audio.legacy")
        let legacyConn = NWConnection(host: "127.0.0.1", port: 49567, using: .tcp)
        legacyConn.start(queue: legacyQueue)
        legacyConn.send(content: CrispAudioWire.encode(.hello), completion: .contentProcessed { _ in
            legacyConn.receive(minimumIncompleteLength: 4 + CrispAudioWire.hello.count + 1,
                               maximumLength: 256) { data, _, _, error in
                if error == nil, let data, data.count >= CrispAudioWire.hello.count + 5 {
                    legacyAccepted.fulfill()
                }
            }
        })
        wait(for: [legacyAccepted], timeout: 3)
        legacyConn.cancel()
        legacyServer.stop()

        let authedReady = expectation(description: "authed server listening")
        let unauthRejected = expectation(description: "unauthenticated client rejected")
        let authSucceeded = expectation(description: "authenticated client accepted")
        let authedServer = CrispAudioServer(backend: StubBackend(), sharedKey: { "lan-key-42" }) { state in
            if state.listening { authedReady.fulfill() }
        }
        authedReady.assertForOverFulfill = false
        authedServer.start(port: 49568, loopbackOnly: true)
        wait(for: [authedReady], timeout: 3)

        let authQueue = DispatchQueue(label: "test.audio.auth")
        let unauthConn = NWConnection(host: "127.0.0.1", port: 49568, using: .tcp)
        unauthConn.stateUpdateHandler = { state in
            if case .failed = state { unauthRejected.fulfill() }
        }
        unauthConn.start(queue: authQueue)
        unauthConn.send(content: CrispAudioWire.encode(.hello), completion: .contentProcessed { _ in
            unauthConn.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, eof, error in
                if eof || error != nil || data == nil {
                    unauthRejected.fulfill()
                }
            }
        })
        unauthRejected.assertForOverFulfill = false
        wait(for: [unauthRejected], timeout: 3)
        unauthConn.cancel()

        let authConn = NWConnection(host: "127.0.0.1", port: 49568, using: .tcp)
        let clientNonce = CrispAudioAuth.randomNonceHex()
        authConn.start(queue: authQueue)
        Self.performClientAuth(
            connection: authConn,
            key: "lan-key-42",
            clientNonce: clientNonce,
            onAuthenticated: {
                authConn.send(content: CrispAudioWire.encode(.hello), completion: .contentProcessed { _ in
                    authConn.receive(minimumIncompleteLength: 5 + CrispAudioWire.hello.count,
                                     maximumLength: 256) { data, _, _, error in
                        if error == nil, let data, data.count >= 5 + CrispAudioWire.hello.count {
                            authSucceeded.fulfill()
                        }
                    }
                })
            }
        )
        wait(for: [authSucceeded], timeout: 4)
        authConn.cancel()
        authedServer.stop()
    }

    private static func performClientAuth(
        connection: NWConnection,
        key: String,
        clientNonce: String,
        onAuthenticated: @escaping @Sendable () -> Void
    ) {
        connection.send(content: CrispAudioAuth.makeInitFrame(clientNonce: clientNonce),
                        completion: .contentProcessed { _ in
            readFrame(on: connection) { payload in
                guard let payload, let serverNonce = CrispAudioAuth.parseChallenge(payload) else { return }
                let proof = CrispAudioAuth.makeProofFrame(
                    sharedKey: key,
                    clientNonce: clientNonce,
                    serverNonce: serverNonce
                )
                connection.send(content: proof, completion: .contentProcessed { _ in
                    readFrame(on: connection) { ack in
                        guard ack == CrispAudioAuth.okPayload else { return }
                        onAuthenticated()
                    }
                })
            }
        })
    }

    private static func readFrame(on connection: NWConnection, completion: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard error == nil, let header, header.count == 4 else { completion(nil); return }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard (1...256).contains(length) else { completion(nil); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, err in
                completion(err == nil ? body : nil)
            }
        }
    }
}
