import AppKit
import Foundation

/// Explicit local component checks; these never observe the user's screen,
/// create a second remote video session, or open an audio device.
enum LagLifecycleTests {
    @MainActor
    static func pattern() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        func shown() -> NSWindow? {
            app.windows.first { $0.title == "共享画面短测 · 自动关闭" && $0.isVisible }
        }
        let pattern = CrispLagPattern.shared
        pattern.show(id: "local-pattern-stop", sequence: 42)
        guard let window = shown(), let view = window.contentView,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            preconditionFailure("Pattern window was not shown")
        }
        view.cacheDisplay(in: view.bounds, to: image)
        func color(_ x: Int, _ y: Int) -> NSColor {
            guard let value = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                preconditionFailure("Pattern could not be drawn")
            }
            return value
        }
        let left = color(50, 60), right = color(550, 60)
        precondition(left.redComponent > 0.7 && left.blueComponent > 0.7 && left.greenComponent < 0.3)
        precondition(right.greenComponent > 0.7 && right.blueComponent > 0.7 && right.redComponent < 0.3)
        for bit in 0..<8 {
            let x = 125 + bit * 50
            let upper = color(x, 60), lower = color(x, 180)
            precondition((upper.redComponent > 0.7) != (lower.redComponent > 0.7))
        }
        pattern.close(id: "different-session")
        precondition(shown() != nil, "A stale close hid another session's pattern")
        pattern.close(id: "local-pattern-stop")
        precondition(shown() == nil, "Explicit stop did not close the pattern")
        pattern.show(id: "local-pattern-expiry", sequence: 43)
        let began = LagRecorder.now()
        while shown() != nil, LagRecorder.now() - began < 5.7 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(shown() == nil, "Pattern failed to close without further requests")
        precondition(LagRecorder.now() - began >= 4.8, "Pattern closed before its expiry")
        print("Local pattern passed: sentinel pixels, complementary rows, explicit/stale close and five-second expiry")
    }

    static func maximumDuration(port: UInt16) -> Double {
        // Delaying start relative to the resource clock makes an independent
        // deadline observable; a one-second poll would overrun by about 650 ms.
        let peer = DiagnosticPeer(port: port, duration: 60, delayBeforeStart: 0.35)
        RealControllerInterop.wait({ peer.isClosed() }, seconds: 63)
        precondition(peer.count("started") == 1 && peer.count("sample") >= 58)
        precondition(peer.elapsed() >= 59.5 && peer.elapsed() < 60.5, "60-second deadline exceeded its scheduling tolerance")
        peer.cancel()
        return peer.elapsed()
    }
}
