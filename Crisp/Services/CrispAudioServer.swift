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
}

extension CrispAudioBackend {
    func shutdown() { stop() }
}

struct CrispAudioServerState: Sendable {
    var listening = false
    var connected = false
    var microphone = false
    var peer = ""
    var error: String?
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
        closeClient(error: error)
        listener?.cancel()
        listener = nil
        backend.stop()
        state.listening = false
        state.error = error
        publish()
    }

    private func accept(_ connection: NWConnection) {
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
            case .ready: self.receive(connection)
            case let .failed(error): self.closeClient(error: "TCP: \(error.localizedDescription)")
            case .cancelled: self.closeClient(error: nil)
            case .waiting: self.closeClient(error: "Network unavailable; reconnect manually")
            default: break
            }
        }
        connection.start(queue: queue)
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
                    for message in try self.decoder.receive(bytes) {
                        if let action = try self.session.receive(message, now: ProcessInfo.processInfo.systemUptime) {
                            switch action {
                            case .replyHello:
                                self.backend.onFailure = { [weak self, weak connection] reason in
                                    guard let self, let connection else { return }
                                    self.queue.async {
                                        guard self.client === connection else { return }
                                        self.closeClient(error: reason)
                                    }
                                }
                                try self.backend.start()
                                self.send(.hello, connection)
                                self.state.connected = true
                            case let .microphone(enabled):
                                try self.backend.setMicrophone(enabled)
                                self.state.microphone = enabled
                                self.starved = false
                            case let .microphonePCM(pcm):
                                self.backend.microphonePCM(pcm)
                                self.starved = false
                            }
                        }
                    }
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

    private func tick() {
        guard let client else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard session.handshaken else {
            if now - acceptedAt >= 8 { closeClient(error: "Client hello timed out") }
            return
        }
        if session.microphoneExpired(now: now), !starved {
            do {
                try backend.setMicrophone(false)
                try backend.setMicrophone(true) // Flush the epoch/queue; don't repeat old audio during an uplink gap.
            } catch { closeClient(error: error.localizedDescription); return }
            starved = true
        }
        guard sends < 5 else { closeClient(error: "Audio send backlog exceeded 100 ms; reconnect manually"); return }
        let pcm = backend.downlinkPCM()
        guard pcm.count == CrispAudioWire.pcmBytes else { closeClient(error: "Invalid capture packet size"); return }
        send(.pcm(pcm), client) // Includes 960 zero bytes every 20 ms when no application is playing.
    }

    private func send(_ message: CrispAudioWire.Message, _ connection: NWConnection) {
        sends += 1
        connection.send(content: CrispAudioWire.encode(message), completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.client === connection else { return }
            self.sends -= 1
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
