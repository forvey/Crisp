import CoreAudio
import Foundation

enum CrispAudioDevice {
    static let uid = "com.forvey.Crisp.RemoteMicrophone"
    static let driverPath = "/Library/Audio/Plug-Ins/HAL/CrispRemoteMicrophone.driver"
    static let control: AudioObjectPropertySelector = 0x636d6374
    static let write: AudioObjectPropertySelector = 0x636d7772
    static let status: AudioObjectPropertySelector = 0x636d7374
    static let usage: AudioObjectPropertySelector = 0x636d7573

    static func healthStatus() -> CrispHALDriverStatus {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return FileManager.default.fileExists(atPath: driverPath) ? .notLoaded : .notInstalled
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return FileManager.default.fileExists(atPath: driverPath) ? .notLoaded : .notInstalled
        }
        for device in devices {
            guard deviceUID(device) == uid else { continue }
            return isReadyDevice(device) ? .ready : .outdated
        }
        return FileManager.default.fileExists(atPath: driverPath) ? .notLoaded : .notInstalled
    }

    private static func deviceUID(_ device: AudioDeviceID) -> String? {
        var key = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var reference: UnsafeMutableRawPointer?
        var bytes = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
        guard AudioObjectGetPropertyData(device, &key, 0, nil, &bytes, &reference) == noErr,
              let reference else { return nil }
        return Unmanaged<CFString>.fromOpaque(reference).takeRetainedValue() as String
    }

    private static func isReadyDevice(_ device: AudioDeviceID) -> Bool {
        var key = AudioObjectPropertyAddress(mSelector: status,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        guard AudioObjectHasProperty(device, &key) else { return false }
        var raw: UnsafeMutableRawPointer?
        var bytes = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
        guard AudioObjectGetPropertyData(device, &key, 0, nil, &bytes, &raw) == noErr, let raw else { return false }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeRetainedValue()
        guard CFGetTypeID(data) == CFDataGetTypeID()
            && CFDataGetLength(data) == MemoryLayout<CrispMicControl>.size
            && Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: 4)) == [1, 0, 0, 0]
        else { return false }
        // Burst writes require the 1.0.4 buffer. An older 100-ms driver
        // would silently drop speech; keep speakers available, but do not
        // advertise this input as usable until the bundled HAL is loaded.
        key.mSelector = CRISP_MIC_BUFFER_STATS
        return AudioObjectHasProperty(device, &key)
    }

    static func find() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { device in
            deviceUID(device) == uid && isReadyDevice(device)
        }
    }

    static func send(_ data: Data, selector: AudioObjectPropertySelector, device: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        let value = data as CFData
        var reference = Unmanaged.passUnretained(value).toOpaque()
        let result = withExtendedLifetime(value) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: reference)), &reference)
        }
        guard result == noErr else {
            throw CrispAudioWire.Failure(
                reason: String(localized: "Virtual microphone write failed (\(result)); reconnect after checking the device")
            )
        }
    }
}

/// Observe the HAL's actual input consumers; never open the input ourselves
/// and never poll. A missing/old driver reports unavailable, not "idle".
final class CrispMicrophoneUsage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.crisp.remote-audio.input-use")
    private var observed: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var generation = UUID()
    private var device: AudioDeviceID = 0
    private var last: CrispAudioWire.MicrophoneUse?
    private var changed: @Sendable (CrispAudioWire.MicrophoneUse) -> Void = { _ in }

    func start(_ changed: @escaping @Sendable (CrispAudioWire.MicrophoneUse) -> Void) {
        queue.sync {
            stopOnQueue()
            self.changed = changed
            guard let device = CrispAudioDevice.find() else { changed(.unavailable); return }
            self.device = device
            let token = generation
            let properties: [(AudioObjectID, AudioObjectPropertySelector)] = [
                (device, CrispAudioDevice.usage),
                (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
            ]
            for (object, selector) in properties {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    guard let self, self.generation == token else { return }
                    self.publish()
                }
                guard AudioObjectHasProperty(object, &address),
                      AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else {
                    stopOnQueue(); changed(.unavailable); return
                }
                observed.append((object, address, block))
            }
            publish() // Subscription first: do not miss an already-open input.
        }
    }

    func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
        generation = UUID()
        for (object, var address, block) in observed {
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        observed.removeAll(); device = 0; last = nil; changed = { _ in }
    }

    private func publish() {
        let use = read()
        guard last != use else { return }
        last = use
        changed(use)
    }

    private func read() -> CrispAudioWire.MicrophoneUse {
        var address = AudioObjectPropertyAddress(mSelector: CrispAudioDevice.usage,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var raw: UnsafeMutableRawPointer?
        var size = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
        guard device != 0,
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &raw) == noErr,
              let raw else { return .unavailable }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeRetainedValue()
        guard CFGetTypeID(data) == CFDataGetTypeID(), CFDataGetLength(data) == MemoryLayout<CrispMicUsage>.size,
              let source = CFDataGetBytePtr(data) else { return .unavailable }
        var value = CrispMicUsage()
        withUnsafeMutableBytes(of: &value) { bytes in
            bytes.baseAddress?.copyMemory(from: source, byteCount: bytes.count)
        }
        guard value.version == 1, value.running <= 1 else { return .unavailable }
        return value.running == 1 ? .inUse : .idle
    }
}

/// A 140-ms network gap can be followed by seven packets at once. Keep that
/// burst intact, then drain to the HAL's playback buffer in small paced batches
/// so tight IPC loops do not collide with the real-time HAL trylock.
final class CrispMicrophoneWriter: @unchecked Sendable {
    private struct State {
        var device: AudioDeviceID = 0
        var active = false
        var enabled = false
        var generation: UInt64 = UInt64.random(in: 1...UInt64.max / 2)
        var packets: [(Data, TimeInterval)] = []
        var pumpPending = false
        var failure: @Sendable (String) -> Void = { _ in }
        var recorder: LagRecorder?
        var probe: AudioProbeStats?
    }
    private let lock = NSLock()
    private var state = State()
    private let queue = DispatchQueue(label: "com.crisp.remote-audio.microphone", qos: .userInitiated)
    private var paceWorkItem: DispatchWorkItem?
    private var applied: UInt64 = 0
    private var resampler: CrispAudioResampler?
    private var converted: [Float] = []
    private let sendToDriver: @Sendable (Data, AudioObjectPropertySelector, AudioDeviceID) throws -> Void
    init(sendToDriver: @escaping @Sendable (Data, AudioObjectPropertySelector, AudioDeviceID) throws -> Void = {
        try CrispAudioDevice.send($0, selector: $1, device: $2)
    }) { self.sendToDriver = sendToDriver }

    func beginProbeStats() {
        lock.lock()
        state.probe = AudioProbeStats(queueDrops: 0, staleDrops: 0, pendingPackets: 0, halWrites: 0)
        lock.unlock()
    }

    func finishProbeStats() -> AudioProbeStats? {
        queue.sync {
            lock.lock(); defer { lock.unlock() }
            var result = state.probe
            if var probe = result {
                probe.pendingPackets = (probe.pendingPackets ?? 0) + state.packets.count
                result = probe
            }
            state.probe = nil
            return result
        }
    }

    func setDiagnostics(_ recorder: LagRecorder?) {
        lock.lock(); state.recorder = recorder; lock.unlock()
    }

    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock(); state.failure = handler; lock.unlock()
    }

    func start(device: AudioDeviceID) {
        lock.lock()
        state.device = device; state.active = true; state.enabled = false
        state.generation &+= 1; state.packets.removeAll(); state.pumpPending = false
        lock.unlock()
        scheduleImmediatePump()
    }

    func microphone(_ enabled: Bool) {
        lock.lock()
        state.enabled = enabled && state.active
        if var probe = state.probe {
            probe.pendingPackets = (probe.pendingPackets ?? 0) + state.packets.count
            state.probe = probe
        }
        state.generation &+= 1; state.packets.removeAll(); state.pumpPending = false
        lock.unlock()
        scheduleImmediatePump()
    }

    func receive(_ data: Data) {
        lock.lock()
        guard state.active, state.enabled else { lock.unlock(); return }
        if state.packets.count == 15 {
            state.recorder?.count("mic.queue_drop")
            if var probe = state.probe {
                probe.queueDrops = (probe.queueDrops ?? 0) + 1
                state.probe = probe
            }
            state.packets.removeFirst()
        }
        state.packets.append((data, ProcessInfo.processInfo.systemUptime))
        let shouldSchedule = !state.pumpPending
        if shouldSchedule { state.pumpPending = true }
        lock.unlock()
        if shouldSchedule {
            queue.async { [weak self] in self?.pump() }
        }
    }

    /// Drops queued packets older than `maxAge` during an uplink pause without
    /// bumping the HAL generation or forcing another 160–200 ms priming hole.
    func flushStale(maxAge: TimeInterval = 0.2) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        var stale = 0
        while let first = state.packets.first, now - first.1 > maxAge {
            state.packets.removeFirst()
            stale += 1
        }
        if stale > 0 {
            state.recorder?.count("mic.stale_drop", stale)
            if var probe = state.probe {
                probe.staleDrops = (probe.staleDrops ?? 0) + stale
                state.probe = probe
            }
        }
        lock.unlock()
    }

    func stop(waitForMute: Bool = false) {
        lock.lock()
        state.active = false; state.enabled = false; state.generation &+= 1
        state.pumpPending = false
        if var probe = state.probe {
            probe.pendingPackets = (probe.pendingPackets ?? 0) + state.packets.count
            state.probe = probe
        }
        state.packets.removeAll()
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            paceWorkItem?.cancel(); paceWorkItem = nil
            pump()
            done.signal()
        }
        if waitForMute { _ = done.wait(timeout: .now() + .milliseconds(300)) }
    }

    private func scheduleImmediatePump() {
        queue.async { [weak self] in
            self?.paceWorkItem?.cancel()
            self?.paceWorkItem = nil
            self?.pump()
        }
    }

    private func pump() {
        paceWorkItem?.cancel()
        paceWorkItem = nil

        lock.lock()
        state.pumpPending = false
        let batchCount = min(2, state.packets.count)
        let batch = Array(state.packets.prefix(batchCount))
        state.packets.removeFirst(batchCount)
        let hasMoreQueued = !state.packets.isEmpty
        var snapshot = state
        snapshot.packets = batch
        lock.unlock()

        // stop() can clear the live queue while this batch is in a HAL
        // call. Include its unwritten remainder in the final diagnostic count.
        var pending = batch.count
        defer {
            if pending > 0, snapshot.probe != nil {
                lock.lock()
                if var probe = state.probe {
                    probe.pendingPackets = (probe.pendingPackets ?? 0) + pending
                    state.probe = probe
                }
                lock.unlock()
            }
        }
        guard snapshot.device != 0 else { return }
        let began = snapshot.recorder.map { _ in LagRecorder.now() }
        defer { if let began { snapshot.recorder?.duration("mic.hal_pump_ms", since: began) } }
        do {
            if applied != snapshot.generation {
                var control = CrispMicControl(version: 1, enabled: snapshot.enabled ? 1 : 0, generation: snapshot.generation)
                try sendToDriver(withUnsafeBytes(of: &control) { Data($0) }, CrispAudioDevice.control, snapshot.device)
                applied = snapshot.generation
                converted.removeAll()
                resampler = try CrispAudioResampler(from: 24000, to: 48000)
            }
            if !snapshot.active { resampler = nil; converted.removeAll(); return }
            guard snapshot.enabled else { return }

            var writtenThisPass = 0
            for packet in batch {
                if !isCurrentGeneration(snapshot.generation) { break }
                let age = ProcessInfo.processInfo.systemUptime - packet.1
                snapshot.recorder?.value("mic.queue_age_ms", age * 1000)
                if age > 0.3 {
                    snapshot.recorder?.count("mic.stale_drop")
                    lock.lock()
                    if var probe = state.probe {
                        probe.staleDrops = (probe.staleDrops ?? 0) + 1
                        state.probe = probe
                    }
                    lock.unlock()
                    pending -= 1
                    continue
                }
                converted += try resampler?.convert(CrispAudioPCM.floats(packet.0)) ?? []
                let outcome = try drainConvertedFrames(snapshot: snapshot)
                writtenThisPass += outcome.writes
                guard outcome.completed else { break }
                pending -= 1
            }

            if hasMoreQueued || converted.count >= 960 {
                schedulePacedContinuation(writtenThisPass: writtenThisPass)
            }
        } catch {
            handlePumpFailure(error, snapshot: snapshot)
        }
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        lock.lock()
        let current = state.active && state.enabled && state.generation == generation
        lock.unlock()
        return current
    }

    private func drainConvertedFrames(snapshot: State) throws -> (writes: Int, completed: Bool) {
        var writes = 0
        while converted.count >= 960 {
            guard isCurrentGeneration(snapshot.generation) else {
                converted.removeAll()
                return (writes, false)
            }
            var frame = CrispMicPacket()
            frame.version = 1; frame.frames = 960; frame.generation = snapshot.generation
            withUnsafeMutableBytes(of: &frame.samples) { bytes in
                converted.withUnsafeBufferPointer { source in
                    if let dst = bytes.baseAddress, let src = source.baseAddress {
                        dst.copyMemory(from: src, byteCount: 960 * 4)
                    }
                }
            }
            converted.removeFirst(960)
            try sendToDriver(withUnsafeBytes(of: &frame) { Data($0) }, CrispAudioDevice.write, snapshot.device)
            snapshot.recorder?.count("mic.hal_packets_written")
            writes += 1
            if snapshot.probe != nil {
                lock.lock()
                if var probe = state.probe {
                    probe.halWrites = (probe.halWrites ?? 0) + 1
                    state.probe = probe
                }
                lock.unlock()
            }
        }
        return (writes, true)
    }

    private func schedulePacedContinuation(writtenThisPass: Int) {
        lock.lock()
        let shouldContinue = state.active && state.enabled && (!state.packets.isEmpty || converted.count >= 960)
        if shouldContinue { state.pumpPending = true }
        lock.unlock()
        guard shouldContinue else { return }
        let work = DispatchWorkItem { [weak self] in self?.pump() }
        paceWorkItem = work
        // Yield briefly between small batches so coreaudiod's real-time ReadInput trylock stays uncontended.
        let delay: DispatchTimeInterval = writtenThisPass > 0 ? .milliseconds(2) : .milliseconds(0)
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handlePumpFailure(_ error: Error, snapshot: State) {
        paceWorkItem?.cancel(); paceWorkItem = nil
        lock.lock()
        let report = state.active && state.generation == snapshot.generation
        if state.generation == snapshot.generation {
            state.active = false; state.enabled = false; state.device = 0; state.pumpPending = false
            if var probe = state.probe {
                probe.pendingPackets = (probe.pendingPackets ?? 0) + state.packets.count
                state.probe = probe
            }
            state.packets.removeAll()
        }
        lock.unlock()
        converted.removeAll(); resampler = nil
        if report { snapshot.failure(error.localizedDescription) }
    }
}
