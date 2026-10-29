import CoreAudio
import Foundation

/// Exercise the production writer/resampler. Replace only HAL property IPC;
/// no device, TCC prompt or installed driver is opened. A gate deterministically
/// holds the worker while a network callback delivers a whole burst.
private final class WriterHAL: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let written = DispatchSemaphore(value: 0)
    let writeEntered = DispatchSemaphore(value: 0)
    let releaseWrite = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var gated = false
    private var gateFirstWrite: Bool
    private var samples: [Float] = []
    init(gateFirstWrite: Bool = false) { self.gateFirstWrite = gateFirstWrite }
    func send(_ data: Data, selector: AudioObjectPropertySelector, device: AudioDeviceID) throws {
        if selector == CrispAudioDevice.control {
            var control = CrispMicControl()
            _ = withUnsafeMutableBytes(of: &control) { data.copyBytes(to: $0) }
            if control.enabled == 1 && !gated {
                gated = true; entered.signal()
                precondition(release.wait(timeout: .now() + 2) == .success)
            }
        } else if selector == CrispAudioDevice.write {
            var packet = CrispMicPacket()
            _ = withUnsafeMutableBytes(of: &packet) { data.copyBytes(to: $0) }
            let middle = withUnsafeBytes(of: &packet.samples) { $0.bindMemory(to: Float.self)[480] }
            lock.lock(); samples.append(middle); lock.unlock()
            if gateFirstWrite {
                gateFirstWrite = false; writeEntered.signal()
                precondition(releaseWrite.wait(timeout: .now() + 2) == .success)
            }
            written.signal()
        }
    }
    func values() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }
}

@main struct MicrophoneWriterTests {
    static func main() {
        // Seven 20-ms packets arriving together must all reach the driver, in
        // order. A 20-packet burst exceeds the explicit 15-packet budget: only
        // its oldest five may be dropped, and those drops must be reported.
        for count in [7, 20] {
            let hal = WriterHAL()
            let writer = CrispMicrophoneWriter { try hal.send($0, selector: $1, device: $2) }
            writer.beginProbeStats(); writer.start(device: 1); writer.microphone(true)
            precondition(hal.entered.wait(timeout: .now() + 2) == .success)
            for sequence in 1...count {
                writer.receive(CrispAudioPCM.bytes([Float](repeating: Float(sequence) / 100, count: 480)))
            }
            hal.release.signal()
            let expected = min(count, 15)
            for _ in 0..<expected { precondition(hal.written.wait(timeout: .now() + 2) == .success) }
            let stats = writer.finishProbeStats()!
            writer.stop(waitForMute: true)
            precondition(stats.queueDrops == max(0, count - 15) && stats.staleDrops == 0)
            precondition(stats.halWrites == expected && stats.pendingPackets == 0)
            let values = hal.values()
            precondition(values.count == expected)
            for (index, value) in values.enumerated() {
                precondition(abs(value - Float(count - expected + index + 1) / 100) < 0.001)
            }
        }
        // Closing while the HAL control write is in flight must discard the
        // queued speech. Late receive callbacks cannot reactivate the writer.
        let hal = WriterHAL()
        let writer = CrispMicrophoneWriter { try hal.send($0, selector: $1, device: $2) }
        writer.beginProbeStats(); writer.start(device: 1); writer.microphone(true)
        precondition(hal.entered.wait(timeout: .now() + 2) == .success)
        for _ in 0..<7 { writer.receive(CrispAudioWire.silence) }
        writer.stop()
        hal.release.signal()
        let stats = writer.finishProbeStats()!
        writer.receive(CrispAudioWire.silence)
        writer.stop(waitForMute: true)
        precondition(hal.values().isEmpty && stats.pendingPackets == 7 && stats.halWrites == 0)
        // A stop during a PCM write cannot undo that one in-flight write, but
        // must prevent the other six snapshot packets from reaching the HAL
        // and report them as unwritten, not silently lose the accounting.
        let interruptedHAL = WriterHAL(gateFirstWrite: true)
        let interrupted = CrispMicrophoneWriter { try interruptedHAL.send($0, selector: $1, device: $2) }
        interrupted.beginProbeStats(); interrupted.start(device: 1); interrupted.microphone(true)
        precondition(interruptedHAL.entered.wait(timeout: .now() + 2) == .success)
        for _ in 0..<7 { interrupted.receive(CrispAudioWire.silence) }
        interruptedHAL.release.signal()
        precondition(interruptedHAL.writeEntered.wait(timeout: .now() + 2) == .success)
        interrupted.stop(); interruptedHAL.releaseWrite.signal()
        let interruptedStats = interrupted.finishProbeStats()!
        interrupted.stop(waitForMute: true)
        precondition(interruptedHAL.values().count == 1)
        precondition(interruptedStats.pendingPackets == 6 && interruptedStats.halWrites == 1)
        print("Microphone writer passed: seven-packet burst, bounded overload, ordered PCM and stop/late callback isolation; no devices")
    }
}
