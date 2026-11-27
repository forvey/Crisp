import CoreAudio
import Foundation
import AVFoundation

/// An explicit self-test is a real consumer of the virtual input, just like a
/// call application. It never opens the physical microphone or changes defaults.
final class CrispAudioProbeInput {
    private var device: AudioDeviceID = 0
    private var procedure: AudioDeviceIOProcID?
    private var capture: AudioProbeCapture?
    private(set) var stats: AudioProbeStats?
    private var probingDriver = false

    private static func permissionDeniedMessage() -> String {
        String(
            localized: """
            Crisp lacks input recording permission on this Mac. Allow access in System Settings → \
            Privacy & Security → Microphone and retry.
            """
        )
    }

    // A self-test reads a real input device, even though its samples are
    // synthetic. Do not mistake denied input access for a silent microphone.
    static func prepare(_ completion: @escaping @Sendable (String?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(nil)
        case .notDetermined:
            DispatchQueue.main.async {
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    completion(allowed ? nil : permissionDeniedMessage())
                }
            }
        default:
            completion(permissionDeniedMessage())
        }
    }

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CrispAudioWire.Failure(
                reason: String(localized: "Crisp is not yet allowed to read audio input; self-test was not started.")
            )
        }
        guard device == 0, let input = CrispAudioDevice.find() else {
            throw CrispAudioWire.Failure(
                reason: String(
                    localized: "Remote Microphone is unavailable or self-test is already running; install Crisp HAL 1.0.4+ and reconnect."
                )
            )
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var running: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(input, &address, 0, nil, &size, &running) == noErr, running == 0 else {
            throw CrispAudioWire.Failure(
                reason: String(
                    localized: "Another app is currently using Remote Microphone; stop input use before running the self-test."
                )
            )
        }
        device = input
        // Keep the original probe layout; buffer statistics use a separate
        // property so older apps can still read the updated driver's counters.
        var probeAddress = AudioObjectPropertyAddress(mSelector: CRISP_MIC_PROBE,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        if AudioObjectHasProperty(input, &probeAddress) {
            var control = CrispMicProbeControl(version: 1, enabled: 1)
            do {
                try CrispAudioDevice.send(withUnsafeBytes(of: &control) { Data($0) },
                                          selector: CRISP_MIC_PROBE, device: input)
                probingDriver = true
            } catch { device = 0; throw error }
        }
        let capture = AudioProbeCapture(rate: 48000)
        self.capture = capture
        let created = AudioDeviceCreateIOProcIDWithBlock(&procedure, input, nil) { _, buffers, time, _, _ in
            guard buffers.pointee.mNumberBuffers == 1 else { capture.missedObservation(); return }
            let buffer = buffers.pointee.mBuffers
            guard buffer.mNumberChannels == 1, buffer.mDataByteSize % 4 == 0,
                  let data = buffer.mData else { capture.missedObservation(); return }
            capture.append(data.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / 4,
                           sampleTime: time.pointee.mSampleTime)
        }
        guard created == noErr, let procedure, AudioDeviceStart(input, procedure) == noErr else {
            _ = stop()
            throw CrispAudioWire.Failure(reason: String(localized: "Unable to read test tone from Remote Microphone"))
        }
    }

    func stop(analyze: Bool = true) -> AudioProbeResult? {
        if device != 0, let procedure {
            AudioDeviceStop(device, procedure)
            AudioDeviceDestroyIOProcID(device, procedure)
        }
        if device != 0, probingDriver {
            var address = AudioObjectPropertyAddress(mSelector: CRISP_MIC_PROBE,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var raw: UnsafeMutableRawPointer?
            var size = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &raw) == noErr, let raw {
                let data = Unmanaged<CFData>.fromOpaque(raw).takeRetainedValue()
                if CFGetTypeID(data) == CFDataGetTypeID(), CFDataGetLength(data) == MemoryLayout<CrispMicProbeStats>.size,
                   let source = CFDataGetBytePtr(data) {
                    var measured = CrispMicProbeStats()
                    withUnsafeMutableBytes(of: &measured) { bytes in
                        bytes.baseAddress?.copyMemory(from: source, byteCount: bytes.count)
                    }
                    if measured.version == 1 {
                        stats = AudioProbeStats(halAcceptedPackets: measured.acceptedPackets,
                            halRejectedPackets: measured.rejectedPackets, halReadFrames: measured.readFrames,
                            halNonzeroFrames: measured.nonzeroFrames)
                    }
                }
            }
            // Optional 1.0.4 extension; the v1 property remains readable by
            // older apps. Missing extension does not mean zero buffer damage.
            address.mSelector = CRISP_MIC_BUFFER_STATS
            raw = nil; size = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
            if AudioObjectHasProperty(device, &address),
               AudioObjectGetPropertyData(device, &address, 0, nil, &size, &raw) == noErr, let raw {
                let data = Unmanaged<CFData>.fromOpaque(raw).takeRetainedValue()
                if CFGetTypeID(data) == CFDataGetTypeID(), CFDataGetLength(data) == MemoryLayout<CrispMicBufferStats>.size,
                   let source = CFDataGetBytePtr(data) {
                    var measured = CrispMicBufferStats()
                    withUnsafeMutableBytes(of: &measured) { bytes in
                        bytes.baseAddress?.copyMemory(from: source, byteCount: bytes.count)
                    }
                    if measured.version == 1 {
                        if stats == nil { stats = AudioProbeStats() }
                        stats?.halOverflowFrames = measured.overflowFrames
                        stats?.halUnderflowFrames = measured.underflowFrames
                        stats?.halPrimingFrames = measured.primingFrames
                        stats?.halContentionFrames = measured.contentionFrames
                        stats?.halExpiredFrames = measured.expiredFrames
                    }
                }
            }
            var control = CrispMicProbeControl(version: 1, enabled: 0)
            try? CrispAudioDevice.send(withUnsafeBytes(of: &control) { Data($0) },
                                       selector: CRISP_MIC_PROBE, device: device)
        }
        probingDriver = false
        device = 0; procedure = nil
        let capture = self.capture; self.capture = nil
        return analyze ? capture?.finish() : nil
    }
}
