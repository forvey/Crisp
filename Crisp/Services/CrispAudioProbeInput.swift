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

    // A self-test reads a real input device, even though its samples are
    // synthetic. Do not mistake denied input access for a silent microphone.
    static func prepare(_ completion: @escaping @Sendable (String?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(nil)
        case .notDetermined:
            DispatchQueue.main.async {
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    completion(allowed ? nil : "mini 的 Crisp 未获输入录音权限；请在系统设置 → 隐私与安全性 → 麦克风中允许后重试。")
                }
            }
        default:
            completion("mini 的 Crisp 未获输入录音权限；请在系统设置 → 隐私与安全性 → 麦克风中允许后重试。")
        }
    }

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CrispAudioWire.Failure(reason: "mini 尚未允许 Crisp 读取输入；测试未启动。")
        }
        guard device == 0, let input = CrispAudioDevice.find() else {
            throw CrispAudioWire.Failure(reason: "远程麦克风不可用或测试已启动；请确认 mini 已安装 Crisp 配套 HAL 1.0.4 及以上并重新连接")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var running: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(input, &address, 0, nil, &size, &running) == noErr, running == 0 else {
            throw CrispAudioWire.Failure(reason: "mini 有应用正在使用远程麦克风，请结束输入使用后再测试")
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
            throw CrispAudioWire.Failure(reason: "无法读取远程麦克风测试音")
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
                if CFGetTypeID(data) == CFDataGetTypeID(), CFDataGetLength(data) == MemoryLayout<CrispMicProbeStats>.size {
                    var measured = CrispMicProbeStats()
                    withUnsafeMutableBytes(of: &measured) {
                        $0.baseAddress!.copyMemory(from: CFDataGetBytePtr(data)!, byteCount: $0.count)
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
                if CFGetTypeID(data) == CFDataGetTypeID(), CFDataGetLength(data) == MemoryLayout<CrispMicBufferStats>.size {
                    var measured = CrispMicBufferStats()
                    withUnsafeMutableBytes(of: &measured) {
                        $0.baseAddress!.copyMemory(from: CFDataGetBytePtr(data)!, byteCount: $0.count)
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
