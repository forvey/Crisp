import Foundation
import Darwin

/// Diagnostic tone IDs change every 20 ms. Unlike a constant sine, missing,
/// repeated and silent spans can be distinguished after the real audio output.
enum AudioProbeSignal {
    static func pcm(_ sequence: Int) -> Data {
        let frequency = Double(4 + sequence % 64) * 100
        var data = Data(capacity: 960)
        for n in 0..<480 {
            let sample = Int16((sin(2 * .pi * frequency * Double(n) / 24000) * 2600).rounded())
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 255)); data.append(UInt8(bits >> 8))
        }
        return data
    }
}

struct AudioProbeResult: Codable, Equatable, Sendable {
    var seconds = 0.0
    var signalMS = 0
    var longestGapMS = 0
    var missingMS = 0
    var repeatedMS = 0
    var observationLost = 0

    var text: String {
        let verdict: String
        if observationLost > 0 { verdict = "采样不完整，不能判定通过" }
        else if seconds < 12 || signalMS < 6000 { verdict = "有效测试采样不足，不能判定通过" }
        else if longestGapMS >= 30 || missingMS > 0 || repeatedMS > 0 { verdict = "检测到音频不连续" }
        else { verdict = "本次未检测到 ≥30 ms 断音或测试音跳段/重复" }
        return "\(verdict)；有效信号 \(signalMS) ms，最长断音 \(longestGapMS) ms，跳段约 \(missingMS) ms，重复约 \(repeatedMS) ms，观察缺口 \(observationLost)"
    }

    static func analyze(_ samples: [Float], rate: Double, lost: Int) -> Self {
        let width = Int((rate / 100).rounded()) // 10-ms observations, any hardware sample rate.
        guard width > 0 else { return Self(observationLost: lost + 1) }
        let coefficients = (0..<64).map { 2 * cos(2 * .pi * Double(4 + $0) * 100 / rate) }
        var result = Self(seconds: Double(samples.count) / rate, observationLost: lost)
        var previous: Int?
        var gap = 0, same = 0
        for start in stride(from: 0, through: max(-1, samples.count - width), by: width) {
            let energy = samples[start..<start + width].reduce(0.0) { $0 + Double($1 * $1) }
            var winner: Int?, peak = 0.0
            if energy / Double(width) > 0.00001 {
                for id in 0..<64 {
                    var a = 0.0, b = 0.0
                    for index in start..<start + width {
                        let value = Double(samples[index]) + coefficients[id] * a - b
                        b = a; a = value
                    }
                    let power = a * a + b * b - coefficients[id] * a * b
                    if power > peak { peak = power; winner = id }
                }
                if peak * 2 / (Double(width) * energy) < 0.7 { winner = nil }
            }
            guard let id = winner else {
                if previous != nil { gap += 10; result.longestGapMS = max(result.longestGapMS, gap) }
                continue
            }
            result.signalMS += 10
            if let previous {
                let step = (id - previous + 64) % 64
                if step == 0 {
                    same += 10
                    if same > 40 { result.repeatedMS += 10 }
                } else {
                    // Modulo IDs are unambiguous for jumps below 1.28 seconds.
                    // Longer failures still appear as output gaps / insufficient signal.
                    if step > 1 { result.missingMS += (step - 1) * 20 }
                    same = 10
                }
            } else { same = 10 }
            previous = id; gap = 0
        }
        return result
    }
}

/// Allocated only during an explicit test. The audio callback only copies into
/// bounded memory with trylock; no analysis, files or network on the audio thread.
final class AudioProbeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let samples: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let rate: Double
    private var count = 0
    private var expected: Double?
    private var lost = 0
    private var skipped: Int32 = 0
    private var active = true
    init(rate: Double) {
        self.rate = rate; capacity = Int(rate * 20)
        samples = .allocate(capacity: capacity)
    }
    deinit { samples.deallocate() }
    func append(_ source: UnsafePointer<Float>, count frames: Int, stride: Int = 1, sampleTime: Double) {
        guard lock.try() else { OSAtomicIncrement32Barrier(&skipped); return }
        defer { lock.unlock() }
        guard active, frames > 0 else { return }
        guard sampleTime.isFinite else { lost += 1; return }
        if let expected, abs(sampleTime - expected) > 2 { lost += 1 }
        expected = sampleTime + Double(frames)
        guard count + frames <= capacity else { lost += 1; return }
        if stride == 1 { samples.advanced(by: count).update(from: source, count: frames) }
        else { for n in 0..<frames { samples[count + n] = source[n * stride] } }
        count += frames
    }
    func finish() -> AudioProbeResult {
        lock.lock(); active = false
        let data = Array(UnsafeBufferPointer(start: samples, count: count)), dropped = lost + Int(OSAtomicAdd32Barrier(0, &skipped))
        lock.unlock()
        return AudioProbeResult.analyze(data, rate: rate, lost: dropped)
    }
}

struct AudioProbeReply: Codable, Sendable {
    let mode: UInt8 // 1 speaker, 2 virtual microphone
    let state: String // ready, result, error
    var result: AudioProbeResult?
    var error: String?
}
