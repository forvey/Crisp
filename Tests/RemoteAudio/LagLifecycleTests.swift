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

        // Motion must draw autonomously without per-frame TCP commands. A
        // stale stop cannot close it; an explicit stop returns partial numeric
        // evidence once and leaves no animation running. No screen is captured.
        var results: [LagMotionSource] = []
        pattern.startMotion(id: "motion-local", token: 17) { results.append($0) }
        let started = LagRecorder.now()
        while LagRecorder.now() - started < 0.35 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        pattern.stopMotion(id: "motion-local", token: 16)
        pattern.close(id: "previous-session")
        precondition(shown() != nil && results.isEmpty)
        pattern.stopMotion(id: "motion-local", token: 17)
        precondition(shown() == nil && results.count == 1)
        precondition(results[0].valid && !results[0].completed && results[0].frames.count >= 3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        precondition(results.count == 1 && shown() == nil, "Cancelled motion timer remained active")

        // A disconnected controller may never send Stop. The independent
        // 15-second bound must close the window and report at most 512 draws.
        pattern.startMotion(id: "motion-expiry", token: 18) { results.append($0) }
        pattern.stopMotion(id: "motion-local", token: 17)
        let motionBegan = LagRecorder.now()
        while shown() != nil, LagRecorder.now() - motionBegan < 16 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(shown() == nil && results.count == 2)
        precondition(results[1].valid && results[1].completed && results[1].frames.count >= 60)
        precondition(LagRecorder.now() - motionBegan >= 14.8)
        print("Motion lifecycle passed: autonomous draws, partial stop, stale stop isolation, independent 15-second expiry")

        // Clarity displays the exact generated reference at source-native
        // pixels. Stop, stale close and independent expiry must release it.
        func qualityWindow() -> NSWindow? {
            app.windows.first { $0.title == "画面清晰度诊断 · 结束后关闭" && $0.isVisible }
        }
        let reference = try! pattern.startQuality(id: "quality-stop", token: 31)
        guard reference.valid, let quality = qualityWindow(), let qualityView = quality.contentView else {
            preconditionFailure("Clarity chart not shown")
        }
        let nativeSize = qualityView.convertToBacking(qualityView.bounds).size
        precondition(Int(nativeSize.width) == LagQualityChart.width && Int(nativeSize.height) == LagQualityChart.height)
        pattern.close(id: "previous-session")
        precondition(qualityWindow() != nil)
        pattern.close(id: "quality-stop")
        precondition(qualityWindow() == nil)
        _ = try! pattern.startQuality(id: "quality-expiry", token: 32)
        let qualityBegan = LagRecorder.now()
        while qualityWindow() != nil, LagRecorder.now() - qualityBegan < 13 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(qualityWindow() == nil && LagRecorder.now() - qualityBegan >= 11.8)
        print("Clarity lifecycle passed: native pixels, stale stop isolation, explicit stop and independent 12-second expiry")
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
