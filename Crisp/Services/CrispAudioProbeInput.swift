import CoreAudio
import Foundation

/// An explicit self-test is a real consumer of the virtual input, just like a
/// call application. It never opens the physical microphone or changes defaults.
final class CrispAudioProbeInput {
    private var device: AudioDeviceID = 0
    private var procedure: AudioDeviceIOProcID?
    private var capture: AudioProbeCapture?

    func start() throws {
        guard device == 0, let input = CrispAudioDevice.find() else {
            throw CrispAudioWire.Failure(reason: "远程麦克风未安装或测试已启动")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var running: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(input, &address, 0, nil, &size, &running) == noErr, running == 0 else {
            throw CrispAudioWire.Failure(reason: "mini 有应用正在使用远程麦克风，请结束输入使用后再测试")
        }
        device = input
        let capture = AudioProbeCapture(rate: 48000)
        self.capture = capture
        let created = AudioDeviceCreateIOProcIDWithBlock(&procedure, input, nil) { _, buffers, time, _, _ in
            guard buffers.pointee.mNumberBuffers == 1 else { return }
            let buffer = buffers.pointee.mBuffers
            guard buffer.mNumberChannels == 1, let data = buffer.mData else { return }
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
        device = 0; procedure = nil
        let capture = self.capture; self.capture = nil
        return analyze ? capture?.finish() : nil
    }
}
