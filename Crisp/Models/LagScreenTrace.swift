import Foundation
import Network
import Darwin

/// Parser is shared by both hosts. Export only selected numeric counters and
/// event categories; never raw system logs, Wi-Fi names or unrelated sockets.
struct LagScreenParser {
    private var columns: [String] = []
    private var process: String?
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
    mutating func tcp(_ line: String, peer: String, server: Bool, stamp: Double, allTransports: Bool = false) -> LagTCPReading? {
        let cells = line.components(separatedBy: ",")
        if cells.first == "", cells.contains("bytes_in") { columns = cells; return nil }
        guard let name = cells.first, cells.count == columns.count else { return nil }
        guard name.hasPrefix("tcp") || (allTransports && name.hasPrefix("udp")) else {
            if !name.isEmpty { process = String(name.prefix(128)) }
            return nil
        }
        let udp = name.hasPrefix("udp")
        let pair = name.dropFirst(5).components(separatedBy: "<->")
        guard pair.count == 2, let local = Self.endpoint(pair[0]), let remote = Self.endpoint(pair[1]),
              remote.0 == Self.normalized(peer),
              allTransports || (server ? local.1 : remote.1) == 5900 else { return nil }
        func field(_ key: String) -> String? { columns.firstIndex(of: key).map { cells[$0] } }
        guard (udp || field("state") == "Established"),
              let incoming = field("bytes_in").flatMap(UInt64.init),
              let outgoing = field("bytes_out").flatMap(UInt64.init) else { return nil }
        let rtt = field("rtt_avg").flatMap { Double($0.replacingOccurrences(of: " ms", with: "")) }
        return LagTCPReading(stamp: stamp, connection: String((allTransports ? "\(process ?? "unknown") \(name)" : name).prefix(256)),
            interface: String((field("interface") ?? "").prefix(32)), bytesIn: incoming, bytesOut: outgoing,
            retransmitBytes: udp ? nil : field("re-tx").flatMap(UInt64.init),
            duplicateBytes: udp ? nil : field("rx_dupe").flatMap(UInt64.init), outOfOrderBytes: udp ? nil : field("rx_ooo").flatMap(UInt64.init),
            rttMS: udp ? nil : rtt.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            receiveBuffer: udp ? nil : field("rcvsize").flatMap(UInt64.init), sendWindow: udp ? nil : field("tx_win").flatMap(UInt64.init),
            transport: allTransports ? (udp ? "udp" : "tcp") : nil, process: allTransports ? process : nil)
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
    private var handles: [FileHandle] = []
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
    func start(path: String, arguments: [String], seconds: Double = 25, lineBuffered: Bool = false) {
        guard !stopped else { return }
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, right in right }
        process.standardInput = FileHandle.nullDevice
        let errors = Pipe()
        let output: FileHandle
        if lineBuffered {
            // nettop buffers CSV until exit when stdout is a pipe. A raw PTY
            // makes libc flush each line, without a shell, helper process or
            // repeated nettop launches. No terminal input is attached.
            var master: Int32 = -1, slave: Int32 = -1
            guard openpty(&master, &slave, nil, nil, nil) == 0 else { exit("unavailable"); return }
            var settings = termios()
            guard tcgetattr(slave, &settings) == 0 else {
                Darwin.close(master); Darwin.close(slave); exit("unavailable"); return
            }
            cfmakeraw(&settings)
            guard tcsetattr(slave, TCSANOW, &settings) == 0 else {
                Darwin.close(master); Darwin.close(slave); exit("unavailable"); return
            }
            _ = fcntl(master, F_SETFD, FD_CLOEXEC)
            _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
            handles = [FileHandle(fileDescriptor: master, closeOnDealloc: true), errors.fileHandleForReading]
            output = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        } else {
            let pipe = Pipe()
            handles = [pipe.fileHandleForReading, errors.fileHandleForReading]
            output = pipe.fileHandleForWriting
        }
        process.standardOutput = output; process.standardError = errors.fileHandleForWriting
        defer { output.closeFile(); errors.fileHandleForWriting.closeFile() }
        process.terminationHandler = { [weak self] child in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.drain()
                guard !self.stopped else { return }
                self.exit(child.terminationStatus == 0 ? "exited" : "unavailable")
                self.stop()
            }
        }
        do { try process.run() }
        catch { handles.forEach { $0.closeFile() }; handles = []; exit("unavailable"); stop(); return }
        for (index, handle) in handles.enumerated() {
            _ = fcntl(handle.fileDescriptor, F_SETFL, fcntl(handle.fileDescriptor, F_GETFL) | O_NONBLOCK)
            let reader = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
            reader.setEventHandler { [weak self] in
                self?.readAvailable(index: index, handle: handle)
            }
            reader.setCancelHandler { handle.closeFile() }
            readers.append(reader); reader.resume()
        }
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + seconds)
        timeout.setEventHandler { [weak self] in self?.exit("timeout"); self?.stop() }
        self.timeout = timeout; timeout.resume()
    }
    private func readAvailable(index: Int, handle: FileHandle) {
        guard !stopped, !readers[index].isCancelled else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        while !stopped {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            if count <= 0 { readers[index].cancel(); return } // PTY EOF can be EIO.
            byteCount += count
            guard byteCount <= 262_144 else { exit("truncated"); stop(); return }
            buffers[index].append(contentsOf: bytes.prefix(count))
            while !stopped, let end = buffers[index].firstIndex(of: 10) {
                let value = String(data: buffers[index][..<end], encoding: .utf8)
                buffers[index].removeSubrange(...end)
                if index == 0, let value { line(value) }
            }
            if !stopped, buffers[index].count > 16_384 { exit("truncated"); stop() }
        }
    }
    func drain() {
        // Nonblocking: keep already-delivered rows on early stop, never wait
        // for another sample or invent its time from process termination.
        for (index, handle) in handles.enumerated() {
            guard !stopped else { return }
            readAvailable(index: index, handle: handle)
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; timeout?.cancel(); timeout = nil
        readers.forEach { $0.cancel() }; readers.removeAll(); handles = []; buffers = [Data(), Data()]
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

    init(queue: DispatchQueue, peer: String?, pid: Int32? = nil, server: Bool = false, allTransports: Bool = false) {
        self.queue = queue
        trace = LagScreenTrace(started: LagRecorder.now(), wallTime: Date())
        trace.allTransports = allTransports ? true : nil
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
        var args = ["-L", "25", "-s", "1", "-n", "-x", "-J", LagScreenParser.fields]
        if !allTransports { args += ["-m", "tcp"] }
        if server { args += ["-p", "screensharingd", "-p", "ScreensharingAgent"] }
        else if let pid, pid > 0 {
            args += ["-p", String(pid)]
            if allTransports { args += ["-p", "ScreensharingAgent", "-p", "screensharingd"] }
        }
        else {
            trace.tcpState = "unavailable"; trace.logState = "notStarted"
            trace.notes.append("未取得被测窗口进程，未扩大为全机连接采集。")
            return
        }
        trace.tcpState = "collecting"; trace.logState = "collecting"
        net = LagTraceCommand(queue: queue, line: { [weak self] line in
            guard let self, !self.ended,
                  let sample = self.parser.tcp(line, peer: peer, server: server, stamp: LagRecorder.now(), allTransports: allTransports) else { return }
            guard self.trace.tcp.count < (allTransports ? 192 : 128) else {
                self.trace.truncated = true; self.trace.tcpState = "truncated"; self.net?.stop(); return
            }
            self.trace.tcp.append(sample)
        }, exit: { [weak self] state in
            guard let self, !self.ended else { return }
            self.trace.tcpState = state
            if state == "truncated" { self.trace.truncated = true }
        })
        net?.start(path: "/usr/bin/nettop", arguments: args, lineBuffered: true)
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
        net?.drain(); logs?.drain()
        ended = true; trace.ended = LagRecorder.now()
        net?.stop(); logs?.stop(); net = nil; logs = nil
        if trace.tcpState == "collecting" { trace.tcpState = trace.tcp.isEmpty ? "noMatchingConnection" : "stopped" }
        if trace.logState == "collecting" { trace.logState = "stopped" }
        if trace.tcp.isEmpty { trace.notes.append(trace.allTransports == true
            ? "未匹配到所选客户端/系统共享服务与该对端的 TCP/UDP；其他进程、转发地址或权限限制仍可能遗漏。"
            : "未读到本对端 TCP 5900 连接；可能权限受限或使用其他传输，不能当作网络正常。") }
        return trace
    }
    deinit { net?.stop(); logs?.stop() }
}
