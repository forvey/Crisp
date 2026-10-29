import Foundation
import Darwin
import Network

enum LagScope: String, Codable, Sendable { case screen, audio, both
    var screen: Bool { self != .audio }
    var audio: Bool { self != .screen }
}

struct LagMetric: Codable, Sendable {
    var count = 0
    var total = 0.0
    var maximum = 0.0
    var over50ms = 0
    var over100ms = 0
    var over250ms = 0
    var bins = [Int](repeating: 0, count: 20)

    mutating func add(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        count += 1; total += value; maximum = max(maximum, value)
        if value >= 50 { over50ms += 1 }
        if value >= 100 { over100ms += 1 }
        if value >= 250 { over250ms += 1 }
        let bin = value < 1 ? 0 : min(19, Int(log2(value)) + 1)
        bins[bin] += 1
    }
    var p95Upper: Double {
        let threshold = Int(ceil(Double(count) * 0.95))
        guard threshold > 0 else { return 0 }
        var accumulated = 0
        for (index, count) in bins.enumerated() {
            accumulated += count
            if accumulated >= threshold { return index == 19 ? maximum : index == 0 ? 1 : pow(2, Double(index)) }
        }
        return maximum
    }
}

/// Constructed only for an explicit session. Callback writers never wait for
/// reporting: contention drops the diagnostic observation, never the user event.
final class LagRecorder: @unchecked Sendable {
    let scope: LagScope
    private let lock = NSLock()
    private var active = true
    private var metrics: [String: LagMetric] = [:]
    private var counters: [String: Int] = [:]
    private var last: [String: Double] = [:]
    private var dropped: Int32 = 0
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    init(scope: LagScope) { self.scope = scope }

    func duration(_ name: String, since start: Double) { value(name, (Self.now() - start) * 1000) }
    func value(_ name: String, _ value: Double) {
        guard lock.try() else { OSAtomicIncrement32Barrier(&dropped); return }
        defer { lock.unlock() }
        guard active, metrics.count < 80 || metrics[name] != nil else { return }
        metrics[name, default: LagMetric()].add(value)
    }
    func count(_ name: String, _ amount: Int = 1) {
        guard lock.try() else { OSAtomicIncrement32Barrier(&dropped); return }
        defer { lock.unlock() }
        guard active, counters.count < 80 || counters[name] != nil else { return }
        counters[name, default: 0] += amount
    }
    func interval(_ name: String) {
        let now = Self.now()
        guard lock.try() else { OSAtomicIncrement32Barrier(&dropped); return }
        defer { lock.unlock() }
        guard active, last.count < 80 || last[name] != nil,
              metrics.count < 80 || metrics[name] != nil else { return }
        if let previous = last[name] { metrics[name, default: LagMetric()].add((now - previous) * 1000) }
        last[name] = now
    }
    func snapshot() -> LagSnapshot {
        lock.lock(); defer { lock.unlock() }
        return LagSnapshot(stamp: Self.now(), metrics: metrics, counters: counters,
                           dropped: Int(OSAtomicAdd32Barrier(0, &dropped)))
    }
    func stop() { lock.lock(); active = false; lock.unlock() }
}

struct LagProcess: Codable, Sendable {
    let pid: Int32
    let name: String
    let cpu: Double?
    let residentBytes: UInt64?
    let diskReadBytes: UInt64?
    let diskWriteBytes: UInt64?
    let unavailable: String?
}
struct LagResources: Codable, Sendable {
    let processes: [LagProcess]
    let thermal: Int
    let swapBytes: UInt64?
    let systemCPU: Double?
    let network: String
}
struct LagSnapshot: Codable, Sendable {
    var stamp: Double
    var metrics: [String: LagMetric] = [:]
    var counters: [String: Int] = [:]
    var dropped = 0
    var resources: LagResources?
}

/// Native counters, one sample/second; no shell command, nettop or all-process
/// polling. Discover the small process whitelist once at explicit session start.
final class LagResourceSampler {
    private var processes: [(Int32, String)] = []
    private struct PreviousUsage {
        let stamp: Double
        let cpu: UInt64
        let read: UInt64
        let write: UInt64
    }
    private var previous: [Int32: PreviousUsage] = [:]
    private var previousCPU: [UInt32]?

    init(extraPID: Int32? = nil) {
        let names = Set(["Screen Sharing", "ScreenSharingEnhancer", "WindowServer",
                         "screensharingd", "ScreensharingAgent", "Crisp", "coreaudiod"])
        var pids = [Int32](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        for pid in pids.prefix(max(0, min(Int(count), pids.count))) where pid > 0 {
            var bytes = [CChar](repeating: 0, count: 1024)
            let name: String
            if proc_name(pid, &bytes, UInt32(bytes.count)) > 0 {
                guard let value = String(bytes: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                         encoding: .utf8) else { continue }
                name = value
            } else {
                // macOS may hide a system process name while still exposing its
                // executable path. Keep matching roles so sample() can report
                // unreadable resource counters rather than silently omitting them.
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                      let value = String(bytes: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                         encoding: .utf8) else { continue }
                name = URL(fileURLWithPath: value).lastPathComponent
            }
            if names.contains(name) || pid == extraPID { processes.append((pid, name)) }
        }
    }

    func sample(path: NWPath? = nil) -> LagResources {
        let now = LagRecorder.now()
        let samples: [LagProcess] = processes.map { pid, name in
            var usage = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard result == 0 else {
                return LagProcess(pid: pid, name: name, cpu: nil, residentBytes: nil,
                    diskReadBytes: nil, diskWriteBytes: nil, unavailable: "process exited or permission unavailable")
            }
            let cpu = usage.ri_user_time + usage.ri_system_time
            let old = previous[pid]
            previous[pid] = PreviousUsage(stamp: now, cpu: cpu, read: usage.ri_diskio_bytesread, write: usage.ri_diskio_byteswritten)
            let percent = old.flatMap { now > $0.stamp && cpu >= $0.cpu
                ? Double(cpu - $0.cpu) / 1e9 / (now - $0.stamp) * 100 : nil }
            return LagProcess(pid: pid, name: name, cpu: percent, residentBytes: usage.ri_phys_footprint,
                diskReadBytes: old.map { usage.ri_diskio_bytesread >= $0.read ? usage.ri_diskio_bytesread - $0.read : 0 },
                diskWriteBytes: old.map { usage.ri_diskio_byteswritten >= $0.write ? usage.ri_diskio_byteswritten - $0.write : 0 },
                unavailable: nil)
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let available = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        var busy: Double?
        if status == KERN_SUCCESS {
            let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
            if let old = previousCPU {
                let deltas = zip(ticks, old).map { Double($0 &- $1) }
                let total = deltas.reduce(0, +)
                if total > 0 { busy = (total - deltas[Int(CPU_STATE_IDLE)]) / total * 100 }
            }
            previousCPU = ticks
        }
        let network: String
        if let path {
            network = path.status != .satisfied ? "unavailable" : path.usesInterfaceType(.wifi) ? "wifi" :
                path.usesInterfaceType(.wiredEthernet) ? "ethernet" : path.usesInterfaceType(.loopback) ? "loopback" : "other"
        } else { network = "unknown" }
        return LagResources(processes: samples, thermal: ProcessInfo.processInfo.thermalState.rawValue,
                            swapBytes: available ? swap.xsu_used : nil, systemCPU: busy, network: network)
    }
}

// Diagnostics use a separate connection on the existing audio listener.
enum LagWire {
    static let hello = Data("SSE-CRISP-DIAGNOSTICS/1".utf8)
    // A 2x-rendered test chart is larger than the old fixed bitmap; this remains
    // bounded and applies only to the explicitly opened diagnostic connection.
    static let limit = 262_144
    static func framed(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + data
    }
    static func encode(_ message: LagMessage) throws -> Data {
        let data = try JSONEncoder().encode(message)
        guard data.count <= limit else { throw LagError.invalidMessage }
        return framed(data)
    }
    struct Parser {
        private var bytes = Data()
        mutating func append(_ data: Data) throws -> [LagMessage] {
            guard bytes.count + data.count <= limit * 2 else { throw LagError.invalidMessage }
            bytes.append(data)
            var result: [LagMessage] = []
            while bytes.count >= 4 {
                let count = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard count > 0, count <= limit else { throw LagError.invalidMessage }
                guard bytes.count >= count + 4 else { break }
                let message = try JSONDecoder().decode(LagMessage.self, from: Data(bytes.dropFirst(4).prefix(count)))
                guard message.version == 1 else { throw LagError.invalidMessage }
                result.append(message)
                bytes = Data(bytes.dropFirst(count + 4))
            }
            return result
        }
    }
}
enum LagError: Error { case invalidMessage }
struct LagMessage: Codable, Sendable {
    var kind: String
    var version = 1
    var id: String
    var scope: LagScope?
    var duration: Double?
    var time: Double?
    var received: Double?
    var sent: Double?
    var sequence: Int?
    var snapshot: LagSnapshot?
    var note: String?
    var motion: LagMotionSource?
    var quality: LagQualityReference?
    var collectScreenTrace: Bool?
    var screenTrace: LagScreenTrace?
}

// Numeric, bounded evidence for the actual native screen connection. Counters
// are cumulative OS values, NOT bytes lost during this test. Compare adjacent
// samples of the same connection; a one-second interval cannot explain 100 ms.
struct LagTCPReading: Codable, Sendable {
    let stamp: Double
    let connection: String
    let interface: String
    let bytesIn: UInt64
    let bytesOut: UInt64
    let retransmitBytes: UInt64?
    let duplicateBytes: UInt64?
    let outOfOrderBytes: UInt64?
    let rttMS: Double?
    let receiveBuffer: UInt64?
    let sendWindow: UInt64?
}
struct LagSystemEvent: Codable, Sendable {
    // Nil when the wall clock changed or the OS did not expose an event time.
    let stamp: Double?
    let receivedAt: Double
    let kind: String
    let durationMS: Double?
}
struct LagScreenTrace: Codable, Sendable {
    let started: Double
    let wallTime: Date
    var ended: Double?
    var tcp: [LagTCPReading] = []
    var events: [LagSystemEvent] = []
    var notes: [String] = []
    var tcpState = "notStarted"
    var logState = "notStarted"
    var truncated = false

    var valid: Bool {
        started.isFinite && started >= 0 && (ended.map { $0.isFinite && $0 >= started } ?? true) &&
        tcp.count <= 128 && events.count <= 256 && notes.count <= 12 && notes.allSatisfy { $0.utf8.count <= 512 } &&
        tcp.allSatisfy { $0.stamp.isFinite && $0.stamp >= started && $0.connection.utf8.count <= 256 &&
            $0.interface.utf8.count <= 32 && ($0.rttMS.map { $0.isFinite && $0 >= 0 } ?? true) } &&
        events.allSatisfy { $0.receivedAt.isFinite && ($0.stamp.map(\.isFinite) ?? true) &&
            ["wifiScanStart", "wifiScanEnd", "gpuAllocationFailure"].contains($0.kind) &&
            ($0.durationMS.map { $0.isFinite && $0 >= 0 && $0 <= 60_000 } ?? true) }
    }
}

/// Only numeric evidence from our own test window; never desktop pixels.
struct LagMotionFrame: Codable, Sendable {
    let number: Int
    let stamp: Double
}
struct LagMotionSource: Codable, Sendable {
    let token: Int
    let frames: [LagMotionFrame]
    let completed: Bool
    let started: Double
    let ended: Double

    var valid: Bool {
        guard (1...4095).contains(token), frames.count <= 512,
              started.isFinite, ended.isFinite, started >= 0, ended >= started else { return false }
        for (index, frame) in frames.enumerated() {
            guard frame.number == index + 1, frame.stamp.isFinite, frame.stamp >= started, frame.stamp <= ended else { return false }
            if index > 0, frame.stamp <= frames[index - 1].stamp { return false }
        }
        return frames.isEmpty || frames.last!.stamp - frames.first!.stamp <= 18
    }
}
