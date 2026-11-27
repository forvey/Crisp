import AppKit
import os
import SwiftUI

/// Persists an optional LAN shared key for TCP 49555 in Application Support with 0600 permissions,
/// avoiding Keychain ACL re-prompts on ad-hoc rebuilds while keeping the secret out of UserDefaults.
enum CrispRemoteAudioKeyStore {
    private static let cachedKey = OSAllocatedUnfairLock<String?>(initialState: nil)
    private static let loaded = OSAllocatedUnfairLock<Bool>(initialState: false)

    private static var keyFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Crisp", isDirectory: true).appendingPathComponent("remote-audio-auth.key")
    }

    nonisolated static func load() -> String? {
        if loaded.withLock({ $0 }) {
            return cachedKey.withLock { $0 }
        }
        let value = readFromDisk()
        cachedKey.withLock { $0 = value }
        loaded.withLock { $0 = true }
        return value
    }

    @MainActor
    static func save(_ rawKey: String?) {
        let normalized = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = (normalized?.isEmpty == false) ? normalized : nil
        cachedKey.withLock { $0 = effective }
        loaded.withLock { $0 = true }
        guard let url = keyFileURL else { return }
        if let effective {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(effective.utf8)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func readFromDisk() -> String? {
        guard let url = keyFileURL,
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }
}

@MainActor
final class CrispRemoteAudioService: ObservableObject {
    static let shared = CrispRemoteAudioService()
    @Published private(set) var state = CrispAudioServerState()
    @Published private(set) var halStatus: CrispHALDriverStatus = .unknown
    @Published private(set) var sharedKey: String? = CrispRemoteAudioKeyStore.load()
    private var server: CrispAudioServer?
    private var sleepObserver: NSObjectProtocol?
    private var generation = UUID()

    private init() {
        refreshHALStatus()
    }

    var hasSharedKey: Bool { sharedKey != nil }

    func refreshHALStatus() {
        halStatus = CrispAudioDevice.healthStatus()
    }

    func setSharedKey(_ value: String?) {
        CrispRemoteAudioKeyStore.save(value)
        sharedKey = CrispRemoteAudioKeyStore.load()
    }

    func generateSharedKey() -> String {
        let key = CrispAudioAuth.randomNonceHex(byteCount: 12)
        setSharedKey(key)
        return key
    }

    func start() {
        guard !state.listening else { return }
        stop()
        refreshHALStatus()
        guard #available(macOS 14.2, *) else {
            state.error = String(localized: "Remote audio requires macOS 14.2 or later.")
            return
        }
        let backend = CrispHardwareAudioBackend()
        let epoch = generation
        let transport = CrispAudioServer(backend: backend, sharedKey: { CrispRemoteAudioKeyStore.load() }) { [weak self] value in
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                self.state = value
                if value.halStatus != .unknown {
                    self.halStatus = value.halStatus
                }
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
        refreshHALStatus()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
    }

    func shutdown() { server?.shutdown(); server = nil }
}

/// Directly accessible in the main panel: one switch, with peer/mic/HAL status
/// and optional LAN shared-key configuration.
struct CrispRemoteAudioRow: View {
    @ObservedObject private var audio = CrispRemoteAudioService.shared
    @State private var isHovered = false
    @State private var showKeyEditor = false
    @State private var keyDraft = ""
    @FocusState private var keyFocused: Bool

    private var connectionStatus: String? {
        guard audio.state.listening else { return nil }
        let peerLabel = audio.state.peer.isEmpty ? nil : audio.state.peer
        if audio.state.connected {
            let base = peerLabel.map { String(localized: "Connected · \($0)") } ?? String(localized: "Connected")
            return "\(base) · \(microphoneLabel)"
        }
        if audio.hasSharedKey {
            return String(localized: "Waiting for Connection · Port \(Int(CrispAudioWire.port)) (Key Required)")
        }
        return String(localized: "Waiting for Connection · Port \(Int(CrispAudioWire.port))")
    }

    private var microphoneLabel: String {
        if audio.state.microphone {
            return String(localized: "Mic In Use")
        }
        switch audio.state.microphoneUse {
        case .inUse: return String(localized: "Mic Reader Waiting")
        case .idle: return String(localized: "Mic Standby")
        case .unavailable: return String(localized: "Mic Unavailable")
        }
    }

    private var halStatusText: String? {
        let status = audio.halStatus
        guard audio.state.listening || status == .outdated else { return nil }
        switch status {
        case .ready: return String(localized: "HAL Driver: Ready")
        case .outdated: return String(localized: "HAL Driver: Update to 1.0.4+ required for mic")
        case .notLoaded: return String(localized: "HAL Driver: Not loaded (listen-only)")
        case .notInstalled: return String(localized: "HAL Driver: Not installed (listen-only)")
        case .unknown: return nil
        }
    }

    private var halIsHealthy: Bool {
        audio.halStatus == .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { audio.state.listening },
                    set: { enabled in
                        guard PanelOpenGuard.allowsActivation else { return }
                        if enabled { audio.start() } else { audio.stop() }
                    }
                )) {
                    HStack(spacing: 8) {
                        MenuItemIcon(systemName: "dot.radiowaves.left.and.right", color: .blue, active: audio.state.listening)
                            .accessibilityHidden(true)
                        Text("Remote Audio").font(.body)
                        if audio.hasSharedKey {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundColor(.secondaryReadable)
                                .accessibilityLabel("LAN key enabled")
                        }
                        Spacer()
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Menu {
                    authActions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(isHovered || showKeyEditor ? 1 : 0)
                .accessibilityLabel("Remote audio options")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(isHovered)
            .onHover { isHovered = $0 }
            .contextMenu { authActions }

            if let error = audio.state.error {
                statusLine(error, color: .red)
            }
            if let connectionStatus {
                statusLine(connectionStatus, color: .secondaryReadable)
            }
            if let halStatusText {
                statusLine(halStatusText, color: halIsHealthy ? .secondaryReadable : .orange)
            }
            if audio.state.listening && audio.state.diagnosing {
                statusLine(String(localized: "Diagnostics running (up to 60 s)"), color: .blue)
            }

            if showKeyEditor {
                keyEditorCard
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
            audio.refreshHALStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            showKeyEditor = false
            keyDraft = ""
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.leading, 46)
            .padding(.trailing, 12)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private var authActions: some View {
        Button {
            let key = audio.generateSharedKey()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key, forType: .string)
        } label: {
            Label(audio.hasSharedKey ? "Rotate & Copy LAN Key" : "Enable & Copy Random LAN Key",
                  systemImage: "key.fill")
        }
        if let current = audio.sharedKey {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(current, forType: .string)
            } label: {
                Label("Copy Current LAN Key", systemImage: "doc.on.doc")
            }
        }
        Button {
            keyDraft = audio.sharedKey ?? ""
            withAnimation(.panelResize) { showKeyEditor = true } completion: { keyFocused = true }
        } label: {
            Label("Set Custom LAN Key…", systemImage: "pencil")
        }
        if audio.hasSharedKey {
            Divider()
            Button(role: .destructive) {
                audio.setSharedKey(nil)
            } label: {
                Label("Disable LAN Key", systemImage: "lock.open")
            }
        }
    }

    private var keyEditorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAN Shared Key (TCP 49555)")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Leave empty to allow unauthenticated LAN peers", text: $keyDraft)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($keyFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    withAnimation(.panelResize) { showKeyEditor = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Save") {
                    audio.setSharedKey(keyDraft)
                    withAnimation(.panelResize) { showKeyEditor = false }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
