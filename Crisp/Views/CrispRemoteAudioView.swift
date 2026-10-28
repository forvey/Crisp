import AppKit
import SwiftUI

@MainActor
final class CrispRemoteAudioService: ObservableObject {
    static let shared = CrispRemoteAudioService()
    @Published private(set) var state = CrispAudioServerState()
    private var server: CrispAudioServer?
    private var sleepObserver: NSObjectProtocol?
    private var generation = UUID()

    func start() {
        guard !state.listening else { return }
        stop()
        guard #available(macOS 14.2, *) else {
            state.error = String(localized: "Remote audio requires macOS 14.2 or later.")
            return
        }
        let backend = CrispHardwareAudioBackend()
        let epoch = generation
        let transport = CrispAudioServer(backend: backend) { [weak self] value in
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                self.state = value
            }
        }
        server = transport
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop() } }
        transport.start()
    }

    func stop() {
        generation = UUID()
        server?.stop()
        server = nil
        state = CrispAudioServerState()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
    }

    func shutdown() { server?.shutdown(); server = nil }
}

/// Inline with the other Crisp settings: one switch, with status only while
/// active or after an error. Component setup belongs to the installer.
struct CrispRemoteAudioRow: View {
    @ObservedObject private var audio = CrispRemoteAudioService.shared

    private var status: String? {
        if let error = audio.state.error { return error }
        guard audio.state.listening else { return nil }
        if audio.state.diagnosing { return String(localized: "Diagnostics active (up to 60 s)") }
        if audio.state.microphone { return String(localized: "Microphone On") }
        return audio.state.connected ? String(localized: "Connected") : String(localized: "Waiting for Connection")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: Binding(
                get: { audio.state.listening },
                set: { if $0 { audio.start() } else { audio.stop() } }
            )) {
                HStack(spacing: 8) {
                    MenuItemIcon(systemName: "speaker.wave.2", color: .blue, active: audio.state.listening)
                        .accessibilityHidden(true)
                    Text("Speaker").font(.body)
                    Spacer()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundColor(audio.state.error == nil ? .secondaryReadable : .red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 46)
                    .padding(.trailing, 12)
                    .padding(.bottom, 3)
            }
        }
    }
}
