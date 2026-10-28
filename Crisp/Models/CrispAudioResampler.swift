import AVFoundation

/// Stateful streaming sample-rate conversion. No physical input/output nodes are opened.
final class CrispAudioResampler {
    private let source: AVAudioFormat
    private let destination: AVAudioFormat
    private let converter: AVAudioConverter

    init(from: Double, to: Double) throws {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let conversion = AVAudioConverter(from: input, to: output) else {
            throw CrispAudioWire.Failure(reason: "Unsupported audio sample rate")
        }
        source = input
        destination = output
        converter = conversion
        converter.primeMethod = .none
    }

    func convert(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: destination,
                frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * destination.sampleRate / source.sampleRate)) + 64)
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else {
            throw error ?? CrispAudioWire.Failure(reason: "Audio resampling failed")
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
