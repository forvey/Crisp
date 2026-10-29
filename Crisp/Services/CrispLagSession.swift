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
    private var timer: DispatchSourceTimer?
    private var deadlineTimer: DispatchSourceTimer?
    private var deadline = 0.0
    private var id = ""
    private var closed = false
    private var pending = 0
    private var requests = 0
    private var lastPattern = 0.0

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
                            note: "resources,audio,pattern-v1; no desktop encoder/decoder counters"))
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
        case "stop": closeOnQueue()
        default: throw LagError.invalidMessage
        }
    }

    private func sample() {
        guard !closed else { return }
        requests = 0
        guard LagRecorder.now() < deadline else { closeOnQueue(); return }
        if var snapshot = recorder?.snapshot() {
            let began = LagRecorder.now()
            snapshot.resources = sampler?.sample(path: connection.currentPath)
            recorder?.duration("diagnostic.sample_ms", since: began)
            send(LagMessage(kind: "sample", id: id, snapshot: snapshot))
        }
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
        deadlineTimer?.cancel(); deadlineTimer = nil
        recorder?.stop(); attach(nil); recorder = nil; sampler = nil
        let sessionID = id
        DispatchQueue.main.async { CrispLagPattern.shared.close(id: sessionID) }
        connection.stateUpdateHandler = nil; connection.cancel(); finished()
    }
}
