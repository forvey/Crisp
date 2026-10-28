import CoreAudio
import Foundation

/// Metadata only: never starts an audio device, opens an input stream or
/// changes a default. Used before/after installation to verify real HAL loading.
@main
struct RemoteAudioDeviceInventory {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var key = address(selector)
        var value: UnsafeMutableRawPointer?
        var bytes = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &key, 0, nil, &bytes, &value) == noErr, let value else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeRetainedValue() as String
    }

    static func defaultUID(_ selector: AudioObjectPropertySelector) -> String? {
        var key = address(selector)
        var id: AudioObjectID = 0
        var bytes = UInt32(MemoryLayout.size(ofValue: id))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &bytes, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    static func integer(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var key = address(selector, scope)
        var value: UInt32 = 0
        var bytes = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(device, &key, 0, nil, &bytes, &value) == noErr else { return nil }
        return value
    }

    static func channels(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var key = address(kAudioDevicePropertyStreamConfiguration, scope)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &key, 0, nil, &bytes) == noErr,
              bytes >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(device, &key, 0, nil, &bytes, data) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func main() throws {
        var key = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &key, 0, nil, &bytes) == noErr else { throw Failure() }
        var ids = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &key, 0, nil, &bytes, &ids) == noErr else { throw Failure() }
        var microphone: [String: Any] = ["loaded": false]
        for id in ids where string(id, kAudioDevicePropertyDeviceUID) == "com.forvey.Crisp.RemoteMicrophone" {
            microphone = ["loaded": true, "id": id, "uid": string(id, kAudioDevicePropertyDeviceUID) ?? "",
                          "name": string(id, kAudioObjectPropertyName) ?? "",
                          "inputSelectable": integer(id, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                                     kAudioObjectPropertyScopeInput) == 1,
                          "hidden": integer(id, kAudioDevicePropertyIsHidden) == 1,
                          "inputChannels": channels(id, kAudioObjectPropertyScopeInput),
                          "outputChannels": channels(id, kAudioObjectPropertyScopeOutput)]
            var statusKey = address(0x636d7374)
            var raw: UnsafeMutableRawPointer?
            bytes = UInt32(MemoryLayout.size(ofValue: raw))
            if AudioObjectGetPropertyData(id, &statusKey, 0, nil, &bytes, &raw) == noErr, let raw {
                let status = Unmanaged<CFData>.fromOpaque(raw).takeRetainedValue()
                let data = status as Data
                microphone["statusBytes"] = Array(data)
                microphone["versionValid"] = data.count == 16 && Array(data.prefix(4)) == [1, 0, 0, 0]
                microphone["enabled"] = data.count >= 8 && data[4..<8].contains { $0 != 0 }
            }
        }
        let report: [String: Any] = ["microphone": microphone,
                                   "defaultInputUID": defaultUID(kAudioHardwarePropertyDefaultInputDevice) ?? "",
                                   "defaultOutputUID": defaultUID(kAudioHardwarePropertyDefaultOutputDevice) ?? "",
                                   "audioIOStarted": false]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }

    struct Failure: Error {}
}
