import Foundation
import Network
import Darwin

/// Synthetic backend: no HAL device, process tap, microphone or speaker is opened.
final class SyntheticAudio: CrispAudioBackend, @unchecked Sendable {
    struct Snapshot { let active: Bool; let microphone: Bool; let received: Int; let resets: Int; let diagnosing: Bool }
    var onFailure: @Sendable (String) -> Void = { _ in }
    var onMicrophoneUse: @Sendable (CrispAudioWire.MicrophoneUse) -> Void = { _ in }
    private let lock = NSLock()
    private var enabled = false
    private var active = false
    private var received = 0
    private var resetCount = 0
    private var microphoneAvailable = true
    private var inputInUse = false
    private var diagnosing = false
    func setDiagnostics(_ recorder: LagRecorder?) { lock.lock(); diagnosing = recorder != nil; lock.unlock() }
    let downlink = CrispAudioPCM.bytes((0..<480).map { sin(Float($0) * 0.05) * 0.1 })
    let uplink = Data(repeating: 17, count: 960)
    func validate() throws {}
    func start() throws {
        lock.lock(); active = true; enabled = false
        let use: CrispAudioWire.MicrophoneUse = microphoneAvailable ? (inputInUse ? .inUse : .idle) : .unavailable
        lock.unlock()
        onMicrophoneUse(use)
    }
    func setInputInUse(_ inUse: Bool) {
        lock.lock(); inputInUse = inUse
        let use: CrispAudioWire.MicrophoneUse = microphoneAvailable ? (inUse ? .inUse : .idle) : .unavailable
        lock.unlock()
        onMicrophoneUse(use)
    }
    func stop() { lock.lock(); active = false; enabled = false; lock.unlock() }
    func setMicrophone(_ on: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if on, !microphoneAvailable { throw CrispAudioWire.Failure(reason: "Synthetic virtual microphone missing") }
        enabled = on
        if !on { resetCount += 1 }
    }
    func setMicrophoneAvailable(_ available: Bool) { lock.lock(); microphoneAvailable = available; lock.unlock() }
    func microphonePCM(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        precondition(enabled && active && bytes == uplink, "Ungated or corrupt upstream audio")
        received += 1
    }
    func downlinkPCM() -> Data { downlink }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(active: active, microphone: enabled, received: received, resets: resetCount, diagnosing: diagnosing)
    }
}

/// Real diagnostic frames against the real listener; never opens hardware.
final class DiagnosticPeer: @unchecked Sendable {
    let id = UUID().uuidString
    private let queue = DispatchQueue(label: "DiagnosticPeer")
    private let connection: NWConnection
    private let lock = NSLock()
    private var parser = LagWire.Parser()
    private var messages: [LagMessage] = []
    private var closed = false
    private var sentAt = 0.0
    private var closedAfter = 0.0
    init(port: UInt16, duration: Double = 3, malformed: Bool = false, delayBeforeStart: Double = 0) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: AudioWire.parameters())
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.connection.send(content: LagWire.framed(LagWire.hello), completion: .contentProcessed { _ in })
                let message = LagMessage(kind: "start", version: malformed ? 99 : 1, id: self.id, scope: .both, duration: duration)
                self.queue.asyncAfter(deadline: .now() + delayBeforeStart) {
                    self.lock.lock(); self.sentAt = LagRecorder.now(); self.lock.unlock()
                    self.connection.send(content: Self.encoded(message), completion: .contentProcessed { _ in })
                }
                self.receive()
            }
        }
        connection.start(queue: queue)
    }
    private static func encoded(_ message: LagMessage) -> Data {
        do { return try LagWire.encode(message) } catch {
            preconditionFailure("Synthetic diagnostic message could not be encoded: \(error)")
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, eof, error in
            guard let self else { return }
            if let data, let messages = try? self.parser.append(data) {
                self.lock.lock(); self.messages += messages; self.lock.unlock()
            }
            if eof || error != nil {
                self.lock.lock(); self.closed = true; self.closedAfter = LagRecorder.now() - self.sentAt; self.lock.unlock()
            } else { self.receive() }
        }
    }
    func count(_ kind: String) -> Int { lock.lock(); defer { lock.unlock() }; return messages.filter { $0.kind == kind }.count }
    func isClosed() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }
    func elapsed() -> Double { lock.lock(); defer { lock.unlock() }; return closedAfter }
    func cancel() { connection.cancel() }
    func stop(appendRestart: Bool = false) {
        var data = Self.encoded(LagMessage(kind: "stop", id: id))
        if appendRestart {
            data += Self.encoded(LagMessage(kind: "start", id: id, scope: .both, duration: 60))
        }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var times: [Double] = []
    func increment() {
        lock.lock(); value += 1
        if times.count < 50 { times.append(ProcessInfo.processInfo.systemUptime) }
        lock.unlock()
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func span() -> Double { lock.lock(); defer { lock.unlock() }; return (times.last ?? 0) - (times.first ?? 0) }
}

@main struct RealControllerInterop {
    // Keep synthetic malformed-peer tests away from a running Crisp on 49555.
    static let testPort: UInt16 = 49556

    static func wait(_ condition: () -> Bool, seconds: Double = 5) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        precondition(condition(), "Timed out waiting for test condition")
    }

    static func malformed(_ bytes: Data) {
        let queue = DispatchQueue(label: "MalformedAudioPeer")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: testPort)!, using: AudioWire.parameters())
        let done = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { phase in
            if case .ready = phase {
                connection.send(content: bytes, completion: .contentProcessed { _ in })
                func receive() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, eof, error in
                        if eof || error != nil { done.signal() } else { receive() }
                    }
                }
                receive()
            }
        }
        connection.start(queue: queue)
        precondition(done.wait(timeout: .now() + 4) == .success, "Malformed client not disconnected")
        connection.cancel()
    }

    static func idleHandshakeExpires() {
        let closed = DispatchSemaphore(value: 0)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: testPort)!, using: AudioWire.parameters())
        connection.stateUpdateHandler = { phase in
            if case .ready = phase {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, eof, error in
                    if eof || error != nil { closed.signal() }
                }
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        connection.start(queue: DispatchQueue(label: "IdleHandshake"))
        precondition(closed.wait(timeout: .now() + 10) == .success, "Unfinished handshake was not expired")
        precondition(ProcessInfo.processInfo.systemUptime - start >= 7.5)
        connection.cancel()
    }

    static func main() throws {
        let backend = SyntheticAudio()
        let ready = DispatchSemaphore(value: 0)
        let server = CrispAudioServer(backend: backend) { state in
            if let error = state.error { FileHandle.standardError.write(Data("Synthetic server: \(error)\n".utf8)) }
            if state.listening { ready.signal() }
        }
        server.start(port: testPort, loopbackOnly: true)
        precondition(ready.wait(timeout: .now() + 5) == .success)
        // Diagnosis with BOTH audio controls off must not start capture, reset
        // the microphone or keep sampling beyond the independently set timeout.
        let resets = backend.snapshot().resets
        let onlyDiagnostic = DiagnosticPeer(port: testPort, duration: 1.2)
        wait({ onlyDiagnostic.count("started") == 1 && backend.snapshot().diagnosing })
        precondition(!backend.snapshot().active && !backend.snapshot().microphone
                     && backend.snapshot().resets == resets)
        wait({ onlyDiagnostic.count("sample") >= 1 })
        wait({ onlyDiagnostic.isClosed() && !backend.snapshot().diagnosing })
        FileHandle.standardError.write(Data("Diagnostic deadline: requested 1.2 s, observed \(onlyDiagnostic.elapsed()) s\n".utf8))
        precondition(onlyDiagnostic.elapsed() < 1.7, "Diagnostic deadline waited for the next one-second sample tick")
        let samplesAfterStop = onlyDiagnostic.count("sample")
        Thread.sleep(forTimeInterval: 1.1)
        precondition(onlyDiagnostic.count("sample") == samplesAfterStop, "Expired diagnostics kept sampling")
        onlyDiagnostic.cancel()
        let stoppedDiagnostic = DiagnosticPeer(port: testPort, duration: 10)
        wait({ stoppedDiagnostic.count("started") == 1 && backend.snapshot().diagnosing })
        stoppedDiagnostic.stop(appendRestart: true)
        wait({ stoppedDiagnostic.isClosed() && !backend.snapshot().diagnosing })
        precondition(stoppedDiagnostic.count("started") == 1,
                     "Frames after stop restarted an orphan recorder")

        // The actual controller session collects both ends and clock bounds,
        // then times out. No manual test-only client substitutes its lifecycle.
        var finalDiagnostic: LagReport?
        let actualDiagnostic = LagSession(host: "127.0.0.1", scope: .both,
                                          pid: getpid(), port: testPort, duration: 3) { report, active, _ in
            if !active { finalDiagnostic = report }
        }
        actualDiagnostic.start()
        let diagnosticDeadline = Date().addingTimeInterval(6)
        while finalDiagnostic == nil && Date() < diagnosticDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(finalDiagnostic != nil, "Actual controller failed to stop")
        precondition(!finalDiagnostic!.local.isEmpty && !finalDiagnostic!.remote.isEmpty && !finalDiagnostic!.clocks.isEmpty)
        wait({ !backend.snapshot().diagnosing })
        precondition(!backend.snapshot().active && !backend.snapshot().microphone)
        let invalidDuration = DiagnosticPeer(port: testPort, duration: 61)
        wait({ invalidDuration.isClosed() })
        precondition(invalidDuration.count("started") == 0 && !backend.snapshot().diagnosing)
        var maximumDiagnosticSeconds: Double?
        if CommandLine.arguments.contains("--full-lifecycle") {
            maximumDiagnosticSeconds = LagLifecycleTests.maximumDuration(port: testPort)
            wait({ !backend.snapshot().diagnosing })
            MainActor.assumeIsolated { LagLifecycleTests.pattern() }
        }
        let client = AudioTransport() // Actual committed ScreenSharingEnhancer code, not a substitute.
        let welcomed = DispatchSemaphore(value: 0)
        let heard = Counter()
        let use = Counter()
        client.onReady = { welcomed.signal() }
        client.onMicrophoneUse = { _ in use.increment() }
        client.onPCM = { bytes in precondition(bytes == backend.downlink); heard.increment() }
        client.connect(host: "127.0.0.1", port: testPort)
        precondition(welcomed.wait(timeout: .now() + 5) == .success)
        wait({ heard.count() >= 25 })
        // A malformed diagnostic and a valid parallel session must not claim
        // or reset the existing audio slot. Cancel releases diagnostic ownership.
        let invalidDiagnostic = DiagnosticPeer(port: testPort, malformed: true)
        wait({ invalidDiagnostic.isClosed() }); invalidDiagnostic.cancel()
        let parallelDiagnostic = DiagnosticPeer(port: testPort, duration: 10)
        wait({ parallelDiagnostic.count("started") == 1 && backend.snapshot().diagnosing })
        let beforeDiagnostic = heard.count()
        wait({ heard.count() >= beforeDiagnostic + 15 && parallelDiagnostic.count("sample") >= 1 })
        precondition(backend.snapshot().active)
        parallelDiagnostic.cancel()
        wait({ !backend.snapshot().diagnosing })
        precondition(backend.snapshot().active, "Diagnostic disconnect stopped audio")
        precondition(!backend.snapshot().microphone, "Microphone must default off")
        client.sendMicrophone(true)
        let beforeIdle = backend.snapshot().received
        client.sendPCM(backend.uplink)
        Thread.sleep(forTimeInterval: 0.3)
        precondition(!backend.snapshot().microphone && backend.snapshot().received == beforeIdle,
                     "Permission alone started idle microphone transmission")
        let useBefore = use.count()
        backend.setInputInUse(true)
        wait({ use.count() > useBefore && backend.snapshot().microphone })
        for _ in 0..<3 { client.sendPCM(backend.uplink) }
        wait({ backend.snapshot().received == beforeIdle + 3 })
        let useActive = use.count()
        backend.setInputInUse(false)
        wait({ use.count() > useActive && !backend.snapshot().microphone })
        let stoppedAt = backend.snapshot().received
        client.sendPCM(backend.uplink)
        Thread.sleep(forTimeInterval: 0.3)
        precondition(backend.snapshot().received == stoppedAt, "Last reader stopped but audio was still delivered")
        let useIdle = use.count()
        backend.setInputInUse(true)
        wait({ use.count() > useIdle && backend.snapshot().microphone })
        let steadyInput = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SteadySyntheticMicrophone"))
        steadyInput.schedule(deadline: .now(), repeating: .milliseconds(20))
        steadyInput.setEventHandler { client.sendPCM(backend.uplink) }
        steadyInput.resume()
        let beforeSecond = backend.snapshot().resets

        let rejected = DispatchSemaphore(value: 0)
        let second = AudioTransport()
        second.onReady = { preconditionFailure("Second client displaced the first") }
        second.onFailure = { _ in rejected.signal() }
        second.connect(host: "127.0.0.1", port: testPort)
        precondition(rejected.wait(timeout: .now() + 5) == .success)
        wait({ backend.snapshot().microphone })
        precondition(backend.snapshot().resets == beforeSecond, "Second client reset the first microphone")
        second.disconnect()
        steadyInput.cancel()
        let beforeGap = backend.snapshot().resets
        wait({ backend.snapshot().resets > beforeGap }) // 200-ms uplink gap flushes without dropping the client.
        client.sendMicrophone(false)
        wait({ !backend.snapshot().microphone })
        wait({ heard.count() >= 50 })
        precondition(heard.span() >= 0.8, "Packets were batched rather than paced every 20 ms")
        client.disconnect()
        wait({ !backend.snapshot().active })

        let reconnect = AudioTransport()
        let reconnected = DispatchSemaphore(value: 0)
        let reconnectUse = DispatchSemaphore(value: 0)
        let received = Counter()
        reconnect.onReady = { reconnected.signal() }
        reconnect.onMicrophoneUse = { value in if value == .inUse { reconnectUse.signal() } }
        reconnect.onPCM = { bytes in precondition(bytes == backend.downlink); received.increment() }
        reconnect.connect(host: "127.0.0.1", port: testPort)
        precondition(reconnected.wait(timeout: .now() + 5) == .success)
        precondition(reconnectUse.wait(timeout: .now() + 5) == .success)
        precondition(!backend.snapshot().microphone, "Reconnect resumed the previous microphone state")
        reconnect.sendMicrophone(true)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SyntheticMicrophone"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { reconnect.sendPCM(backend.uplink) }
        timer.resume()
        var before = rusage(), after = rusage()
        getrusage(RUSAGE_SELF, &before)
        let start = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: 5)
        let duration = ProcessInfo.processInfo.systemUptime - start
        getrusage(RUSAGE_SELF, &after)
        timer.cancel()
        reconnect.sendMicrophone(false)
        reconnect.disconnect()
        wait({ !backend.snapshot().active })
        let cpuBefore = Double(before.ru_utime.tv_sec + before.ru_stime.tv_sec)
            + Double(before.ru_utime.tv_usec + before.ru_stime.tv_usec) / 1e6
        let cpuAfter = Double(after.ru_utime.tv_sec + after.ru_stime.tv_sec)
            + Double(after.ru_utime.tv_usec + after.ru_stime.tv_usec) / 1e6

        // Missing/old input reports unavailable. Even an allowed microphone
        // stays closed, while the independent speaker connection keeps working.
        backend.setMicrophoneAvailable(false)
        let listenOnly = AudioTransport()
        let listenReady = DispatchSemaphore(value: 0)
        let micUnavailable = DispatchSemaphore(value: 0)
        let listenPackets = Counter()
        listenOnly.onReady = { listenReady.signal() }
        listenOnly.onPCM = { _ in listenPackets.increment() }
        listenOnly.onFailure = { reason in preconditionFailure(reason) }
        listenOnly.onMicrophoneUse = { value in if value == .unavailable { micUnavailable.signal() } }
        listenOnly.connect(host: "127.0.0.1", port: testPort)
        precondition(listenReady.wait(timeout: .now() + 5) == .success)
        wait({ listenPackets.count() >= 10 })
        precondition(!backend.snapshot().microphone)
        let beforeMissingMic = backend.snapshot().received
        listenOnly.sendMicrophone(true)
        precondition(micUnavailable.wait(timeout: .now() + 5) == .success)
        listenOnly.sendPCM(backend.uplink)
        let heardBefore = listenPackets.count()
        wait({ listenPackets.count() >= heardBefore + 10 })
        precondition(backend.snapshot().active && backend.snapshot().received == beforeMissingMic && !backend.snapshot().microphone)
        listenOnly.disconnect()
        wait({ !backend.snapshot().active })
        backend.setMicrophoneAvailable(true)

        // Explicit self-test uses the production server/transport. Generated
        // frames replace downlink only during the requested speaker stage;
        // a busy virtual input must reject the microphone stage, not hijack it.
        backend.setInputInUse(true)
        let probeClient = AudioTransport()
        let probeReady = DispatchSemaphore(value: 0)
        let probeStarted = DispatchSemaphore(value: 0)
        let probeStopped = DispatchSemaphore(value: 0)
        let probeRejected = DispatchSemaphore(value: 0)
        let probePackets = Counter()
        let expectedProbe = Set((0..<64).map { AudioProbeSignal.pcm($0) })
        probeClient.onReady = { probeReady.signal() }
        probeClient.onPCM = { if expectedProbe.contains($0) { probePackets.increment() } }
        probeClient.onProbeReply = { data in
            let reply = try! JSONDecoder().decode(AudioProbeReply.self, from: data)
            if reply.state == "ready" { probeStarted.signal() }
            if reply.state == "result" { probeStopped.signal() }
            if reply.state == "error" { probeRejected.signal() }
        }
        probeClient.connect(host: "127.0.0.1", port: testPort)
        precondition(probeReady.wait(timeout: .now() + 5) == .success)
        probeClient.probe(1)
        precondition(probeStarted.wait(timeout: .now() + 5) == .success)
        wait({ probePackets.count() >= 10 })
        probeClient.probe(0)
        precondition(probeStopped.wait(timeout: .now() + 5) == .success)
        probeClient.probe(2)
        precondition(probeRejected.wait(timeout: .now() + 5) == .success)
        precondition(!backend.snapshot().microphone)
        probeClient.disconnect()
        wait({ !backend.snapshot().active })

        malformed(CrispAudioWire.encode(.pcm(CrispAudioWire.silence)))
        malformed(CrispAudioWire.encode(.hello) + CrispAudioWire.encode(.probe(3)))
        malformed(CrispAudioWire.encode(.hello) + CrispAudioWire.encode(.probeReply(Data("{}".utf8))))
        malformed(Data([0, 0, 4, 1]))
        malformed(Data([0, 0, 0, 5, 1]) + Data("bad!".utf8))
        malformed(CrispAudioWire.encode(.hello) + CrispAudioWire.encode(.hello))
        malformed(CrispAudioWire.encode(.hello) + CrispAudioWire.encode(.pcm(Data([0]))))
        idleHandshakeExpires()
        wait({ !backend.snapshot().active })
        server.shutdown()
        var report: [String: Any] = ["result": "passed", "realControllerSource": true, "hardwareOpened": false,
            "duplexSeconds": duration, "cpuPercentOneCore": (cpuAfter - cpuBefore) / duration * 100,
            "processPeakRSSBytes": after.ru_maxrss, "downlinkPacketsInFiveSeconds": received.count(),
            "uplinkPacketsTotal": backend.snapshot().received, "PCMBitrateEachDirection": 384000,
            "first50PacketSpanSeconds": heard.span(), "listenWithoutVirtualInput": true]
        report["diagnosticDeadlineRequestedSeconds"] = 1.2
        report["diagnosticDeadlineObservedSeconds"] = onlyDiagnostic.elapsed()
        report["localPatternLifecycleValidated"] = maximumDiagnosticSeconds != nil
        if let maximumDiagnosticSeconds { report["maximumDiagnosticObservedSeconds"] = maximumDiagnosticSeconds }
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
