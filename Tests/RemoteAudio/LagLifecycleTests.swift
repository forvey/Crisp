import AppKit
import Foundation

/// Explicit local component checks; these never observe the user's screen,
/// create a second remote video session, or open an audio device.
enum LagLifecycleTests {
    @MainActor
    static func pattern() throws {
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
        // Coordinates below describe interface points. A HiDPI cache has
        // twice as many pixels; sample the same point on either backing scale.
        let scaleX = Double(image.pixelsWide) / view.bounds.width
        let scaleY = Double(image.pixelsHigh) / view.bounds.height
        print("Pattern cache: \(image.pixelsWide)x\(image.pixelsHigh), point-to-pixel scale \(scaleX)x\(scaleY)")
        func color(_ x: Int, _ y: Int) -> NSColor {
            let pixelX = Int(Double(x) * scaleX), pixelY = Int(Double(y) * scaleY)
            guard let value = image.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB) else {
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

        // A visible preparation marker must not consume the motion test. Only
        // this session's Run starts drawing; no acknowledgement closes it in 5s.
        var prepared: [LagMotionSource] = []
        pattern.startMotion(id: "motion-ready", token: 19, waitingForReader: true) { prepared.append($0) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        pattern.runMotion(id: "previous-session", token: 19)
        pattern.runMotion(id: "motion-ready", token: 18)
        precondition(shown() != nil && prepared.isEmpty)
        pattern.stopMotion(id: "motion-ready", token: 19)
        precondition(prepared.count == 1 && prepared[0].frames.isEmpty && !prepared[0].completed)

        pattern.startMotion(id: "motion-run", token: 20, waitingForReader: true) { prepared.append($0) }
        pattern.runMotion(id: "motion-run", token: 20)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        pattern.runMotion(id: "motion-run", token: 20) // duplicate must not reset numbering
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        pattern.stopMotion(id: "motion-run", token: 20)
        precondition(prepared.count == 2 && prepared[1].valid && prepared[1].frames.count >= 3)
        precondition(prepared[1].ended - prepared[1].started >= 0.35)

        pattern.startMotion(id: "motion-unread", token: 21, waitingForReader: true) { prepared.append($0) }
        let preparationBegan = LagRecorder.now()
        while shown() != nil, LagRecorder.now() - preparationBegan < 5.7 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(shown() == nil && prepared.count == 3)
        precondition(prepared[2].frames.isEmpty && !prepared[2].completed)
        print("Motion readiness passed: static preparation, matching/duplicate Run and unacknowledged expiry")

        // Clarity displays the exact generated reference at source-native
        // pixels. Stop, stale close and independent expiry must release it.
        func qualityWindow() -> NSWindow? {
            app.windows.first { $0.title == "画面清晰度诊断 · 结束后关闭" && $0.isVisible }
        }
        func startQualityAndWait(id: String, token: Int) -> LagQualityReference? {
            var generated: LagQualityReference?
            var finished = false
            pattern.startQuality(id: id, token: token) {
                generated = $0
                finished = true
            }
            let waitStart = LagRecorder.now()
            while !finished, LagRecorder.now() - waitStart < 5 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(finished, "Quality chart generation did not finish in time")
            return generated
        }
        guard let reference = startQualityAndWait(id: "quality-stop", token: 31),
              reference.valid, let quality = qualityWindow(), let qualityView = quality.contentView else {
            preconditionFailure("Clarity chart not shown")
        }
        precondition(quality.styleMask.contains(.closable))
        let nativeSize = qualityView.convertToBacking(qualityView.bounds).size
        precondition(Int(qualityView.bounds.width) == LagQualityChart.width && Int(qualityView.bounds.height) == LagQualityChart.height)
        precondition(Int(nativeSize.width) == LagQualityChart.width * reference.scale &&
                     Int(nativeSize.height) == LagQualityChart.height * reference.scale)
        precondition(reference.display?.backingScale == Double(reference.scale))
        pattern.close(id: "previous-session")
        precondition(qualityWindow() != nil)
        quality.close()
        precondition(qualityWindow() == nil)
        guard let expiryRef = startQualityAndWait(id: "quality-expiry", token: 32), expiryRef.valid else {
            preconditionFailure("Clarity expiry chart not shown")
        }
        pattern.close(id: "quality-expiry")
        precondition(qualityWindow() == nil)
        _ = startQualityAndWait(id: "quality-expiry-2", token: 33)
        let qualityBegan = LagRecorder.now()
        while qualityWindow() != nil, LagRecorder.now() - qualityBegan < 17 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(qualityWindow() == nil && LagRecorder.now() - qualityBegan >= 15.8)
        print("Clarity lifecycle passed: display-scale pixels, local close, stale stop, " +
              "explicit stop and 16-second expiry")
    }

    @MainActor
    static func screenTrace(port: UInt16) {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(4)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            precondition(condition(), "Screen trace round trip did not finish")
        }
        for collect in [false, true] {
            let peer = DiagnosticPeer(port: port, duration: 30)
            wait { peer.count("started") == 1 }
            precondition(peer.last("started")?.note?.contains("screen-evidence-v1") == true)
            peer.send("motionPrepare", sequence: 101, collect: collect ? true : nil)
            wait { NSApplication.shared.windows.contains { $0.title == "共享画面短测 · 自动关闭" && $0.isVisible } }
            peer.send("motionStop", sequence: 101)
            wait { peer.count("motionResult") == 1 }
            let result = peer.last("motionResult")!
            precondition(result.motion?.token == 101 && result.motion?.completed == false)
            if collect {
                // A loopback peer must never launch nettop or system-log collection.
                precondition(result.screenTrace?.valid == true && result.screenTrace?.ended != nil)
                precondition(result.screenTrace?.tcpState == "unavailable" && result.screenTrace?.logState == "notStarted")
                precondition(result.screenTrace?.tcp.isEmpty == true && result.screenTrace?.events.isEmpty == true)
            } else { precondition(result.screenTrace == nil, "Old clients unexpectedly enabled screen collection") }
            peer.stop()
            wait { peer.isClosed() }
            precondition(!NSApplication.shared.windows.contains { $0.title == "共享画面短测 · 自动关闭" && $0.isVisible })
        }
        print("Screen trace TCP passed: opt-in result, loopback no collection, legacy omission and stop cleanup")
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
