import CoreAudio
import Foundation

enum CrispAudioDevice {
    static let uid = "com.forvey.Crisp.RemoteMicrophone"
    static let driverPath = "/Library/Audio/Plug-Ins/HAL/CrispRemoteMicrophone.driver"
    static let control: AudioObjectPropertySelector = 0x636d6374
    static let write: AudioObjectPropertySelector = 0x636d7772
    static let status: AudioObjectPropertySelector = 0x636d7374

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
    }
    private let lock = NSLock()
    private var state = State()
    private let queue = DispatchQueue(label: "com.crisp.remote-audio.microphone", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var applied: UInt64 = 0
    private var resampler: CrispAudioResampler?
    private var converted: [Float] = []
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
        if state.packets.count == 5 { state.recorder?.count("mic.queue_drop"); state.packets.removeFirst() }
        state.packets.append((data, ProcessInfo.processInfo.systemUptime))
    }

    func stop(waitForMute: Bool = false) {
        lock.lock()
        state.active = false; state.enabled = false; state.generation &+= 1
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
            guard age <= 0.1 else { snapshot.recorder?.count("mic.stale_drop"); return }
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
