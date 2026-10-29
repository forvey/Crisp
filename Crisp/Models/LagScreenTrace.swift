import Foundation
import Network
import Darwin

/// Parser is shared by both hosts. Export only selected numeric counters and
/// event categories; never raw system logs, Wi-Fi names or unrelated sockets.
struct LagScreenParser {
    private var columns: [String] = []
    static let fields = "interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win"

    static func peer(_ endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let value): return value.debugDescription
        case .ipv6(let value): return value.debugDescription
        default: return nil // Do not guess a DNS name is the nettop address.
        }
    }
    static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .components(separatedBy: "%")[0].lowercased()
    }
    private static func endpoint(_ value: String) -> (String, Int)? {
        guard let split = value.lastIndex(of: ":"), let port = Int(value[value.index(after: split)...]) else { return nil }
        return (normalized(String(value[..<split])), port)
    }
    mutating func tcp(_ line: String, peer: String, server: Bool, stamp: Double) -> LagTCPReading? {
        let cells = line.components(separatedBy: ",")
        if cells.first == "", cells.contains("bytes_in") { columns = cells; return nil }
        guard let name = cells.first, name.hasPrefix("tcp"), cells.count == columns.count else { return nil }
        let pair = name.dropFirst(5).components(separatedBy: "<->")
        guard pair.count == 2, let local = Self.endpoint(pair[0]), let remote = Self.endpoint(pair[1]),
              remote.0 == Self.normalized(peer), (server ? local.1 : remote.1) == 5900 else { return nil }
        func field(_ key: String) -> String? { columns.firstIndex(of: key).map { cells[$0] } }
        guard field("state") == "Established",
              let incoming = field("bytes_in").flatMap(UInt64.init),
              let outgoing = field("bytes_out").flatMap(UInt64.init) else { return nil }
        let rtt = field("rtt_avg").flatMap { Double($0.replacingOccurrences(of: " ms", with: "")) }
        return LagTCPReading(stamp: stamp, connection: String(name.prefix(256)),
            interface: String((field("interface") ?? "").prefix(32)), bytesIn: incoming, bytesOut: outgoing,
            retransmitBytes: field("re-tx").flatMap(UInt64.init),
            duplicateBytes: field("rx_dupe").flatMap(UInt64.init), outOfOrderBytes: field("rx_ooo").flatMap(UInt64.init),
            rttMS: rtt.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            receiveBuffer: field("rcvsize").flatMap(UInt64.init), sendWindow: field("tx_win").flatMap(UInt64.init))
    }

    static func event(_ line: String, started: Double, wall: Date, now: Double, date: Date) -> LagSystemEvent? {
        guard let data = line.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = entry["eventMessage"] as? String else { return nil }
        let process = (entry["processImagePath"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let kind: String
        var duration: Double?
        if process == "airportd", message.contains("SCAN request received") {
            kind = "wifiScanStart"
        } else if process == "airportd", message.contains("Apple80211Scan:"), message.contains("total time [") {
            kind = "wifiScanEnd"
            if let start = message.range(of: "total time ["),
               let end = message[start.upperBound...].firstIndex(of: "]"),
               let seconds = Double(message[start.upperBound..<end]), seconds.isFinite, (0...60).contains(seconds) {
                duration = seconds * 1000
            }
        } else if process == "kernel", message.contains("AMD ERROR! Failed to allocate") {
            kind = "gpuAllocationFailure"
        } else { return nil }
        var stamp: Double?
        // A changed wall clock cannot silently move events onto a freeze.
        if abs(date.timeIntervalSince(wall) - (now - started)) <= 0.05,
           let timestamp = entry["timestamp"] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
            if let eventDate = formatter.date(from: timestamp) {
                let converted = started + eventDate.timeIntervalSince(wall)
                if converted >= started, converted <= now + 0.05 { stamp = converted }
            }
        }
        return LagSystemEvent(stamp: stamp, receivedAt: now, kind: kind, durationMS: duration)
    }
}

/// One bounded child process, no shell, no privilege escalation, no disk output.
/// All callbacks and cancellation share the owner's serial queue. A stalled
/// child is killed after a short grace period; it cannot survive a stopped test.
final class LagTraceCommand: @unchecked Sendable {
    private let process = Process()
    private let queue: DispatchQueue
    private var readers: [DispatchSourceRead] = []
    private var timeout: DispatchSourceTimer?
    private var buffers = [Data(), Data()]
    private var byteCount = 0
    private var stopped = false
    private let line: (String) -> Void
    private let exit: (String) -> Void
    var isRunning: Bool { process.isRunning }
    init(queue: DispatchQueue, line: @escaping (String) -> Void, exit: @escaping (String) -> Void) {
        self.queue = queue; self.line = line; self.exit = exit
    }
    func start(path: String, arguments: [String], seconds: Double = 25) {
        guard !stopped else { return }
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, right in right }
        process.standardInput = FileHandle.nullDevice
        let pipes = [Pipe(), Pipe()]
        process.standardOutput = pipes[0]; process.standardError = pipes[1]
        process.terminationHandler = { [weak self] child in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.exit(child.terminationStatus == 0 ? "exited" : "unavailable")
                // Data already in the pipe can still be read before its EOF.
            }
        }
        do { try process.run() }
        catch { exit("unavailable"); stop(); return }
        for (index, pipe) in pipes.enumerated() {
            pipe.fileHandleForWriting.closeFile()
            let handle = pipe.fileHandleForReading
            let reader = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
            reader.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count <= 0 { self.readers[index].cancel(); return }
                self.byteCount += count
                guard self.byteCount <= 262_144 else { self.exit("truncated"); self.stop(); return }
                self.buffers[index].append(contentsOf: bytes.prefix(count))
                while let end = self.buffers[index].firstIndex(of: 10) {
                    let value = String(data: self.buffers[index][..<end], encoding: .utf8)
                    self.buffers[index].removeSubrange(...end)
                    if index == 0, let value { self.line(value) }
                }
                if self.buffers[index].count > 16_384 { self.exit("truncated"); self.stop() }
            }
            reader.setCancelHandler { handle.closeFile() }
            readers.append(reader); reader.resume()
        }
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + seconds)
        timeout.setEventHandler { [weak self] in self?.exit("timeout"); self?.stop() }
        self.timeout = timeout; timeout.resume()
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; timeout?.cancel(); timeout = nil
        readers.forEach { $0.cancel() }; readers.removeAll(); buffers = [Data(), Data()]
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            let child = process
            queue.asyncAfter(deadline: .now() + 0.3) {
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
    deinit { stop() }
}

/// Only created by motionPrepare, not app startup, audio or clarity tests.
/// Uses read-only OS counters at 1 Hz. This is NOT per-packet capture and does
/// not manufacture a millisecond-level network verdict from a ping or average.
final class LagScreenCollector {
    private let queue: DispatchQueue
    private var parser = LagScreenParser()
    private var trace: LagScreenTrace
    private var net: LagTraceCommand?
    private var logs: LagTraceCommand?
    private var ended = false

    init(queue: DispatchQueue, peer: String?, pid: Int32? = nil, server: Bool = false) {
        self.queue = queue
        trace = LagScreenTrace(started: LagRecorder.now(), wallTime: Date())
        trace.notes = [
            "屏幕 TCP 按约 1 秒采样；非逐包时间，不能单独归因 100 ms 停顿。",
            "未申请管理员权限、未抓包；缺少逐包收发与重传时间、源端实际合成和苹果编码/解码耗时。",
            "仅识别已知 Wi-Fi 扫描和 AMD 分配失败日志；没记录不等于没有扫描或 GPU 异常。"
        ]
        guard let peer, !["127.0.0.1", "::1"].contains(LagScreenParser.normalized(peer)) else {
            trace.tcpState = "unavailable"; trace.logState = "notStarted"
            trace.notes.append("未取得实际对端 IP 或为回环测试，未启动系统采集。")
            return
        }
        var args = ["-L", "25", "-s", "1", "-n", "-x", "-m", "tcp", "-J", LagScreenParser.fields]
        if server { args += ["-p", "screensharingd", "-p", "ScreensharingAgent"] }
        else if let pid, pid > 0 { args += ["-p", String(pid)] }
        else {
            trace.tcpState = "unavailable"; trace.logState = "notStarted"
            trace.notes.append("未取得被测窗口进程，未扩大为全机连接采集。")
            return
        }
        trace.tcpState = "collecting"; trace.logState = "collecting"
        net = LagTraceCommand(queue: queue, line: { [weak self] line in
            guard let self, !self.ended,
                  let sample = self.parser.tcp(line, peer: peer, server: server, stamp: LagRecorder.now()) else { return }
            guard self.trace.tcp.count < 128 else {
                self.trace.truncated = true; self.trace.tcpState = "truncated"; self.net?.stop(); return
            }
            self.trace.tcp.append(sample)
        }, exit: { [weak self] state in
            guard let self, !self.ended else { return }
            self.trace.tcpState = state
            if state == "truncated" { self.trace.truncated = true }
        })
        net?.start(path: "/usr/bin/nettop", arguments: args)
        logs = LagTraceCommand(queue: queue, line: { [weak self] line in
            guard let self, !self.ended,
                  let event = LagScreenParser.event(line, started: self.trace.started, wall: self.trace.wallTime,
                                                   now: LagRecorder.now(), date: Date()) else { return }
            guard self.trace.events.count < 256 else {
                self.trace.truncated = true; self.trace.logState = "truncated"; self.logs?.stop(); return
            }
            self.trace.events.append(event)
        }, exit: { [weak self] state in
            guard let self, !self.ended else { return }
            self.trace.logState = state
            if state == "truncated" { self.trace.truncated = true }
        })
        let predicate = "(process == \"airportd\" AND (eventMessage CONTAINS \"SCAN request received\" OR (eventMessage CONTAINS \"Apple80211Scan:\" AND eventMessage CONTAINS \"total time [\"))) OR (process == \"kernel\" AND eventMessage CONTAINS \"AMD ERROR! Failed to allocate\")"
        logs?.start(path: "/usr/bin/log", arguments: ["stream", "--style", "ndjson", "--level", "info", "--timeout", "25", "--predicate", predicate])
    }
    func snapshot() -> LagScreenTrace { trace }
    @discardableResult func stop() -> LagScreenTrace {
        guard !ended else { return trace }
        ended = true; trace.ended = LagRecorder.now()
        net?.stop(); logs?.stop(); net = nil; logs = nil
        if trace.tcpState == "collecting" { trace.tcpState = trace.tcp.isEmpty ? "noMatchingConnection" : "stopped" }
        if trace.logState == "collecting" { trace.logState = "stopped" }
        if trace.tcp.isEmpty { trace.notes.append("未读到本对端 TCP 5900 连接；可能权限受限或使用其他传输，不能当作网络正常。") }
        return trace
    }
    deinit { net?.stop(); logs?.stop() }
}
