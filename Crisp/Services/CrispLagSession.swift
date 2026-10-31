import Foundation
import Network

/// Queue-confined diagnostic peer. It never starts audio. Every accepted session
/// has its own deadline, including when the controller disappears without stop.
final class CrispLagSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.crisp.diagnostics", qos: .utility)
    private let attach: (LagRecorder?) -> Void
    private let finished: () -> Void
    private var parser = LagWire.Parser()
    private var recorder: LagRecorder?
    private var sampler: LagResourceSampler?
    private var screenCollector: LagScreenCollector?
    private var networkCollector: LagNetworkCollector?
    private var hostSampler: LagHostSampler?
    private var collectCause = false
    private var causeBegan: Double?
    private var causeDone = false
    private var lastSample: Double?
    private var timer: DispatchSourceTimer?
    private var deadlineTimer: DispatchSourceTimer?
    private var deadline = 0.0
    private var id = ""
    private var closed = false
    private var pending = 0
    private var requests = 0
    private var lastPattern = 0.0
    private var motionToken: Int?
    private var qualityToken: Int?

    init(connection: NWConnection,
         attach: @escaping (LagRecorder?) -> Void, finished: @escaping () -> Void) {
        self.connection = connection
        self.attach = attach; self.finished = finished
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard !closed else { return }
        connection.stateUpdateHandler = { [weak self] phase in
            switch phase {
            case .failed, .cancelled, .waiting: self?.close()
            default: break
            }
        }
        deadline = LagRecorder.now() + 5
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer; timer.resume()
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + 5)
        timeout.setEventHandler { [weak self] in self?.closeOnQueue() }
        deadlineTimer = timeout; timeout.resume()
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, eof, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                do {
                    if let data {
                        for message in try self.parser.append(data) {
                            guard !self.closed else { break }
                            self.requests += 1
                            guard self.requests <= 30 else { throw LagError.invalidMessage }
                            try self.handle(message)
                        }
                    }
                    if eof || error != nil { self.closeOnQueue() } else if !self.closed { self.receive() }
                } catch { self.closeOnQueue() }
            }
        }
    }

    private func handle(_ message: LagMessage) throws {
        let now = LagRecorder.now()
        if recorder == nil {
            guard message.kind == "start", UUID(uuidString: message.id) != nil,
                  let scope = message.scope, let duration = message.duration,
                  duration.isFinite, duration >= 1, duration <= 60 else { throw LagError.invalidMessage }
            id = message.id; deadline = now + duration
            deadlineTimer?.schedule(deadline: .now() + duration)
            let recorder = LagRecorder(scope: scope)
            self.recorder = recorder; sampler = LagResourceSampler(); attach(recorder)
            send(LagMessage(kind: "started", id: id, time: now,
                            note: "resources,audio,pattern-v1,motion-v1,motion-v2,quality-v2,screen-evidence-v1,motion-cause-v1; no desktop encoder/decoder counters"))
            return
        }
        guard message.id == id, now < deadline else { closeOnQueue(); return }
        switch message.kind {
        case "ping":
            guard let time = message.time, time.isFinite else { throw LagError.invalidMessage }
            send(LagMessage(kind: "pong", id: id, time: time, received: now,
                            sent: LagRecorder.now(), sequence: message.sequence))
        case "pattern":
            guard recorder?.scope.screen == true, let sequence = message.sequence,
                  (1...255).contains(sequence), now - lastPattern >= 0.08 else { throw LagError.invalidMessage }
            lastPattern = now
            let sessionID = id
            DispatchQueue.main.async { CrispLagPattern.shared.show(id: sessionID, sequence: sequence) }
        case "patternStop":
            let sessionID = id
            DispatchQueue.main.async { CrispLagPattern.shared.close(id: sessionID) }
        case "motionStart", "motionPrepare":
            guard recorder?.scope.screen == true, causeBegan == nil, motionToken == nil, qualityToken == nil,
                  let token = message.sequence, (1...4095).contains(token),
                  deadline - now >= 20 else { throw LagError.invalidMessage }
            motionToken = token
            collectCause = message.collectCause == true
            if collectCause, message.kind == "motionStart" { startCause() }
            if !collectCause, message.collectScreenTrace == true {
                screenCollector = LagScreenCollector(queue: queue,
                    peer: LagScreenParser.peer(connection.currentPath?.remoteEndpoint ?? connection.endpoint), server: true)
            }
            let sessionID = id
            // All start/stop/close operations are submitted from this serial
            // queue to the main queue in order. A late start cannot overtake close.
            DispatchQueue.main.async { [weak self] in
                CrispLagPattern.shared.startMotion(id: sessionID, token: token, waitingForReader: message.kind == "motionPrepare") { result in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.closed, self.motionToken == token else { return }
                        self.motionToken = nil
                        let trace = self.screenCollector?.stop(), network = self.networkCollector?.stop()
                        self.screenCollector = nil; self.networkCollector = nil; self.hostSampler = nil
                        if self.collectCause { self.causeDone = true; self.sampler = nil }
                        self.send(LagMessage(kind: "motionResult", id: sessionID, motion: result, screenTrace: trace, network: network))
                    }
                }
            }
        case "motionRun":
            guard let token = message.sequence, motionToken == token, deadline - now >= 16 else { throw LagError.invalidMessage }
            if collectCause, causeBegan == nil { startCause() }
            let sessionID = id
            DispatchQueue.main.async { CrispLagPattern.shared.runMotion(id: sessionID, token: token) }
        case "motionStop":
            guard let token = message.sequence, motionToken == token else { return }
            let sessionID = id
            DispatchQueue.main.async { CrispLagPattern.shared.stopMotion(id: sessionID, token: token) }
        case "qualityStart":
            guard recorder?.scope.screen == true, causeBegan == nil, motionToken == nil, qualityToken == nil,
                  let token = message.sequence, (1...4095).contains(token), deadline - now >= 16 else { throw LagError.invalidMessage }
            qualityToken = token
            let sessionID = id
            DispatchQueue.main.async { [weak self] in
                let reference = try? CrispLagPattern.shared.startQuality(id: sessionID, token: token)
                guard let self else { return }
                self.queue.async {
                    guard !self.closed, self.qualityToken == token else { return }
                    self.send(LagMessage(kind: "qualityReady", id: sessionID, sequence: token,
                        note: reference == nil ? "mini 无法生成或显示清晰度参考图。" : nil, quality: reference))
                }
            }
        case "qualityStop":
            guard let token = qualityToken, message.sequence == token else { return }
            qualityToken = nil
            let sessionID = id
            DispatchQueue.main.async { CrispLagPattern.shared.close(id: sessionID) }
        case "stop": closeOnQueue()
        default: throw LagError.invalidMessage
        }
    }

    private func sample() {
        guard !closed else { return }
        requests = 0
        guard LagRecorder.now() < deadline else { closeOnQueue(); return }
        guard !causeDone else { return }
        if var snapshot = recorder?.snapshot() {
            let began = LagRecorder.now()
            snapshot.resources = sampler?.sample(path: connection.currentPath)
            snapshot.host = hostSampler?.sample(interface: networkCollector?.interface,
                timerLateMS: lastSample.map { max(0, began - $0 - 1) * 1000 } ?? 0)
            lastSample = began
            recorder?.duration("diagnostic.sample_ms", since: began)
            let recorder = self.recorder
            DispatchQueue.main.async { recorder?.duration("diagnostic.main_queue_ms", since: began) }
            send(LagMessage(kind: "sample", id: id, snapshot: snapshot,
                screenTrace: causeBegan == nil ? nil : screenCollector?.snapshot(), network: networkCollector?.snapshot()))
        }
    }
    private func startCause() {
        causeBegan = LagRecorder.now(); hostSampler = LagHostSampler()
        let peer = LagScreenParser.peer(connection.currentPath?.remoteEndpoint ?? connection.endpoint)
        networkCollector = LagNetworkCollector(queue: queue, peer: peer)
        screenCollector = LagScreenCollector(queue: queue, peer: peer, server: true, allTransports: true)
    }

    private func send(_ message: LagMessage) {
        guard !closed, pending < 3, let bytes = try? LagWire.encode(message) else { closeOnQueue(); return }
        pending += 1
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.pending -= 1
                if error != nil { self.closeOnQueue() }
            }
        })
    }

    func close() {
        queue.async { self.closeOnQueue() }
    }
    private func closeOnQueue() {
        guard !closed else { return }
        closed = true; timer?.cancel(); timer = nil
        screenCollector?.stop(); screenCollector = nil
        networkCollector?.stop(); networkCollector = nil; hostSampler = nil
        deadlineTimer?.cancel(); deadlineTimer = nil
        recorder?.stop(); attach(nil); recorder = nil; sampler = nil
        let sessionID = id
        DispatchQueue.main.async { CrispLagPattern.shared.close(id: sessionID) }
        connection.stateUpdateHandler = nil; connection.cancel(); finished()
    }
}
