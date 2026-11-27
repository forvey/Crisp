import Foundation
import Network

protocol CrispAudioBackend: AnyObject, Sendable {
    var onFailure: @Sendable (String) -> Void { get set }
    var onMicrophoneUse: @Sendable (CrispAudioWire.MicrophoneUse) -> Void { get set }
    func halHealth() -> CrispHALDriverStatus
    func validate() throws
    func start() throws
    func stop()
    func shutdown()
    func setMicrophone(_ enabled: Bool) throws
    func flushStaleMicrophone() throws
    func microphonePCM(_ bytes: Data)
    func downlinkPCM() -> Data
    func downlinkPackets() -> [Data]
    func setDiagnostics(_ recorder: LagRecorder?)
    func startProbeInput() throws
    func prepareProbeInput(_ completion: @escaping @Sendable (String?) -> Void)
    func stopProbeInput() -> AudioProbeResult?
}

extension CrispAudioBackend {
    func halHealth() -> CrispHALDriverStatus { .unknown }
    func shutdown() { stop() }
    func flushStaleMicrophone() throws {
        try setMicrophone(false)
        try setMicrophone(true)
    }
    func downlinkPackets() -> [Data] { [downlinkPCM()] }
    func setDiagnostics(_ recorder: LagRecorder?) {}
    func startProbeInput() throws {
        throw CrispAudioWire.Failure(reason: String(localized: "This audio backend does not support input self-test"))
    }
    func stopProbeInput() -> AudioProbeResult? { nil }
    func prepareProbeInput(_ completion: @escaping @Sendable (String?) -> Void) { completion(nil) }
}

struct CrispAudioServerState: Sendable {
    var listening = false
    var connected = false
    var microphone = false
    var microphoneUse: CrispAudioWire.MicrophoneUse = .unavailable
    var halStatus: CrispHALDriverStatus = .unknown
    var peer = ""
    var error: String?
    var diagnosing = false
}

/// All connection/framing state belongs to queue. Neither audio real-time callback nor
/// MainActor ever waits for network I/O. A backend may be synthetic for loopback tests.
final class CrispAudioServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.crisp.remote-audio.network", qos: .userInitiated)
    private let backend: any CrispAudioBackend
    private let sharedKeyProvider: @Sendable () -> String?
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
    private var microphoneUse = CrispAudioWire.MicrophoneUse.unavailable
    private var probeMode: UInt8 = 0
    private var probeSequence = 0
    private var probeDeadline = 0.0
    private var probeID: UUID?
    private var probeStats: AudioProbeStats?
    private var probeSentAt: TimeInterval?
    private var probeReceivedAt: TimeInterval?
    private struct Handshake {
        let connection: NWConnection
        let timer: DispatchSourceTimer
        var clientNonce: String?
        var serverNonce: String?
        var authenticated: Bool = false
    }
    private var pending: [UUID: Handshake] = [:]
    private var diagnostic: CrispLagSession?
    private var diagnosticID = UUID()
    private var recorder: LagRecorder?

    init(backend: any CrispAudioBackend,
         sharedKey: @escaping @Sendable () -> String? = { nil },
         changed: @escaping @Sendable (CrispAudioServerState) -> Void) {
        self.backend = backend
        self.sharedKeyProvider = sharedKey
        self.changed = changed
    }

    func start(port: UInt16 = CrispAudioWire.port, loopbackOnly: Bool = false) {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                try backend.validate()
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    throw CrispAudioWire.Failure(reason: String(localized: "Invalid TCP port: \(port)"))
                }
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                tcp.enableKeepalive = true
                tcp.keepaliveIdle = 5
                tcp.keepaliveInterval = 2
                tcp.keepaliveCount = 2
                let parameters = NWParameters(tls: nil, tcp: tcp)
                if loopbackOnly {
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
                }
                let newListener = try loopbackOnly ? NWListener(using: parameters) :
                    NWListener(using: parameters, on: nwPort)
                listener = newListener
                newListener.newConnectionHandler = { [weak self, weak newListener] connection in
                    guard let self, self.listener === newListener else { connection.cancel(); return }
                    self.accept(connection)
                }
                newListener.stateUpdateHandler = { [weak self, weak newListener] phase in
                    guard let self, self.listener === newListener else { return }
                    switch phase {
                    case .ready:
                        self.state.halStatus = self.backend.halHealth()
                        self.state.listening = true
                        self.publish()
                    case let .failed(error):
                        let desc = error.localizedDescription
                        self.stopOnQueue(error: String(localized: "TCP listener: \(desc)"))
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

    private func normalizedSharedKey() -> String? {
        guard let key = sharedKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        return key
    }

    private static func peerLabel(_ connection: NWConnection) -> String {
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        if case let .hostPort(host, _) = endpoint {
            switch host {
            case .ipv4(let value):
                return value.debugDescription
            case .ipv6(let value):
                return value.debugDescription.components(separatedBy: "%")[0]
            case .name(let name, _):
                return name
            @unknown default:
                break
            }
        }
        return String(describing: endpoint)
    }

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
        // Read preface frames before assigning the audio slot. A diagnostic-only
        // client must never reset microphones or start capture.
        guard listener != nil, pending.count < 4 else { connection.cancel(); return }
        let token = UUID()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 8)
        timer.setEventHandler { [weak self] in self?.removePending(token)?.cancel() }
        pending[token] = Handshake(connection: connection, timer: timer)
        timer.resume()
        connection.start(queue: queue)
        receivePrefaceFrame(token: token, connection: connection)
    }

    private func receivePrefaceFrame(token: UUID, connection: NWConnection) {
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
                guard let self, self.pending[token]?.connection === connection else { return }
                guard let payload, payload.count == length, !eof, error == nil else {
                    self.removePending(token)?.cancel(); return
                }
                self.handlePrefacePayload(token: token, connection: connection, header: data, payload: payload)
            }
        }
    }

    private func handlePrefacePayload(token: UUID, connection: NWConnection, header: Data, payload: Data) {
        guard var handshake = pending[token], handshake.connection === connection else { return }
        let requiredKey = normalizedSharedKey()

        if let clientNonce = handshake.clientNonce, let serverNonce = handshake.serverNonce, !handshake.authenticated {
            guard let key = requiredKey,
                  CrispAudioAuth.verifyProof(payload, sharedKey: key, clientNonce: clientNonce, serverNonce: serverNonce) else {
                removePending(token)?.cancel()
                let peer = Self.peerLabel(connection)
                state.error = String(localized: "Rejected connection: invalid LAN key from \(peer)")
                publish()
                return
            }
            handshake.authenticated = true
            pending[token] = handshake
            connection.send(content: CrispAudioAuth.makeOKFrame(), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.removePending(token)?.cancel()
                } else {
                    self.receivePrefaceFrame(token: token, connection: connection)
                }
            })
            return
        }

        if !handshake.authenticated, let clientNonce = CrispAudioAuth.parseInit(payload) {
            guard requiredKey != nil else {
                removePending(token)?.cancel()
                return
            }
            let serverNonce = CrispAudioAuth.randomNonceHex()
            handshake.clientNonce = clientNonce
            handshake.serverNonce = serverNonce
            pending[token] = handshake
            connection.send(content: CrispAudioAuth.makeChallengeFrame(serverNonce: serverNonce),
                            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.removePending(token)?.cancel()
                } else {
                    self.receivePrefaceFrame(token: token, connection: connection)
                }
            })
            return
        }

        if requiredKey != nil && !handshake.authenticated {
            removePending(token)?.cancel()
            let peer = Self.peerLabel(connection)
            state.error = String(localized: "Rejected unauthenticated connection from \(peer)")
            publish()
            return
        }

        guard removePending(token) === connection else { return }
        if payload == LagWire.hello {
            adoptDiagnostics(connection)
        } else if payload == Data([1]) + CrispAudioWire.hello {
            adoptAudio(connection, hello: header + payload)
        } else {
            connection.cancel()
        }
    }

    private func adoptDiagnostics(_ connection: NWConnection) {
        guard diagnostic == nil else { connection.cancel(); return }
        let newDiagnosticID = UUID()
        diagnosticID = newDiagnosticID
        let peer = CrispLagSession(connection: connection, attach: { [weak self] recorder in
            guard let self else { return }
            self.queue.async {
                guard self.diagnosticID == newDiagnosticID else { return }
                self.state.diagnosing = recorder != nil
                self.recorder = recorder?.scope.audio == true ? recorder : nil
                self.backend.setDiagnostics(self.recorder)
                self.publish()
            }
        }, finished: { [weak self] in
            guard let self else { return }
            self.queue.async {
                if self.diagnosticID == newDiagnosticID { self.diagnostic = nil }
            }
        })
        diagnostic = peer
        peer.start()
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
        state.halStatus = backend.halHealth()
        state.peer = Self.peerLabel(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] phase in
            guard let self, let connection, self.client === connection else { return }
            switch phase {
            case let .failed(error):
                let desc = error.localizedDescription
                self.closeClient(error: String(localized: "TCP: \(desc)"))
            case .cancelled:
                self.closeClient(error: nil)
            case .waiting:
                self.closeClient(error: String(localized: "Network unavailable; reconnect manually"))
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
            if case .pcm = message, probeMode == 2, var stats = probeStats {
                let now = ProcessInfo.processInfo.systemUptime
                stats.receivedPackets = (stats.receivedPackets ?? 0) + 1
                if let last = probeReceivedAt {
                    stats.maxReceiveGapMS = max(stats.maxReceiveGapMS ?? 0, Int((now - last) * 1000))
                }
                probeStats = stats
                probeReceivedAt = now
            }
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
                    backend.onMicrophoneUse = { [weak self, weak connection] use in
                        guard let self, let connection else { return }
                        self.queue.async {
                            guard self.client === connection else { return }
                            self.microphoneUse = use
                            self.state.microphoneUse = use
                            self.state.halStatus = self.backend.halHealth()
                            do {
                                try self.applyMicrophone()
                                self.send(.microphoneUse(use), connection)
                                self.publish()
                            } catch { self.closeClient(error: error.localizedDescription) }
                        }
                    }
                    try backend.start(); send(.hello, connection); state.connected = true
                    state.halStatus = backend.halHealth()
                case .microphone:
                    try applyMicrophone()
                case let .probe(mode):
                    try controlProbe(mode, connection)
                case let .microphonePCM(pcm):
                    guard state.microphone else { continue } // In-flight packets after last reader closes are discarded.
                    recorder?.interval("mic.receive_interval_ms")
                    recorder?.count("mic.packets")
                    backend.microphonePCM(pcm); starved = false
                }
            }
        }
    }

    private func applyMicrophone() throws {
        let active = session.microphoneEnabled && microphoneUse == .inUse
        guard active != state.microphone else { return }
        try backend.setMicrophone(active)
        state.microphone = active; starved = false
        if active { session.microphoneUseStarted(now: ProcessInfo.processInfo.systemUptime) }
        publish()
    }

    private func controlProbe(_ mode: UInt8, _ connection: NWConnection) throws {
        if mode == 0 {
            let finished = probeMode
            guard finished != 0 else {
                throw CrispAudioWire.Failure(reason: String(localized: "No audio diagnostics currently in progress"))
            }
            probeMode = 0
            probeID = nil
            var result = finished == 2 ? backend.stopProbeInput() : nil
            if finished == 2 {
                var stats = result?.stats ?? AudioProbeStats()
                stats.receivedPackets = probeStats?.receivedPackets
                stats.maxReceiveGapMS = probeStats?.maxReceiveGapMS
                result?.stats = stats
            }
            _ = try session.receive(.microphone(false), now: ProcessInfo.processInfo.systemUptime)
            try applyMicrophone()
            sendProbe(AudioProbeReply(mode: finished, state: "result", result: result,
                                     stats: finished == 1 ? probeStats : nil), connection)
            probeStats = nil; probeSentAt = nil; probeReceivedAt = nil
            return
        }
        guard probeMode == 0, !session.microphoneEnabled else {
            throw CrispAudioWire.Failure(reason: String(localized: "Audio diagnostics cannot override an active microphone"))
        }
        if mode == 2 {
            guard microphoneUse == .idle else {
                let message = microphoneUse == .unavailable
                    ? String(localized: "Remote Microphone is unavailable; install Crisp HAL 1.0.4+ and reconnect.")
                    : String(localized: "Another app is currently using Remote Microphone; stop input use before running diagnostics.")
                sendProbe(AudioProbeReply(mode: mode, state: "error", error: message), connection)
                return
            }
            probeMode = mode; probeDeadline = ProcessInfo.processInfo.systemUptime + 18
            let id = UUID(); probeID = id
            backend.prepareProbeInput { [weak self, weak connection] error in
                guard let self, let connection else { return }
                self.queue.async {
                    // Closing the test while a system permission sheet is open
                    // must not let its late answer start an input device.
                    guard self.client === connection, self.probeID == id, self.probeMode == mode else { return }
                    if let error {
                        self.probeMode = 0
                        self.sendProbe(AudioProbeReply(mode: mode, state: "error", error: error), connection)
                    } else { self.startProbe(mode, connection) }
                }
            }
            return
        }
        startProbe(mode, connection)
    }

    private func startProbe(_ mode: UInt8, _ connection: NWConnection) {
        do {
            if mode == 2 {
                guard microphoneUse == .idle else {
                    throw CrispAudioWire.Failure(
                        reason: String(localized: "Remote Microphone is unavailable or currently in use by an app")
                    )
                }
                try backend.startProbeInput()
            }
            probeMode = mode; probeSequence = 0
            probeStats = mode == 1 ? AudioProbeStats(sentPackets: 0, maxSendGapMS: 0)
                : AudioProbeStats(receivedPackets: 0, maxReceiveGapMS: 0)
            probeSentAt = nil; probeReceivedAt = nil
            probeDeadline = ProcessInfo.processInfo.systemUptime + 18
            sendProbe(AudioProbeReply(mode: mode, state: "ready"), connection)
        } catch {
            _ = backend.stopProbeInput()
            probeMode = 0; probeStats = nil
            sendProbe(AudioProbeReply(mode: mode, state: "error", error: error.localizedDescription), connection)
        }
    }

    private func sendProbe(_ reply: AudioProbeReply, _ connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(reply), data.count <= 1023 else {
            closeClient(error: String(localized: "Audio diagnostics result exceeded protocol limit")); return
        }
        send(.probeReply(data), connection)
    }

    private func tick() {
        guard let client else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard session.handshaken else {
            if now - acceptedAt >= 8 { closeClient(error: String(localized: "Client hello timed out")) }
            return
        }
        recorder?.interval("audio.send_tick_ms")
        if probeMode != 0, now >= probeDeadline {
            closeClient(error: String(localized: "Audio diagnostics timed out; input device released")); return
        }
        if state.microphone, session.microphoneExpired(now: now), !starved {
            recorder?.count("mic.starvation_reset")
            do {
                try backend.flushStaleMicrophone()
            } catch { closeClient(error: error.localizedDescription); return }
            starved = true
        }
        recorder?.value("audio.pending_packets", Double(sends))
        guard sends < 5 else {
            recorder?.count("audio.send_backlog_disconnect")
            closeClient(error: String(localized: "Audio send backlog exceeded 100 ms; reconnect manually")); return
        }
        if probeMode == 1 {
            let pcm = AudioProbeSignal.pcm(probeSequence)
            probeSequence += 1
            if var stats = probeStats {
                stats.sentPackets = (stats.sentPackets ?? 0) + 1
                if let last = probeSentAt {
                    stats.maxSendGapMS = max(stats.maxSendGapMS ?? 0, Int((now - last) * 1000))
                }
                probeStats = stats
            }
            probeSentAt = now
            guard pcm.count == CrispAudioWire.pcmBytes else {
                closeClient(error: String(localized: "Invalid capture packet size")); return
            }
            send(.pcm(pcm), client)
            return
        }
        for pcm in backend.downlinkPackets() {
            guard sends < 5 else {
                recorder?.count("audio.send_backlog_disconnect")
                closeClient(error: String(localized: "Audio send backlog exceeded 100 ms; reconnect manually")); return
            }
            guard pcm.count == CrispAudioWire.pcmBytes else {
                closeClient(error: String(localized: "Invalid capture packet size")); return
            }
            send(.pcm(pcm), client)
        }
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
        microphoneUse = .unavailable
        state.microphoneUse = .unavailable
        probeMode = 0
        probeID = nil; probeStats = nil; probeSentAt = nil; probeReceivedAt = nil
        state.peer = ""
        state.error = error
        publish()
    }
}
