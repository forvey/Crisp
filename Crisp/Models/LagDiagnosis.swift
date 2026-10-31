import Foundation
import Darwin
import CoreWLAN
import IOKit

/// Exists only during an explicit cause collection. No scans, screenshots,
/// process arguments, SSID/BSSID, privilege escalation or disk output.
final class LagHostSampler {
    private var previous: [Int32: (cpu: UInt64, birth: UInt64, stamp: Double)] = [:]
    private var vmPrevious: vm_statistics64_data_t?
    private var last: Double?
    private var accelerators: [io_object_t] = []
    private let wifi = CWWiFiClient()

    init() {
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while accelerators.count < 8 {
                let entry = IOIteratorNext(iterator)
                if entry == 0 { break }
                accelerators.append(entry)
            }
        }
    }
    deinit { accelerators.forEach { IOObjectRelease($0) } }

    func sample(interface: String?, timerLateMS: Double) -> LagHostReading {
        let began = LagRecorder.now()
        var result = LagHostReading(interval: last.map { began - $0 }, timerLateMS: timerLateMS)
        last = began
        var level: Int32 = 0, length = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) == 0,
           [1, 2, 4].contains(level) { result.memoryPressure = Int(level) }
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let page = UInt64(getpagesize())
            if let old = vmPrevious {
                func delta(_ new: UInt64, _ old: UInt64) -> UInt64? { new >= old ? (new - old) * page : nil }
                result.swapInBytes = delta(vm.swapins, old.swapins)
                result.swapOutBytes = delta(vm.swapouts, old.swapouts)
                result.pageOutBytes = delta(vm.pageouts, old.pageouts)
            }
            result.compressedBytes = UInt64(vm.compressor_page_count) * page
            vmPrevious = vm
        }
        for (index, accelerator) in accelerators.enumerated() {
            guard let dictionary = IORegistryEntryCreateCFProperty(accelerator, "PerformanceStatistics" as CFString,
                    kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            // Vendor counters are optional device-wide evidence, never per-app
            // GPU/encoder utilization. Unknown fields are deliberately ignored.
            for key in ["Device Utilization %", "GPU Activity(%)"] {
                if let value = dictionary[key] as? NSNumber, value.doubleValue.isFinite,
                   (0...100).contains(value.doubleValue) {
                    result.gpu.append(LagGPUReading(device: "accelerator-\(index)", field: key, percent: value.doubleValue))
                }
            }
        }
        // Include the actual busiest readable processes, not just our apps.
        // Names only; never inspect arguments, windows, files or user content.
        var pids = [Int32](repeating: 0, count: 2048)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        result.processLimitReached = n >= pids.count
        var next: [Int32: (cpu: UInt64, birth: UInt64, stamp: Double)] = [:]
        var busy: [(Int32, Double, UInt64)] = []
        for pid in pids.prefix(max(0, min(Int(n), pids.count))) where pid > 0 {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { result.unreadableProcesses += 1; continue }
            result.readableProcesses += 1
            let cpu = usage.ri_user_time + usage.ri_system_time
            next[pid] = (cpu, usage.ri_proc_start_abstime, began)
            if let old = previous[pid], old.birth == usage.ri_proc_start_abstime, cpu >= old.cpu,
               began - old.stamp >= 0.5 {
                busy.append((pid, Double(cpu - old.cpu) / 1e9 / (began - old.stamp) * 100, usage.ri_phys_footprint))
            }
        }
        previous = next
        result.busyProcesses = busy.sorted { $0.1 > $1.1 }.prefix(6).map { pid, cpu, memory in
            var name = [CChar](repeating: 0, count: 128)
            let known = proc_name(pid, &name, UInt32(name.count)) > 0
            return LagProcess(pid: pid, name: known ? String(cString: name) : "PID \(pid)", cpu: cpu,
                residentBytes: memory, diskReadBytes: nil, diskWriteBytes: nil,
                unavailable: nil, cpuInterval: result.interval)
        }
        if let interface {
            if let wlan = wifi.interface(withName: interface), let channel = wlan.wlanChannel() {
                let rssi = wlan.rssiValue(), noise = wlan.noiseMeasurement(), rate = wlan.transmitRate()
                result.wifi = LagWiFiReading(interface: interface, channel: channel.channelNumber,
                    band: Int(channel.channelBand.rawValue), width: Int(channel.channelWidth.rawValue),
                    rssi: (-127 ..< 0).contains(rssi) ? rssi : nil,
                    noise: (-127 ..< 0).contains(noise) ? noise : nil,
                    transmitMbps: rate.isFinite && rate > 0 ? rate : nil)
            }
            var addresses: UnsafeMutablePointer<ifaddrs>?
            if getifaddrs(&addresses) == 0 {
                defer { freeifaddrs(addresses) }
                var pointer = addresses
                while let entry = pointer {
                    defer { pointer = entry.pointee.ifa_next }
                    guard String(cString: entry.pointee.ifa_name) == interface,
                          entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                          let raw = entry.pointee.ifa_data else { continue }
                    let data = raw.assumingMemoryBound(to: if_data.self).pointee
                    result.interface = LagInterfaceReading(name: interface, bytesIn: UInt64(data.ifi_ibytes),
                        bytesOut: UInt64(data.ifi_obytes), errorsIn: UInt64(data.ifi_ierrors), errorsOut: UInt64(data.ifi_oerrors))
                    break
                }
            }
        }
        result.sampleMS = (LagRecorder.now() - began) * 1000
        return result
    }
}

struct LagProbeParser {
    static func reading(_ line: String, at stamp: Double) -> LagProbeReading? {
        let marker = line.contains("icmp_seq=") ? "icmp_seq=" : "icmp_seq "
        guard let start = line.range(of: marker),
              let sequence = Int(line[start.upperBound...].prefix(while: { $0.isNumber })), (0..<64).contains(sequence) else { return nil }
        if let time = line.range(of: "time="), let value = Double(line[time.upperBound...].prefix(while: { $0.isNumber || $0 == "." })),
           value.isFinite, value >= 0, value <= 60_000 {
            return LagProbeReading(stamp: stamp, sequence: sequence, rttMS: value)
        }
        if line.contains("Request timeout") { return LagProbeReading(stamp: stamp, sequence: sequence, rttMS: nil) }
        return nil
    }
    static func totals(_ line: String) -> (Int, Int)? {
        guard line.contains("packets transmitted"), line.contains("packets received") else { return nil }
        let parts = line.components(separatedBy: ",")
        guard parts.count >= 2, let sent = Int(parts[0].trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber })),
              let received = Int(parts[1].trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber })),
              (0...30).contains(sent), (0...sent).contains(received) else { return nil }
        return (sent, received)
    }
    static func numericAddress(_ string: String) -> Bool {
        let address = string.components(separatedBy: "%")[0]
        var v4 = in_addr(), v6 = in6_addr()
        return address.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}

/// One small ping every 500 ms per target, on the actual peer route. ICMP
/// results are supporting evidence; no replies do not prove a broken link.
final class LagNetworkCollector {
    private let queue: DispatchQueue
    private var trace = LagNetworkTrace(started: LagRecorder.now())
    private var commands: [LagTraceCommand] = []
    private var ended = false
    private var gateway: String?
    private let peer: String?
    private var routeTimer: DispatchSourceTimer?
    init(queue: DispatchQueue, peer: String?) {
        self.queue = queue; self.peer = peer
        guard let peer, LagProbeParser.numericAddress(peer), !["127.0.0.1", "::1"].contains(LagScreenParser.normalized(peer)) else {
            trace.routeState = "unavailable"; trace.notes = ["未取得实际对端或为回环测试，未启动路由探测。"]
            return
        }
        trace.routeState = "collecting"
        route(peer, scoped: nil) { [weak self] interface, _ in
            guard let self, !self.ended else { return }
            guard let interface else { self.trace.routeState = "unavailable"; return }
            self.trace.interface = interface; self.trace.routeState = "read"
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 7, repeating: 7)
            timer.setEventHandler { [weak self] in self?.checkRoute() }
            self.routeTimer = timer; timer.resume()
            self.startPing(peer, interface: interface, gateway: false)
            // Same-subnet peer routes can have a link-layer next hop. Read the
            // default gateway of this interface, not an unrelated VPN default.
            self.route("default", scoped: interface) { [weak self] _, gateway in
                guard let self, !self.ended else { return }
                guard let gateway else {
                    self.trace.gateway.state = "unavailable"
                    self.trace.notes.append("该接口默认网关不可读，不能完成无线接入分段比较。")
                    return
                }
                self.gateway = gateway
                self.startPing(gateway, interface: interface, gateway: true)
            }
        }
    }
    private func checkRoute() {
        guard !ended, let peer, let original = trace.interface else { return }
        route(peer, scoped: nil) { [weak self] interface, _ in
            guard let self, !self.ended else { return }
            guard interface == original else {
                self.trace.routeState = interface == nil ? "recheckUnavailable" : "changed"
                return
            }
            self.route("default", scoped: original) { [weak self] _, gateway in
                guard let self, !self.ended else { return }
                if self.gateway != nil, gateway != self.gateway { self.trace.routeState = "changed" }
            }
        }
    }
    private func route(_ target: String, scoped: String?, completion: @escaping (String?, String?) -> Void) {
        var interface: String?, gateway: String?
        var args = ["-n", "get", peer?.contains(":") == true ? "-inet6" : "-inet"]
        if let scoped { args += ["-ifscope", scoped] }
        args.append(target)
        let command = LagTraceCommand(queue: queue, line: { line in
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2 else { return }
            if pair[0] == "interface", !pair[1].isEmpty, pair[1].utf8.count <= 32 { interface = pair[1] }
            if pair[0] == "gateway", LagProbeParser.numericAddress(pair[1]) { gateway = pair[1] }
        }, exit: { [weak self] state in
            guard let self, !self.ended else { return }
            completion(state == "exited" ? interface : nil, state == "exited" ? gateway : nil)
        })
        commands.append(command); command.start(path: "/sbin/route", arguments: args, seconds: 2)
    }
    private func startPing(_ target: String, interface: String, gateway: Bool) {
        if gateway { trace.gateway.state = "collecting" } else { trace.peer.state = "collecting" }
        let command = LagTraceCommand(queue: queue, line: { [weak self] line in
            guard let self, !self.ended else { return }
            var probe = gateway ? self.trace.gateway : self.trace.peer
            if let reading = LagProbeParser.reading(line, at: LagRecorder.now()), probe.readings.count < 64 {
                probe.readings.append(reading)
            }
            if let totals = LagProbeParser.totals(line) { probe.transmitted = totals.0; probe.received = totals.1 }
            if gateway { self.trace.gateway = probe } else { self.trace.peer = probe }
        }, exit: { [weak self] state in
            guard let self, !self.ended else { return }
            if gateway { self.trace.gateway.state = state } else { self.trace.peer.state = state }
        })
        commands.append(command)
        let v6 = target.contains(":")
        let args = v6 ? ["-n", "-B", interface, "-i", "0.5", "-c", "30", "-s", "32", target]
            : ["-n", "-b", interface, "-i", "0.5", "-c", "30", "-W", "1000", "-s", "32", target]
        command.start(path: v6 ? "/sbin/ping6" : "/sbin/ping", arguments: args, seconds: 17, lineBuffered: true)
    }
    var interface: String? { trace.interface }
    func snapshot() -> LagNetworkTrace { trace }
    @discardableResult func stop() -> LagNetworkTrace {
        guard !ended else { return trace }
        commands.forEach { $0.drain() }; ended = true
        routeTimer?.cancel(); routeTimer = nil
        commands.forEach { $0.stop() }; commands.removeAll()
        trace.ended = LagRecorder.now()
        if trace.peer.state == "collecting" { trace.peer.state = "stopped" }
        if trace.gateway.state == "collecting" { trace.gateway.state = "stopped" }
        return trace
    }
    deinit { routeTimer?.cancel(); commands.forEach { $0.stop() } }
}
