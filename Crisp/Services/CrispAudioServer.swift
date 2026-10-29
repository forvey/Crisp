import Foundation
import Network

protocol CrispAudioBackend: AnyObject, Sendable {
    var onFailure: @Sendable (String) -> Void { get set }
    func validate() throws
    func start() throws
    func stop()
    func shutdown()
    func setMicrophone(_ enabled: Bool) throws
    func microphonePCM(_ bytes: Data)
    func downlinkPCM() -> Data
    func setDiagnostics(_ recorder: LagRecorder?)
}

extension CrispAudioBackend {
    func shutdown() { stop() }
    func setDiagnostics(_ recorder: LagRecorder?) {}
}

struct CrispAudioServerState: Sendable {
    var listening = false
    var connected = false
    var microphone = false
    var peer = ""
    var error: String?
    var diagnosing = false
}

/// All connection/framing state belongs to queue. Neither audio real-time callback nor
/// MainActor ever waits for network I/O. A backend may be synthetic for loopback tests.
final class CrispAudioServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.crisp.remote-audio.network", qos: .userInitiated)
    private let backend: any CrispAudioBackend
    private let changed: @Sendable (CrispAudioServerState) -> Void
    private var listener: NWListener?
    private var client: NWConnection?
    private var decoder = CrispAudioWire.Decoder()
    private var session = CrispAudioSession()
    private var state = CrispAudioServerState()
    private var clock: DispatchSourceTimer?
    private var acceptedAt = 0.0
    private var sends = 0
    private var starved = false
    private struct Handshake { let connection: NWConnection; let timer: DispatchSourceTimer }
    private var pending: [UUID: Handshake] = [:]
    private var diagnostic: CrispLagSession?
    private var diagnosticID = UUID()
    private var recorder: LagRecorder?

    init(backend: any CrispAudioBackend, changed: @escaping @Sendable (CrispAudioServerState) -> Void) {
        self.backend = backend
        self.changed = changed
    }

    func start(port: UInt16 = CrispAudioWire.port, loopbackOnly: Bool = false) {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                try backend.validate()
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                tcp.enableKeepalive = true
                tcp.keepaliveIdle = 5
                tcp.keepaliveInterval = 2
                tcp.keepaliveCount = 2
                let parameters = NWParameters(tls: nil, tcp: tcp)
                if loopbackOnly {
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                }
                let newListener = try loopbackOnly ? NWListener(using: parameters) :
                    NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
                listener = newListener
                newListener.newConnectionHandler = { [weak self, weak newListener] connection in
                    guard let self, self.listener === newListener else { connection.cancel(); return }
                    self.accept(connection)
                }
                newListener.stateUpdateHandler = { [weak self, weak newListener] phase in
                    guard let self, self.listener === newListener else { return }
                    switch phase {
                    case .ready: self.state.listening = true; self.publish()
                    case let .failed(error): self.stopOnQueue(error: "TCP listener: \(error.localizedDescription)")
                    default: break
                    }
                }
                newListener.start(queue: queue)
            } catch {
                stopOnQueue(error: error.localizedDescription)
            }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue(error: nil) } }
    func shutdown() { queue.sync { stopOnQueue(error: nil); backend.shutdown() } }

    private func publish() { changed(state) }

    private func stopOnQueue(error: String?) {
        diagnostic?.close(); diagnostic = nil
        diagnosticID = UUID(); recorder?.stop(); recorder = nil
        backend.setDiagnostics(nil); state.diagnosing = false
        let handshakes = pending.values; pending.removeAll()
        for handshake in handshakes { handshake.timer.cancel(); handshake.connection.cancel() }
        closeClient(error: error)
        listener?.cancel()
        listener = nil
        backend.stop()
        state.listening = false
        state.error = error
        publish()
    }

    private func accept(_ connection: NWConnection) {
        // Read exactly one small preface before assigning the audio slot. A
        // diagnostic-only client must never reset microphones or start capture.
        guard listener != nil, pending.count < 4 else { connection.cancel(); return }
        let token = UUID()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 8)
        timer.setEventHandler { [weak self] in self?.removePending(token)?.cancel() }
        pending[token] = Handshake(connection: connection, timer: timer)
        timer.resume()
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, eof, error in
            guard let self, self.pending[token]?.connection === connection else { return }
            guard let data, data.count == 4, !eof, error == nil else {
                self.removePending(token)?.cancel(); return
            }
            let length = data.reduce(0) { ($0 << 8) | Int($1) }
            guard (1...128).contains(length) else {
                self.removePending(token)?.cancel(); return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] payload, _, eof, error in
                guard let self, self.removePending(token) === connection else { return }
                guard let payload, payload.count == length, !eof, error == nil else { connection.cancel(); return }
                if payload == LagWire.hello {
                    guard self.diagnostic == nil else { connection.cancel(); return }
                    let diagnosticID = UUID()
                    self.diagnosticID = diagnosticID
                    let peer = CrispLagSession(connection: connection, attach: { [weak self] recorder in
                        guard let self else { return }
                        self.queue.async {
                            guard self.diagnosticID == diagnosticID else { return }
                            self.state.diagnosing = recorder != nil
                            self.recorder = recorder?.scope.audio == true ? recorder : nil
                            self.backend.setDiagnostics(self.recorder)
                            self.publish()
                        }
                    }, finished: { [weak self] in
                        guard let self else { return }
                        self.queue.async {
                            if self.diagnosticID == diagnosticID { self.diagnostic = nil }
                        }
                    })
                    self.diagnostic = peer; peer.start()
                } else if payload == Data([1]) + CrispAudioWire.hello {
                    self.adoptAudio(connection, hello: data + payload)
                } else { connection.cancel() }
            }
        }
    }

    private func removePending(_ token: UUID) -> NWConnection? {
        guard let handshake = pending.removeValue(forKey: token) else { return nil }
        handshake.timer.cancel()
        return handshake.connection
    }

    private func adoptAudio(_ connection: NWConnection, hello: Data) {
        guard listener != nil, client == nil else {
            connection.cancel()
            return // A second client can never reset or take over the first client's microphone.
        }
        client = connection
        decoder = CrispAudioWire.Decoder()
        session = CrispAudioSession()
        try? backend.setMicrophone(false)
        acceptedAt = ProcessInfo.processInfo.systemUptime
        sends = 0
        starved = false
        state.error = nil
        state.peer = String(describing: connection.endpoint)
        connection.stateUpdateHandler = { [weak self, weak connection] phase in
            guard let self, let connection, self.client === connection else { return }
            switch phase {
            case let .failed(error): self.closeClient(error: "TCP: \(error.localizedDescription)")
            case .cancelled: self.closeClient(error: nil)
            case .waiting: self.closeClient(error: "Network unavailable; reconnect manually")
            default: break
            }
        }
        do { try process(hello, connection); receive(connection) } catch { closeClient(error: error.localizedDescription); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        clock = timer
        timer.resume()
        publish()
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] bytes, _, eof, error in
            guard let self, let connection, self.client === connection else { return }
            do {
                if let bytes {
                    try self.process(bytes, connection)
                    self.publish()
                }
                if let error { self.closeClient(error: error.localizedDescription) } else if eof {
                    self.closeClient(error: nil)
                } else { self.receive(connection) }
            } catch {
                self.closeClient(error: error.localizedDescription)
            }
        }
    }

    private func process(_ bytes: Data, _ connection: NWConnection) throws {
        for message in try decoder.receive(bytes) {
            if let action = try session.receive(message, now: ProcessInfo.processInfo.systemUptime) {
                switch action {
                case .replyHello:
                    backend.onFailure = { [weak self, weak connection] reason in
                        guard let self, let connection else { return }
                        self.queue.async {
                            guard self.client === connection else { return }
                            self.closeClient(error: reason)
                        }
                    }
                    try backend.start(); send(.hello, connection); state.connected = true
                case let .microphone(enabled):
                    try backend.setMicrophone(enabled); state.microphone = enabled; starved = false
                case let .microphonePCM(pcm):
                    recorder?.interval("mic.receive_interval_ms")
                    recorder?.count("mic.packets")
                    backend.microphonePCM(pcm); starved = false
                }
            }
        }
    }

    private func tick() {
        guard let client else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard session.handshaken else {
            if now - acceptedAt >= 8 { closeClient(error: "Client hello timed out") }
            return
        }
        recorder?.interval("audio.send_tick_ms")
        if session.microphoneExpired(now: now), !starved {
            recorder?.count("mic.starvation_reset")
            do {
                try backend.setMicrophone(false)
                try backend.setMicrophone(true) // Flush the epoch/queue; don't repeat old audio during an uplink gap.
            } catch { closeClient(error: error.localizedDescription); return }
            starved = true
        }
        recorder?.value("audio.pending_packets", Double(sends))
        guard sends < 5 else {
            recorder?.count("audio.send_backlog_disconnect")
            closeClient(error: "Audio send backlog exceeded 100 ms; reconnect manually"); return
        }
        let pcm = backend.downlinkPCM()
        guard pcm.count == CrispAudioWire.pcmBytes else { closeClient(error: "Invalid capture packet size"); return }
        send(.pcm(pcm), client) // Includes 960 zero bytes every 20 ms when no application is playing.
    }

    private func send(_ message: CrispAudioWire.Message, _ connection: NWConnection) {
        sends += 1
        let recorder = recorder
        let began = recorder.map { _ in LagRecorder.now() }
        connection.send(content: CrispAudioWire.encode(message), completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.client === connection else { return }
            self.sends -= 1
            if let began { recorder?.duration("audio.send_completion_ms", since: began) }
            if let error { self.closeClient(error: error.localizedDescription) }
        })
    }

    private func closeClient(error: String?) {
        let old = client
        client = nil
        clock?.cancel()
        clock = nil
        old?.cancel()
        try? backend.setMicrophone(false)
        backend.stop()
        session.disconnect()
        state.connected = false
        state.microphone = false
        state.peer = ""
        state.error = error
        publish()
    }
}
