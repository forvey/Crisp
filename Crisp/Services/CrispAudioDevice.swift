import CoreAudio
import Foundation

enum CrispAudioDevice {
    static let uid = "com.forvey.Crisp.RemoteMicrophone"
    static let driverPath = "/Library/Audio/Plug-Ins/HAL/CrispRemoteMicrophone.driver"
    static let control: AudioObjectPropertySelector = 0x636d6374
    static let write: AudioObjectPropertySelector = 0x636d7772
    static let status: AudioObjectPropertySelector = 0x636d7374
    static let usage: AudioObjectPropertySelector = 0x636d7573

    static func find() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { device in
            var key = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var reference: UnsafeMutableRawPointer?
            var bytes = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
            guard AudioObjectGetPropertyData(device, &key, 0, nil, &bytes, &reference) == noErr,
                  let reference else { return false }
            let value = Unmanaged<CFString>.fromOpaque(reference).takeRetainedValue()
            guard (value as String) == uid else { return false }
            key.mSelector = status
            guard AudioObjectHasProperty(device, &key) else { return false }
            var raw: UnsafeMutableRawPointer?
            bytes = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
            guard AudioObjectGetPropertyData(device, &key, 0, nil, &bytes, &raw) == noErr, let raw else { return false }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeRetainedValue()
            return CFGetTypeID(data) == CFDataGetTypeID()
                && CFDataGetLength(data) == MemoryLayout<CrispMicControl>.size
                && Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: 4)) == [1, 0, 0, 0]
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
            throw CrispAudioWire.Failure(reason: "Virtual microphone write failed (\(result)); reconnect after checking the device")
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
        guard CFGetTypeID(data) == CFDataGetTypeID(), CFDataGetLength(data) == MemoryLayout<CrispMicUsage>.size else { return .unavailable }
        var value = CrispMicUsage()
        withUnsafeMutableBytes(of: &value) { bytes in
            bytes.baseAddress!.copyMemory(from: CFDataGetBytePtr(data)!, byteCount: bytes.count)
        }
        guard value.version == 1, value.running <= 1 else { return .unavailable }
        return value.running == 1 ? .inUse : .idle
    }
}

/// Network callbacks only mutate a five-packet bounded queue. A separate worker performs
/// resampling and HAL property IPC; no PCM closure backlog is submitted to DispatchQueue.
final class CrispMicrophoneWriter: @unchecked Sendable {
    private struct State {
        var device: AudioDeviceID = 0
        var active = false
        var enabled = false
        var generation: UInt64 = UInt64.random(in: 1...UInt64.max / 2)
        var packets: [(Data, TimeInterval)] = []
        var failure: @Sendable (String) -> Void = { _ in }
        var recorder: LagRecorder?
        var probe: AudioProbeStats?
    }
    private let lock = NSLock()
    private var state = State()
    private let queue = DispatchQueue(label: "com.crisp.remote-audio.microphone", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var applied: UInt64 = 0
    private var resampler: CrispAudioResampler?
    private var converted: [Float] = []
    func beginProbeStats() {
        lock.lock()
        state.probe = AudioProbeStats(queueDrops: 0, staleDrops: 0, pendingPackets: 0, halWrites: 0)
        lock.unlock()
    }
    func finishProbeStats() -> AudioProbeStats? {
        queue.sync {
            lock.lock(); defer { lock.unlock() }
            var result = state.probe
            if result != nil { result!.pendingPackets! += state.packets.count }
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
        state.generation &+= 1; state.packets.removeAll()
        lock.unlock()
        queue.async { [self] in
            if timer == nil {
                let clock = DispatchSource.makeTimerSource(queue: queue)
                clock.schedule(deadline: .now(), repeating: .milliseconds(10))
                clock.setEventHandler { [weak self] in self?.pump() }
                timer = clock; clock.resume()
            }
        }
    }

    func microphone(_ enabled: Bool) {
        lock.lock()
        state.enabled = enabled && state.active
        state.generation &+= 1; state.packets.removeAll()
        lock.unlock()
    }

    func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard state.active, state.enabled else { return }
        if state.packets.count == 5 {
            state.recorder?.count("mic.queue_drop")
            if state.probe != nil { state.probe!.queueDrops! += 1 }
            state.packets.removeFirst()
        }
        state.packets.append((data, ProcessInfo.processInfo.systemUptime))
    }

    func stop(waitForMute: Bool = false) {
        lock.lock()
        state.active = false; state.enabled = false; state.generation &+= 1
        if state.probe != nil { state.probe!.pendingPackets! += state.packets.count }
        state.packets.removeAll()
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in pump(); done.signal() }
        if waitForMute { _ = done.wait(timeout: .now() + .milliseconds(300)) }
    }

    private func pump() {
        lock.lock()
        let snapshot = state
        let packet = state.packets.isEmpty ? nil : state.packets.removeFirst()
        lock.unlock()
        guard snapshot.device != 0 else { return }
        let began = snapshot.recorder.map { _ in LagRecorder.now() }
        defer { if let began { snapshot.recorder?.duration("mic.hal_pump_ms", since: began) } }
        do {
            if applied != snapshot.generation {
                var control = CrispMicControl(version: 1, enabled: snapshot.enabled ? 1 : 0, generation: snapshot.generation)
                try CrispAudioDevice.send(withUnsafeBytes(of: &control) { Data($0) },
                                          selector: CrispAudioDevice.control, device: snapshot.device)
                applied = snapshot.generation
                converted.removeAll()
                resampler = try CrispAudioResampler(from: 24000, to: 48000)
            }
            if !snapshot.active { timer?.cancel(); timer = nil; resampler = nil; return }
            guard snapshot.enabled, let packet else { return }
            let age = ProcessInfo.processInfo.systemUptime - packet.1
            snapshot.recorder?.value("mic.queue_age_ms", age * 1000)
            guard age <= 0.1 else {
                snapshot.recorder?.count("mic.stale_drop")
                if snapshot.probe != nil {
                    lock.lock()
                    if state.probe != nil { state.probe!.staleDrops! += 1 }
                    lock.unlock()
                }
                return
            }
            converted += try resampler?.convert(CrispAudioPCM.floats(packet.0)) ?? []
            while converted.count >= 960 {
                lock.lock()
                let stillCurrent = state.active && state.enabled && state.generation == snapshot.generation
                lock.unlock()
                guard stillCurrent else { converted.removeAll(); return }
                var frame = CrispMicPacket()
                frame.version = 1; frame.frames = 960; frame.generation = snapshot.generation
                withUnsafeMutableBytes(of: &frame.samples) { bytes in
                    converted.withUnsafeBufferPointer { bytes.baseAddress?.copyMemory(from: $0.baseAddress!, byteCount: 960 * 4) }
                }
                converted.removeFirst(960)
                try CrispAudioDevice.send(withUnsafeBytes(of: &frame) { Data($0) },
                                          selector: CrispAudioDevice.write, device: snapshot.device)
                snapshot.recorder?.count("mic.hal_packets_written")
                if snapshot.probe != nil {
                    lock.lock()
                    if state.probe != nil { state.probe!.halWrites! += 1 }
                    lock.unlock()
                }
            }
        } catch {
            timer?.cancel(); timer = nil
            lock.lock()
            let report = state.active && state.generation == snapshot.generation
            if state.generation == snapshot.generation {
                state.active = false; state.enabled = false; state.device = 0
                state.packets.removeAll()
            }
            lock.unlock()
            converted.removeAll(); resampler = nil
            if report { snapshot.failure(error.localizedDescription) }
        }
    }
}
