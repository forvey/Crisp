import AppKit

/// Only an explicit short-test command displays this window. Nothing is drawn
/// during ordinary diagnostics. Independent timeout also closes a lost session.
@MainActor final class CrispLagPattern {
    static let shared = CrispLagPattern()
    private var window: NSWindow?
    private var id = ""
    private var expiry: Timer?
    private var motionTimer: Timer?
    private var motionToken: Int?
    private var frames: [LagMotionFrame] = []
    private var motionCompletion: ((LagMotionSource) -> Void)?
    private var motionBegan = 0.0

    func show(id: String, sequence: Int) {
        guard motionToken == nil else { return }
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
            MainActor.assumeIsolated { self?.close(id: id) }
        }
    }

    func close(id: String) {
        guard self.id == id else { return }
        finishMotion(completed: false)
        expiry?.invalidate(); expiry = nil
        window?.close(); window = nil; self.id = ""
    }

    /// The animation runs locally at 30 fps, not in response to per-frame TCP
    /// commands. Evidence records draw() completion, NOT timer firings or proof
    /// of compositor/encoder output. No timer exists before this explicit call.
    func startMotion(id: String, token: Int, completion: @escaping (LagMotionSource) -> Void) {
        guard motionToken == nil else { return }
        show(id: id, sequence: 0)
        guard let view = window?.contentView as? PatternView else { return }
        expiry?.invalidate()
        motionToken = token; motionCompletion = completion; frames = []
        frames.reserveCapacity(512)
        view.motionToken = token
        view.frameDidDraw = { [weak self] number in
            guard let self, self.id == id, self.motionToken == token, self.frames.count < 512 else { return }
            self.frames.append(LagMotionFrame(number: number, stamp: LagRecorder.now()))
        }
        let began = LagRecorder.now()
        motionBegan = began
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            // Main run-loop timer; use the actor directly, without enqueueing
            // stale Tasks that could advance a later test after cancellation.
            MainActor.assumeIsolated {
                guard let self, self.id == id, self.motionToken == token else { return }
                guard LagRecorder.now() - began < 15 else { self.finishMotion(completed: true); return }
                (self.window?.contentView as? PatternView)?.advanceMotion()
            }
        }
        motionTimer = timer; RunLoop.main.add(timer, forMode: .common)
        let expiry = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.id == id, self.motionToken == token else { return }
                self.finishMotion(completed: true)
            }
        }
        self.expiry = expiry; RunLoop.main.add(expiry, forMode: .common)
        view.advanceMotion()
    }

    func stopMotion(id: String, token: Int) {
        guard self.id == id, motionToken == token else { return }
        finishMotion(completed: false)
    }

    private func finishMotion(completed: Bool) {
        guard let token = motionToken else { return }
        motionTimer?.invalidate(); motionTimer = nil
        expiry?.invalidate(); expiry = nil
        let result = LagMotionSource(token: token, frames: frames, completed: completed,
                                    started: motionBegan, ended: LagRecorder.now())
        let completion = motionCompletion
        motionToken = nil; motionCompletion = nil; frames = []
        window?.close(); window = nil; id = ""
        completion?(result)
    }

    private final class PatternView: NSView {
        var sequence = 0 { didSet { needsDisplay = true } }
        var motionToken: Int?
        var frameDidDraw: ((Int) -> Void)?
        private var frame = 0
        private var advancing = false

        func advanceMotion() {
            guard frame < 512 else { return }
            advancing = true; needsDisplay = true
            displayIfNeeded()
        }
        override func draw(_ dirtyRect: NSRect) {
            let record = motionToken != nil && advancing
            if record { frame += 1; advancing = false }
            let value = motionToken.map { ($0 << 12) | frame } ?? sequence
            let bits = motionToken == nil ? 8 : 24
            NSColor.black.setFill(); bounds.fill()
            let width = bounds.width / Double(bits + 4)
            let codeHeight = motionToken == nil ? bounds.height : bounds.height / 2
            for row in 0..<2 {
                for col in 0..<(bits + 4) {
                    let color: NSColor
                    if col < 2 {
                        color = .magenta
                    } else if col >= bits + 2 {
                        color = .cyan
                    } else {
                        color = (((value >> (col - 2)) & 1) == row) ? .white : .black
                    }
                    color.setFill()
                    NSRect(x: Double(col) * width, y: Double(row) * codeHeight / 2,
                           width: width, height: codeHeight / 2).fill()
                }
            }
            if motionToken != nil {
                // Moving bars exercise continuous image changes, not just a
                // number counter. This is a small synthetic scene, not video.
                for index in 0..<10 {
                    NSColor(white: index % 2 == 0 ? 0.9 : 0.3, alpha: 1).setFill()
                    let x = (Double(index) * bounds.width / 10 + Double(frame) * 4).truncatingRemainder(dividingBy: bounds.width)
                    NSRect(x: x, y: codeHeight + 8, width: 20, height: bounds.height - codeHeight - 16).fill()
                }
            }
            if record { frameDidDraw?(frame) }
        }
    }
}
