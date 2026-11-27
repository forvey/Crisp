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
            throw CrispAudioWire.Failure(reason: String(localized: "Unsupported audio sample rate"))
        }
        source = input
        destination = output
        converter = conversion
        converter.primeMethod = .none
    }

    func convert(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let inputChannel = input.floatChannelData?[0],
              let output = AVAudioPCMBuffer(pcmFormat: destination,
                frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * destination.sampleRate / source.sampleRate)) + 64),
              let outputChannel = output.floatChannelData?[0]
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                inputChannel.update(from: base, count: samples.count)
            }
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else {
            throw error ?? CrispAudioWire.Failure(reason: String(localized: "Audio resampling failed"))
        }
        return Array(UnsafeBufferPointer(start: outputChannel, count: Int(output.frameLength)))
    }
}
