import AppKit

/// Only an explicit short-test command displays this window. Nothing is drawn
/// during ordinary diagnostics. Independent timeout also closes a lost session.
@MainActor final class CrispLagPattern {
    static let shared = CrispLagPattern()
    private var window: NSWindow?
    private var id = ""
    private var expiry: Timer?

    func show(id: String, sequence: Int) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "共享画面短测 · 自动关闭"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentView = PatternView()
            // On a multi-display mini the shared display may not be the main
            // one. Use the screen where the remote pointer was left by the user.
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
                let frame = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: frame.midX - 300, y: frame.midY - 120))
            } else { window.center() }
            window.orderFrontRegardless()
            self.window = window
        }
        self.id = id
        (window?.contentView as? PatternView)?.sequence = sequence
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close(id: id) }
        }
    }

    func close(id: String) {
        guard self.id == id else { return }
        expiry?.invalidate(); expiry = nil
        window?.close(); window = nil; self.id = ""
    }

    private final class PatternView: NSView {
        var sequence = 0 { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.setFill(); bounds.fill()
            let width = bounds.width / 12
            for row in 0..<2 {
                for col in 0..<12 {
                    let color: NSColor
                    if col < 2 { color = .magenta } else if col >= 10 { color = .cyan }
                    else { color = (((sequence >> (col - 2)) & 1) == row) ? .white : .black }
                    color.setFill()
                    NSRect(x: Double(col) * width, y: Double(row) * bounds.height / 2,
                           width: width, height: bounds.height / 2).fill()
                }
            }
        }
    }
}
