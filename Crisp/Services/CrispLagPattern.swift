import AppKit

/// Only an explicit short-test command displays this window. Nothing is drawn
/// during ordinary diagnostics. Independent timeout also closes a lost session.
@MainActor final class CrispLagPattern {
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        weak var owner: CrispLagPattern?
        init(owner: CrispLagPattern) { self.owner = owner }
        func windowWillClose(_ notification: Notification) {
            guard let closedWindow = notification.object as? NSWindow else { return }
            owner?.handleWindowWillClose(closedWindow)
        }
    }

    static let shared = CrispLagPattern()
    private lazy var windowDelegate = WindowDelegate(owner: self)
    private var window: NSWindow?
    private var id = ""
    private var expiry: Timer?
    private var motionTimer: Timer?
    private var motionToken: Int?
    private var qualityToken: Int?
    private var qualityCompletion: (@MainActor (LagQualityReference?) -> Void)?
    private var frames: [LagMotionFrame] = []
    private var motionCompletion: ((LagMotionSource) -> Void)?
    private var motionBegan = 0.0

    func show(id: String, sequence: Int) {
        guard motionToken == nil, qualityToken == nil else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "共享画面短测 · 自动关闭"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.delegate = windowDelegate
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
        cancelQualityState()
        closeCurrentWindow()
    }

    func startQuality(id: String, token: Int, completion: @escaping @MainActor (LagQualityReference?) -> Void) {
        guard motionToken == nil, qualityToken == nil,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let mode = CGDisplayCopyDisplayMode(number.uint32Value) else {
            completion(nil)
            return
        }
        let scale = Int(screen.backingScaleFactor)
        guard Double(scale) == screen.backingScaleFactor else {
            completion(nil)
            return
        }
        let display = LagDisplay(id: number.uint32Value, width: mode.width, height: mode.height,
                                 pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                                 backingScale: screen.backingScaleFactor, refreshRate: mode.refreshRate)
        let visibleFrame = screen.visibleFrame
        closeCurrentWindow()
        self.id = id
        qualityToken = token
        qualityCompletion = completion
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reference = try? LagQualityChart.make(token: token, scale: scale, display: display)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishQualitySetup(id: id, token: token, visibleFrame: visibleFrame, reference: reference)
                }
            }
        }
    }

    private func finishQualitySetup(id: String, token: Int, visibleFrame: NSRect, reference: LagQualityReference?) {
        guard self.id == id, qualityToken == token, motionToken == nil else { return }
        guard let reference, let image = NSImage(data: reference.png) else {
            cancelQualityState()
            return
        }
        let size = NSSize(width: Double(LagQualityChart.width), height: Double(LagQualityChart.height))
        image.size = size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "画面清晰度诊断 · 结束后关闭"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = windowDelegate
        window.contentView = QualityView(image: image, size: size)
        window.setFrameOrigin(NSPoint(x: visibleFrame.midX - size.width / 2,
                                      y: visibleFrame.midY - size.height / 2))
        closeCurrentWindow()
        self.window = window
        window.orderFrontRegardless()
        window.displayIfNeeded()
        let expiry = Timer(timeInterval: 16, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(id: id) }
        }
        self.expiry?.invalidate()
        self.expiry = expiry
        RunLoop.main.add(expiry, forMode: .common)
        let completion = qualityCompletion
        qualityCompletion = nil
        completion?(reference)
    }

    private func closeCurrentWindow() {
        let current = window
        window = nil
        current?.delegate = nil
        current?.close()
    }

    private func cancelQualityState() {
        expiry?.invalidate()
        expiry = nil
        qualityToken = nil
        let completion = qualityCompletion
        qualityCompletion = nil
        id = ""
        completion?(nil)
    }

    private func handleWindowWillClose(_ closedWindow: NSWindow) {
        guard window === closedWindow else { return }
        window = nil
        closedWindow.delegate = nil
        if motionToken != nil {
            finishMotion(completed: false)
            return
        }
        cancelQualityState()
    }

    private final class QualityView: NSView {
        let image: NSImage
        init(image: NSImage, size: NSSize) { self.image = image; super.init(frame: NSRect(origin: .zero, size: size)) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func draw(_ dirtyRect: NSRect) {
            NSGraphicsContext.current?.imageInterpolation = .none
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        }
    }

    /// The animation runs locally at 30 fps, not in response to per-frame TCP
    /// commands. Evidence records draw() completion, NOT timer firings or proof
    /// of compositor/encoder output. No timer exists before this explicit call.
    func startMotion(id: String, token: Int, waitingForReader: Bool = false, completion: @escaping (LagMotionSource) -> Void) {
        guard motionToken == nil, qualityToken == nil else { return }
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
        motionBegan = 0
        if waitingForReader {
            view.previewMotion(); window?.displayIfNeeded()
            let expiry = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishMotion(completed: false) }
            }
            self.expiry = expiry; RunLoop.main.add(expiry, forMode: .common)
        } else { runMotion(id: id, token: token) }
    }

    func runMotion(id: String, token: Int) {
        guard self.id == id, motionToken == token, motionBegan == 0,
              let view = window?.contentView as? PatternView else { return }
        expiry?.invalidate(); view.resetMotion()
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
                                    started: motionBegan == 0 ? LagRecorder.now() : motionBegan, ended: LagRecorder.now())
        let completion = motionCompletion
        motionToken = nil; motionCompletion = nil; frames = []
        closeCurrentWindow(); id = ""
        completion?(result)
    }

    private final class PatternView: NSView {
        var sequence = 0 { didSet { needsDisplay = true } }
        var motionToken: Int?
        var frameDidDraw: ((Int) -> Void)?
        private var frameNumber = 0
        private var advancing = false

        func previewMotion() { frameNumber = 1; advancing = false; needsDisplay = true }
        func resetMotion() { frameNumber = 0; advancing = false }

        func advanceMotion() {
            guard frameNumber < 512 else { return }
            advancing = true; needsDisplay = true
            displayIfNeeded()
        }
        override func draw(_ dirtyRect: NSRect) {
            let record = motionToken != nil && advancing
            if record { frameNumber += 1; advancing = false }
            let value = motionToken.map { ($0 << 12) | frameNumber } ?? sequence
            let bits = motionToken == nil ? 8 : 24
            NSColor.black.setFill(); bounds.fill()
            let width = bounds.width / CGFloat(bits + 4)
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
                    NSRect(x: CGFloat(col) * width, y: CGFloat(row) * codeHeight / 2,
                           width: width, height: codeHeight / 2).fill()
                }
            }
            if motionToken != nil {
                // Moving bars exercise continuous image changes, not just a
                // number counter. This is a small synthetic scene, not video.
                for index in 0..<10 {
                    NSColor(white: index % 2 == 0 ? 0.9 : 0.3, alpha: 1).setFill()
                    let x = (CGFloat(index) * bounds.width / 10 + CGFloat(frameNumber) * 4).truncatingRemainder(dividingBy: bounds.width)
                    NSRect(x: x, y: codeHeight + 8, width: 20, height: bounds.height - codeHeight - 16).fill()
                }
            }
            if record { frameDidDraw?(frameNumber) }
        }
    }
}
