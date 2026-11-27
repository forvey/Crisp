import CryptoKit
import Foundation
import Security

enum CrispHALDriverStatus: String, Sendable {
    case unknown
    case ready
    case outdated
    case notLoaded
    case notInstalled
}

/// Optional backward-compatible LAN shared-key challenge-response auth on TCP 49555.
/// When no key is configured on Crisp, legacy SSE-CRISP-AUDIO/2 and SSE-CRISP-DIAGNOSTICS/1
/// clients connect without extra frames. When a key is set, clients must complete
/// SSE-CRISP-AUTH/1 -> SSE-CRISP-CHALLENGE/1 -> SSE-CRISP-PROOF/1 -> SSE-CRISP-AUTH-OK/1.
enum CrispAudioAuth {
    static let initPrefix = Data("SSE-CRISP-AUTH/1 ".utf8)
    static let challengePrefix = Data("SSE-CRISP-CHALLENGE/1 ".utf8)
    static let proofPrefix = Data("SSE-CRISP-PROOF/1 ".utf8)
    static let okPayload = Data("SSE-CRISP-AUTH-OK/1".utf8)
    static let nonceHexLength = 32
    static let digestHexLength = 64

    static func framed(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + payload
    }

    static func randomNonceHex(byteCount: Int = 16) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func makeInitFrame(clientNonce: String) -> Data {
        framed(initPrefix + Data(clientNonce.utf8))
    }

    static func makeChallengeFrame(serverNonce: String) -> Data {
        framed(challengePrefix + Data(serverNonce.utf8))
    }

    static func makeProofFrame(sharedKey: String, clientNonce: String, serverNonce: String) -> Data {
        let hex = proofDigestHex(sharedKey: sharedKey, clientNonce: clientNonce, serverNonce: serverNonce)
        return framed(proofPrefix + Data(hex.utf8))
    }

    static func makeOKFrame() -> Data {
        framed(okPayload)
    }

    static func parseInit(_ payload: Data) -> String? {
        guard payload.starts(with: initPrefix) else { return nil }
        let rest = Data(payload.dropFirst(initPrefix.count))
        guard rest.count == nonceHexLength, let hex = String(data: rest, encoding: .utf8),
              isLowerHex(hex) else { return nil }
        return hex
    }

    static func parseChallenge(_ payload: Data) -> String? {
        guard payload.starts(with: challengePrefix) else { return nil }
        let rest = Data(payload.dropFirst(challengePrefix.count))
        guard rest.count == nonceHexLength, let hex = String(data: rest, encoding: .utf8),
              isLowerHex(hex) else { return nil }
        return hex
    }

    static func proofDigestHex(sharedKey: String, clientNonce: String, serverNonce: String) -> String {
        let key = SymmetricKey(data: Data(sharedKey.utf8))
        let material = Data("SSE-CRISP-AUTH/1:\(clientNonce):\(serverNonce)".utf8)
        let code = HMAC<SHA256>.authenticationCode(for: material, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func verifyProof(_ payload: Data, sharedKey: String, clientNonce: String, serverNonce: String) -> Bool {
        guard !sharedKey.isEmpty, payload.starts(with: proofPrefix) else { return false }
        let rest = Data(payload.dropFirst(proofPrefix.count))
        guard rest.count == digestHexLength,
              let hex = String(data: rest, encoding: .utf8),
              let proofBytes = decodeHex(hex) else { return false }
        let key = SymmetricKey(data: Data(sharedKey.utf8))
        let material = Data("SSE-CRISP-AUTH/1:\(clientNonce):\(serverNonce)".utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(proofBytes, authenticating: material, using: key)
    }

    private static func isLowerHex(_ value: String) -> Bool {
        value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private static func decodeHex(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var output = Data(capacity: bytes.count / 2)
        for idx in stride(from: 0, to: bytes.count, by: 2) {
            guard let hi = hexValue(bytes[idx]), let lo = hexValue(bytes[idx + 1]) else { return nil }
            output.append((hi << 4) | lo)
        }
        return output
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 97...102: return byte - 87
        case 65...70: return byte - 55
        default: return nil
        }
    }
}

enum CrispAudioWire {
    static let port: UInt16 = 49555
    static let sampleRate = 24_000.0
    static let framesPerPacket = 480
    static let pcmBytes = 960
    static let hello = Data("SSE-CRISP-AUDIO/2 PCM_S16LE 24000 1 480".utf8)
    static let silence = Data(repeating: 0, count: pcmBytes)

    enum MicrophoneUse: UInt8, Sendable { case unavailable = 0, idle = 1, inUse = 2 }

    enum Message: Equatable {
        case hello
        case pcm(Data)
        case microphone(Bool)
        case microphoneUse(MicrophoneUse)
        case probe(UInt8)
        case probeReply(Data)
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
        case let .microphoneUse(use): kind = 4; payload = Data([use.rawValue])
        case let .probe(mode): kind = 5; payload = Data([mode])
        case let .probeReply(data): kind = 6; payload = data
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
                        guard (1...1024).contains(size) else {
                            throw Failure(reason: String(localized: "Invalid audio message length"))
                        }
                        length = Int(size)
                        header.removeAll(keepingCapacity: true)
                    }
                } else {
                    body.append(byte)
                    if body.count == 1, let frameLength = length {
                        let expected: Int
                        switch byte {
                        case 1: expected = CrispAudioWire.hello.count + 1
                        case 2: expected = pcmBytes + 1
                        case 3...5: expected = 2
                        case 6: expected = frameLength
                        default: expected = 0
                        }
                        guard expected != 0, frameLength == expected else {
                            throw Failure(reason: String(localized: "Unknown audio kind or invalid payload length"))
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
                guard payload == CrispAudioWire.hello else {
                    throw Failure(reason: String(localized: "Audio protocol/version or PCM format mismatch"))
                }
                return .hello
            case 2:
                guard payload.count == pcmBytes else {
                    throw Failure(reason: String(localized: "PCM payload must contain exactly 960 bytes"))
                }
                return .pcm(payload)
            case 3:
                guard payload.count == 1, let value = payload.first, value <= 1 else {
                    throw Failure(reason: String(localized: "Invalid microphone control payload"))
                }
                return .microphone(value == 1)
            case 4:
                guard payload.count == 1, let value = payload.first, let use = MicrophoneUse(rawValue: value) else {
                    throw Failure(reason: String(localized: "Invalid microphone-use payload"))
                }
                return .microphoneUse(use)
            case 5:
                guard payload.count == 1, let mode = payload.first, mode <= 2 else {
                    throw Failure(reason: String(localized: "Invalid audio test mode"))
                }
                return .probe(mode)
            case 6:
                guard !payload.isEmpty else {
                    throw Failure(reason: String(localized: "Empty audio test result"))
                }
                return .probeReply(payload)
            default:
                throw Failure(reason: String(localized: "Unknown audio message kind"))
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
        case probe(UInt8)
    }

    mutating func receive(_ message: CrispAudioWire.Message, now: TimeInterval) throws -> Action? {
        if !handshaken {
            guard message == .hello else {
                throw CrispAudioWire.Failure(reason: String(localized: "Client hello must be the first message"))
            }
            handshaken = true
            microphoneEnabled = false
            return .replyHello
        }
        switch message {
        case .hello:
            throw CrispAudioWire.Failure(reason: String(localized: "Repeated hello is not permitted"))
        case .microphoneUse, .probeReply:
            throw CrispAudioWire.Failure(reason: String(localized: "Only the server may report microphone use"))
        case let .probe(mode): return .probe(mode)
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

    mutating func microphoneUseStarted(now: TimeInterval) {
        // Time spent waiting for a consumer is not a broken audio stream.
        lastMicrophonePacket = microphoneEnabled ? now : nil
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
