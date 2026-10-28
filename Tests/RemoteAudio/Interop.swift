import Foundation
import Network
import Darwin

/// Synthetic backend: no HAL device, process tap, microphone or speaker is opened.
final class SyntheticAudio: CrispAudioBackend, @unchecked Sendable {
    struct Snapshot { let active: Bool; let microphone: Bool; let received: Int; let resets: Int }
    var onFailure: @Sendable (String) -> Void = { _ in }
    private let lock = NSLock()
    private var enabled = false
    private var active = false
    private var received = 0
    private var resetCount = 0
    private var microphoneAvailable = true
    let downlink = CrispAudioPCM.bytes((0..<480).map { sin(Float($0) * 0.05) * 0.1 })
    let uplink = Data(repeating: 17, count: 960)
    func validate() throws {}
    func start() throws { lock.lock(); active = true; enabled = false; lock.unlock() }
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
        return Snapshot(active: active, microphone: enabled, received: received, resets: resetCount)
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
        let client = AudioTransport() // Actual committed ScreenSharingEnhancer code, not a substitute.
        let welcomed = DispatchSemaphore(value: 0)
        let heard = Counter()
        client.onReady = { welcomed.signal() }
        client.onPCM = { bytes in precondition(bytes == backend.downlink); heard.increment() }
        client.connect(host: "127.0.0.1", port: testPort)
        precondition(welcomed.wait(timeout: .now() + 5) == .success)
        wait({ heard.count() >= 25 })
        precondition(!backend.snapshot().microphone, "Microphone must default off")
        client.sendMicrophone(true)
        for _ in 0..<3 { client.sendPCM(backend.uplink) }
        wait({ backend.snapshot().received == 3 })
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
        let received = Counter()
        reconnect.onReady = { reconnected.signal() }
        reconnect.onPCM = { bytes in precondition(bytes == backend.downlink); received.increment() }
        reconnect.connect(host: "127.0.0.1", port: testPort)
        precondition(reconnected.wait(timeout: .now() + 5) == .success)
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

        // Missing virtual input must not block listening. Injection must fail
        // explicitly when the user actually requests the microphone route.
        backend.setMicrophoneAvailable(false)
        let listenOnly = AudioTransport()
        let listenReady = DispatchSemaphore(value: 0)
        let micRejected = DispatchSemaphore(value: 0)
        let listenPackets = Counter()
        listenOnly.onReady = { listenReady.signal() }
        listenOnly.onPCM = { _ in listenPackets.increment() }
        listenOnly.onFailure = { _ in micRejected.signal() }
        listenOnly.connect(host: "127.0.0.1", port: testPort)
        precondition(listenReady.wait(timeout: .now() + 5) == .success)
        wait({ listenPackets.count() >= 10 })
        precondition(!backend.snapshot().microphone)
        let beforeMissingMic = backend.snapshot().received
        listenOnly.sendMicrophone(true)
        precondition(micRejected.wait(timeout: .now() + 5) == .success)
        wait({ !backend.snapshot().active })
        precondition(backend.snapshot().received == beforeMissingMic && !backend.snapshot().microphone)
        listenOnly.disconnect()
        backend.setMicrophoneAvailable(true)

        malformed(CrispAudioWire.encode(.pcm(CrispAudioWire.silence)))
        malformed(Data([0, 0, 4, 1]))
        malformed(Data([0, 0, 0, 5, 1]) + Data("bad!".utf8))
        malformed(CrispAudioWire.encode(.hello) + CrispAudioWire.encode(.hello))
        malformed(CrispAudioWire.encode(.hello) + CrispAudioWire.encode(.pcm(Data([0]))))
        idleHandshakeExpires()
        wait({ !backend.snapshot().active })
        server.shutdown()
        let report: [String: Any] = ["result": "passed", "realControllerSource": true, "hardwareOpened": false,
            "duplexSeconds": duration, "cpuPercentOneCore": (cpuAfter - cpuBefore) / duration * 100,
            "processPeakRSSBytes": after.ru_maxrss, "downlinkPacketsInFiveSeconds": received.count(),
            "uplinkPacketsTotal": backend.snapshot().received, "PCMBitrateEachDirection": 384000,
            "first50PacketSpanSeconds": heard.span(), "listenWithoutVirtualInput": true]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
