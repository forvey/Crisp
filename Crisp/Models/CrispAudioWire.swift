import Foundation

enum CrispAudioWire {
    static let port: UInt16 = 49555
    static let sampleRate = 24_000.0
    static let framesPerPacket = 480
    static let pcmBytes = 960
    static let hello = Data("SSE-CRISP-AUDIO/1 PCM_S16LE 24000 1 480".utf8)
    static let silence = Data(repeating: 0, count: pcmBytes)

    enum Message: Equatable {
        case hello
        case pcm(Data)
        case microphone(Bool)
    }

    struct Failure: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func encode(_ message: Message) -> Data {
        let kind: UInt8
        let payload: Data
        switch message {
        case .hello: kind = 1; payload = hello
        case let .pcm(bytes): kind = 2; payload = bytes
        case let .microphone(enabled): kind = 3; payload = Data([enabled ? 1 : 0])
        }
        let length = UInt32(payload.count + 1)
        var result = Data([UInt8(length >> 24), UInt8((length >> 16) & 255),
                           UInt8((length >> 8) & 255), UInt8(length & 255), kind])
        result.append(payload)
        return result
    }

    /// Incremental framing, with at most one 1024-byte body retained regardless of the
    /// size of an incoming chunk. TCP reads may contain partial or many complete messages.
    struct Decoder {
        private var header: [UInt8] = []
        private var body: [UInt8] = []
        private var length: Int?

        mutating func receive(_ data: Data) throws -> [Message] {
            var messages: [Message] = []
            for byte in data {
                if length == nil {
                    header.append(byte)
                    if header.count == 4 {
                        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        guard (1...1024).contains(size) else { throw Failure(reason: "Invalid audio message length") }
                        length = Int(size)
                        header.removeAll(keepingCapacity: true)
                    }
                } else {
                    body.append(byte)
                    if body.count == 1 {
                        let expected = byte == 1 ? CrispAudioWire.hello.count + 1 : byte == 2 ? pcmBytes + 1 : byte == 3 ? 2 : 0
                        guard expected != 0, length == expected else {
                            throw Failure(reason: "Unknown audio kind or invalid payload length")
                        }
                    }
                    if body.count == length {
                        messages.append(try Self.parse(body))
                        body.removeAll(keepingCapacity: true)
                        length = nil
                    }
                }
            }
            return messages
        }

        private static func parse(_ bytes: [UInt8]) throws -> Message {
            let payload = Data(bytes.dropFirst())
            switch bytes[0] {
            case 1:
                guard payload == CrispAudioWire.hello else { throw Failure(reason: "Audio protocol/version or PCM format mismatch") }
                return .hello
            case 2:
                guard payload.count == pcmBytes else { throw Failure(reason: "PCM payload must contain exactly 960 bytes") }
                return .pcm(payload)
            case 3:
                guard payload.count == 1, let value = payload.first, value <= 1 else {
                    throw Failure(reason: "Invalid microphone control payload")
                }
                return .microphone(value == 1)
            default:
                throw Failure(reason: "Unknown audio message kind")
            }
        }
    }
}

struct CrispAudioSession {
    private(set) var handshaken = false
    private(set) var microphoneEnabled = false
    private(set) var lastMicrophonePacket: TimeInterval?

    enum Action: Equatable {
        case replyHello
        case microphone(Bool)
        case microphonePCM(Data)
    }

    mutating func receive(_ message: CrispAudioWire.Message, now: TimeInterval) throws -> Action? {
        if !handshaken {
            guard message == .hello else { throw CrispAudioWire.Failure(reason: "Client hello must be the first message") }
            handshaken = true
            microphoneEnabled = false
            return .replyHello
        }
        switch message {
        case .hello:
            throw CrispAudioWire.Failure(reason: "Repeated hello is not permitted")
        case let .microphone(enabled):
            microphoneEnabled = enabled
            lastMicrophonePacket = enabled ? now : nil
            return .microphone(enabled)
        case let .pcm(bytes):
            guard microphoneEnabled else { return nil }
            lastMicrophonePacket = now
            return .microphonePCM(bytes)
        }
    }

    func microphoneExpired(now: TimeInterval) -> Bool {
        microphoneEnabled && lastMicrophonePacket.map { now - $0 >= 0.2 } == true
    }

    mutating func disconnect() {
        self = Self()
    }
}

enum CrispAudioPCM {
    static func floats(_ bytes: Data) -> [Float] {
        let raw = Array(bytes)
        return stride(from: 0, to: raw.count - 1, by: 2).map {
            Float(Int16(bitPattern: UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8)) / 32768
        }
    }

    static func bytes(_ samples: [Float]) -> Data {
        var result = Data(capacity: samples.count * 2)
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let value = Int16(max(-32768, min(32767, (finite * 32768).rounded())))
            let bits = UInt16(bitPattern: value)
            result.append(UInt8(bits & 255))
            result.append(UInt8(bits >> 8))
        }
        return result
    }
}
