import CoreAudio
import Foundation

private final class CrispCaptureRing: @unchecked Sendable {
    let reference: UnsafeMutableRawPointer
    init(capacity: Int) throws {
        guard let value = CrispRingCreate(capacity) else {
            throw CrispAudioWire.Failure(reason: String(localized: "Audio buffer allocation failed"))
        }
        reference = value
    }
    deinit { CrispRingDestroy(reference) }
}

/// A private audio-only aggregate containing a process tap, with no physical microphone
/// subdevice, screen stream, output IO or default-device changes.
@available(macOS 14.2, *)
final class CrispSystemAudioCapture {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioDeviceID = 0
    private var procedure: AudioDeviceIOProcID?
    private var ring: CrispCaptureRing?
    private var converter: CrispAudioResampler?
    private var sourceRate = 48000.0
    private var drainBuffer: [Float] = []
    private var output: [Float] = []
    private var priming = true
    private var startedAt = 0.0
    private let changeQueue = DispatchQueue(label: "com.crisp.remote-audio.device-changes")
    private var observed: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var onFailure: @Sendable (String) -> Void = { _ in }
    var recorder: LagRecorder?

    private static let packetFrames = CrispAudioWire.framesPerPacket // 480 (20 ms @ 24 kHz)
    private static let primingWatermark = 960                        // 40 ms pre-roll to absorb IOProc/timer jitter
    private static let highWatermark = 1440                          // 60 ms: emit extra packet to track clock drift
    private static let maxOutputFrames = 2400                        // 100 ms cap

    func start() throws {
        stop()
        do {
            var ownProcess = AudioObjectID(kAudioObjectUnknown)
            var pid = getpid()
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                          UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess)
            let excluded: [AudioObjectID] = ownProcess == kAudioObjectUnknown ? [] : [ownProcess]
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
            description.name = "Crisp Remote Audio"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap),
                      String(localized: "System audio permission / process tap"))
            var format = AudioStreamBasicDescription()
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            address.mSelector = kAudioTapPropertyFormat
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format),
                      String(localized: "Tap format"))
            guard format.mSampleRate > 0, format.mSampleRate <= 192000, format.mChannelsPerFrame == 1,
                  format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mBytesPerFrame == 4,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw CrispAudioWire.Failure(
                    reason: String(localized: "Unsupported process-tap format; reconnect after changing the output device")
                )
            }
            sourceRate = format.mSampleRate
            converter = try CrispAudioResampler(from: sourceRate, to: 24000)
            let ringCapacity = max(4096, Int(sourceRate * 0.25))
            let storage = try CrispCaptureRing(capacity: ringCapacity)
            ring = storage
            drainBuffer = [Float](repeating: 0, count: ringCapacity)
            priming = true
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Crisp Private Audio Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate),
                      String(localized: "Private tap device"))
            try check(AudioDeviceCreateIOProcIDWithBlock(&procedure, aggregate, nil) { _, input, _, _, _ in
                guard input.pointee.mNumberBuffers > 0 else { return }
                let buffer = input.pointee.mBuffers
                guard let data = buffer.mData, buffer.mNumberChannels == 1, buffer.mDataByteSize > 0 else { return }
                _ = CrispRingPushRealtime(storage.reference, data.assumingMemoryBound(to: Float.self), Int(buffer.mDataByteSize) / 4)
            }, String(localized: "Tap IO callback"))
            try check(AudioDeviceStart(aggregate, procedure), String(localized: "Start system audio capture"))
            startedAt = ProcessInfo.processInfo.systemUptime
            observe(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
            observe(tap, selector: kAudioTapPropertyFormat)
            address.mSelector = kAudioHardwarePropertyDefaultOutputDevice
            var defaultOutput: AudioDeviceID = 0
            size = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                          0, nil, &size, &defaultOutput) == noErr {
                observe(defaultOutput, selector: kAudioDevicePropertyNominalSampleRate)
            }
        } catch {
            stop()
            throw error
        }
    }

    /// Drains actual available samples from the tap ring and emits complete 480-sample
    /// packets driven by buffer watermark rather than padding short reads with zeros.
    func packets() throws -> [Data] {
        let began = recorder.map { _ in LagRecorder.now() }
        defer { if let began { recorder?.duration("capture.convert_ms", since: began) } }
        guard let ring, let converter else {
            throw CrispAudioWire.Failure(reason: String(localized: "System audio capture is not running"))
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let written = CrispRingLastWrite(ring.reference)
        let stalled = written == 0 ? ProcessInfo.processInfo.systemUptime - startedAt :
            Double(mach_absolute_time() - written) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        guard stalled < 3 else {
            throw CrispAudioWire.Failure(
                reason: String(localized: "System audio capture produced no buffers. Check recording permission, then reconnect.")
            )
        }
        recorder?.value("capture.last_callback_age_ms", stalled * 1000)

        let read = drainBuffer.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return CrispRingDrain(ring.reference, base, buffer.count)
        }
        if read > 0 {
            output += try converter.convert(Array(drainBuffer.prefix(read)))
        }
        if output.count > Self.maxOutputFrames {
            let excess = output.count - Self.maxOutputFrames
            recorder?.count("capture.overflow_frames", excess)
            output.removeFirst(excess)
        }

        if priming {
            guard output.count >= Self.primingWatermark else { return [] }
            priming = false
        }

        guard output.count >= Self.packetFrames else {
            recorder?.count("capture.under_watermark")
            return []
        }

        var packets: [Data] = []
        let first = Array(output.prefix(Self.packetFrames))
        output.removeFirst(Self.packetFrames)
        packets.append(CrispAudioPCM.bytes(first))

        // Drain a second packet when hardware sample clock runs ahead of the 20 ms timer.
        if output.count >= Self.highWatermark - Self.packetFrames {
            let second = Array(output.prefix(Self.packetFrames))
            output.removeFirst(Self.packetFrames)
            packets.append(CrispAudioPCM.bytes(second))
        }
        return packets
    }

    func packet() throws -> Data {
        try packets().first ?? CrispAudioWire.silence
    }

    func stop() {
        for (object, var address, block) in observed { AudioObjectRemovePropertyListenerBlock(object, &address, changeQueue, block) }
        observed.removeAll()
        if aggregate != 0, let procedure { AudioDeviceStop(aggregate, procedure); AudioDeviceDestroyIOProcID(aggregate, procedure) }
        procedure = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        ring = nil; converter = nil; drainBuffer.removeAll(); output.removeAll(); priming = true
    }

    private func observe(_ object: AudioObjectID, selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        let handler = onFailure
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler(String(localized: "Audio output device or sample rate changed; reconnect manually"))
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, changeQueue, block) == noErr { observed.append((object, address, block)) }
    }

    private func check(_ code: OSStatus, _ operation: String) throws {
        guard code == noErr else {
            throw CrispAudioWire.Failure(
                reason: String(localized: "\(operation) failed (\(code)). Check System Settings → Privacy & Security → System Audio Recording.")
            )
        }
    }
}

@available(macOS 14.2, *)
final class CrispHardwareAudioBackend: CrispAudioBackend, @unchecked Sendable {
    private let microphone = CrispMicrophoneWriter()
    private let usage = CrispMicrophoneUsage()
    private var probeInput: CrispAudioProbeInput?
    private let capture = CrispSystemAudioCapture()
    private var microphoneStarted = false
    var onFailure: @Sendable (String) -> Void = { _ in }
    var onMicrophoneUse: @Sendable (CrispAudioWire.MicrophoneUse) -> Void = { _ in }
    func setDiagnostics(_ recorder: LagRecorder?) {
        capture.recorder = recorder; microphone.setDiagnostics(recorder)
    }

    func halHealth() -> CrispHALDriverStatus { CrispAudioDevice.healthStatus() }
    func validate() throws {} // Listening alone does not require a virtual input device.
    func start() throws {
        capture.onFailure = onFailure
        try capture.start()
        usage.start(onMicrophoneUse)
    }
    func stop() {
        if let probeInput {
            _ = probeInput.stop(analyze: false); _ = microphone.finishProbeStats()
        }
        probeInput = nil; usage.stop(); microphoneStarted = false; microphone.stop(); capture.stop()
    }
    func shutdown() {
        if let probeInput {
            _ = probeInput.stop(analyze: false); _ = microphone.finishProbeStats()
        }
        probeInput = nil; usage.stop(); microphoneStarted = false; microphone.stop(waitForMute: true); capture.stop()
    }
    func startProbeInput() throws {
        let reader = CrispAudioProbeInput()
        microphone.beginProbeStats()
        do { try reader.start(); probeInput = reader } catch { _ = microphone.finishProbeStats(); throw error }
    }
    func prepareProbeInput(_ completion: @escaping @Sendable (String?) -> Void) {
        CrispAudioProbeInput.prepare(completion)
    }
    func stopProbeInput() -> AudioProbeResult? {
        let reader = probeInput; probeInput = nil
        var result = reader?.stop()
        var stats = microphone.finishProbeStats() ?? AudioProbeStats()
        stats.halAcceptedPackets = reader?.stats?.halAcceptedPackets
        stats.halRejectedPackets = reader?.stats?.halRejectedPackets
        stats.halReadFrames = reader?.stats?.halReadFrames
        stats.halNonzeroFrames = reader?.stats?.halNonzeroFrames
        stats.halOverflowFrames = reader?.stats?.halOverflowFrames
        stats.halUnderflowFrames = reader?.stats?.halUnderflowFrames
        stats.halPrimingFrames = reader?.stats?.halPrimingFrames
        stats.halContentionFrames = reader?.stats?.halContentionFrames
        stats.halExpiredFrames = reader?.stats?.halExpiredFrames
        result?.stats = stats
        return result
    }
    func setMicrophone(_ enabled: Bool) throws {
        guard enabled else {
            if microphoneStarted { microphone.stop(); microphoneStarted = false }
            return
        }
        if enabled, !microphoneStarted {
            guard let device = CrispAudioDevice.find() else {
                let reason = String(
                    localized: """
                    Remote Microphone is unavailable; install Crisp HAL 1.0.4+ and reconnect. \
                    Listen-only audio does not require this component.
                    """
                )
                throw CrispAudioWire.Failure(reason: reason)
            }
            microphone.setFailureHandler(onFailure)
            microphone.start(device: device)
            microphoneStarted = true
        }
        if microphoneStarted { microphone.microphone(enabled) }
    }
    func flushStaleMicrophone() throws {
        // HAL already enforces its 200-ms hardware expiration failsafe; only trim
        // stale software queue entries here instead of cycling HAL generation.
        microphone.flushStale()
    }
    func microphonePCM(_ bytes: Data) { microphone.receive(bytes) }
    func downlinkPCM() -> Data {
        do { return try capture.packet() } catch { onFailure(error.localizedDescription); return CrispAudioWire.silence }
    }
    func downlinkPackets() -> [Data] {
        do { return try capture.packets() } catch { onFailure(error.localizedDescription); return [] }
    }
}
