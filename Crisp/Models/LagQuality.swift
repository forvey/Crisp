import AppKit
import ImageIO

/// Captured from the tested display, not inferred from a checkbox or window size.
struct LagDisplay: Codable, Sendable {
    let id: UInt32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let backingScale: Double
    let refreshRate: Double
    var text: String {
        "mini 显示器 \(id)：桌面 \(width) × \(height)，渲染 \(pixelWidth) × \(pixelHeight) 像素，HiDPI \(pixelWidth > width ? "开" : "关")，界面倍率 \(backingScale)×"
    }
}

/// Only the program-generated chart crosses the diagnostic connection. No
/// remote desktop screenshot is transmitted. Bounded before decoding pixels.
struct LagQualityReference: Codable, Sendable {
    let token: Int
    let png: Data
    var renderScale: Int? = nil
    var display: LagDisplay? = nil
    var scale: Int { renderScale ?? 1 }
    var valid: Bool {
        guard (1...4095).contains(token), (1...2).contains(scale), png.count <= 160_000,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyPixelWidth] as? Int == LagQualityChart.width * scale &&
            properties[kCGImagePropertyPixelHeight] as? Int == LagQualityChart.height * scale
    }
}

enum LagQualityChart {
    static let width = 784, height = 480, header = 48
    static let textRect = CGRect(x: 24, y: 70, width: 736, height: 136)
    static let lineY = 232, lineHeight = 80
    static let lineWidths = [1, 2, 4]
    static let colors: [(UInt8, UInt8, UInt8)] = [
        (220, 45, 45), (35, 180, 70), (45, 80, 220), (210, 170, 35),
        (160, 50, 190), (35, 175, 185), (128, 128, 128), (235, 235, 235)
    ]
    static func lineRect(_ index: Int) -> CGRect {
        CGRect(x: 24 + index * 248, y: lineY, width: 224, height: lineHeight)
    }
    static func colorRect(_ index: Int) -> CGRect {
        CGRect(x: 24 + index * 92, y: 348, width: 72, height: 56)
    }

    @MainActor static func make(token: Int, scale: Int = 1, display: LagDisplay? = nil) throws -> LagQualityReference {
        guard (1...4095).contains(token), (1...2).contains(scale),
              let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * scale * 4, bitsPerPixel: 32),
              let bytes = image.bitmapData else { throw LagError.invalidMessage }
        func fill(_ rect: CGRect, _ rgb: (UInt8, UInt8, UInt8)) {
            for y in (Int(rect.minY) * scale)..<(Int(rect.maxY) * scale) {
                for x in (Int(rect.minX) * scale)..<(Int(rect.maxX) * scale) {
                    let i = y * image.bytesPerRow + x * 4
                    bytes[i] = rgb.0; bytes[i + 1] = rgb.1; bytes[i + 2] = rgb.2; bytes[i + 3] = 255
                }
            }
        }
        fill(CGRect(x: 0, y: 0, width: width, height: height), (255, 255, 255))
        // Two large complementary markers identify the run and establish both
        // axes. Their center distances tolerate a few blurred border pixels.
        for (y, suffix) in [(0, 1), (height - header, 2)] {
            let code = token << 12 | suffix
            for row in 0..<2 {
                for column in 0..<28 {
                    let color: (UInt8, UInt8, UInt8)
                    if column < 2 { color = (255, 0, 255) }
                    else if column >= 26 { color = (0, 255, 255) }
                    else {
                        let light = ((code >> (column - 2)) & 1) == 1 - row
                        color = light ? (255, 255, 255) : (0, 0, 0)
                    }
                    fill(CGRect(x: column * 28, y: y + row * 24, width: 28, height: 24), color)
                }
            }
        }
        for (index, stripe) in lineWidths.enumerated() {
            let rect = lineRect(index)
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let color: (UInt8, UInt8, UInt8) = ((x - Int(rect.minX)) / stripe) % 2 == 0 ? (0, 0, 0) : (255, 255, 255)
                fill(CGRect(x: x, y: Int(rect.minY), width: 1, height: lineHeight / 2), color)
            }
            for y in (Int(rect.minY) + lineHeight / 2)..<Int(rect.maxY) {
                let color: (UInt8, UInt8, UInt8) = ((y - Int(rect.minY) - lineHeight / 2) / stripe) % 2 == 0 ? (0, 0, 0) : (255, 255, 255)
                fill(CGRect(x: Int(rect.minX), y: y, width: Int(rect.width), height: 1), color)
            }
        }
        for index in colors.indices { fill(colorRect(index), colors[index]) }
        // Render once on the source Mac and send those exact pixels as the
        // reference. OS/font differences on the controller cannot create a loss.
        guard let graphics = NSGraphicsContext(bitmapImageRep: image) else { throw LagError.invalidMessage }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        // Same logical font size on both modes: HiDPI rasterizes fresh glyphs
        // into twice as many pixels, rather than stretching the old bitmap.
        graphics.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        for (size, top, text) in [
            (12.0, 78.0, "费用预算 / Budget 0123456789  部门 Department"),
            (16.0, 116.0, "预算项目：办公用品  ￥12,345.67   Balance = 12345.67"),
            (24.0, 158.0, "中文细节  AaBbMmWw  0O1Il  {}[]<>")
        ] {
            (text as NSString).draw(at: CGPoint(x: 24, y: Double(height) - top - size * 1.4),
                withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = image.representation(using: .png, properties: [:]) else { throw LagError.invalidMessage }
        let result = LagQualityReference(token: token, png: png, renderScale: scale, display: display)
        guard result.valid else { throw LagError.invalidMessage }
        return result
    }
}

struct LagQualityResult: Codable {
    let token: Int
    var samples = 0
    var completed = false
    var lastFrameMatched = false
    var client: String?
    var windowPixels: String?
    var sourceDigest: String?
    var scaleX: Double?
    var scaleY: Double?
    var textDifference: Double?
    var lineContrast: [Double] = []
    var colorDifference: Double?
    var reason: String?
    var display: LagDisplay?
    var renderScale: Int?
    var screenPermissionGranted: Bool?
    var capturedFrames: Int?
    var unmatchedFrames: Int?
    var preparationMS: Int?
    var measuredSeconds: Double?
    var text: String {
        guard lastFrameMatched, samples > 0, let scaleX, let scaleY, let textDifference, let colorDifference, lineContrast.count == 3 else {
            return "画面清晰度：不能判定。未取得完整的本次图案，或最后画面已无法对齐。\n" + (reason ?? "")
        }
        let reduced = min(scaleX, scaleY) < 0.99
        var lines = ["画面清晰度诊断（同样字号，按 mini 当前显示倍率绘制）"]
        if let client { lines.append("本机窗口：\(client) · \(windowPixels ?? "尺寸未知") 像素") }
        if let display { lines.append(display.text) }
        lines.append("测量客户端解码、缩放后绘制的窗口，不是后台收到的原始图像；不含物理显示器效果。")
        lines.append(String(format: "源渲染像素到本机像素：横向 %.1f%%，纵向 %.1f%%。%@", scaleX * 100, scaleY * 100,
                            reduced ? "当前画面被缩小，细节损失不能直接归因压缩或网络。" : "未发现明显缩小。"))
        lines.append(String(format: "中文/英文文字图像差异：%.1f%%（越低越接近原图；不是识字率）。", textDifference * 100))
        for index in 0..<3 {
            lines.append(String(format: "%d 点细线：对比度保留 %.0f%%（HiDPI 每点占更多渲染像素）。",
                                LagQualityChart.lineWidths[index], lineContrast[index] * 100))
        }
        lines.append(String(format: "色块平均 RGB 差异：%.1f / 255（不是物理屏幕校色结果）。", colorDifference * 255))
        if !completed { lines.append("诊断提前结束：以下仅为已有画面的测量，不能作为完整诊断结论。") }
        else if abs(scaleX - scaleY) > 0.05 { lines.append("结论：横纵显示比例不同，画面可能被拉伸；先统一比例再比较。") }
        else if reduced { lines.append("结论：存在显示缩小；建议保持同一窗口比例比较，或用原尺寸重测。") }
        else if textDifference > 0.05 || (lineContrast.min() ?? 1) < 0.7 || colorDifference > 0.05 {
            lines.append("结论：本次窗口图像存在可测的细节或颜色差异；不能单凭此结果定位到编码或网络。")
        } else { lines.append("结论：本次固定图未发现明显差异；不代表所有字体、视频或物理屏幕都清晰。") }
        lines.append("检查 \(samples) 个完整图像，报告最后一次结果；不保存截图。")
        if let renderScale {
            lines.append("测试文字为 12/16/24 点，源图渲染倍率 \(renderScale)×。HiDPI 不同的两份报告参考图也不同，不能只按文字差异百分比判断哪份更清楚。")
        }
        if let reason { lines.append(reason) }
        return lines.joined(separator: "\n")
    }
}

/// Only aggregate results are retained for two successive client measurements.
/// Different chart content or scale is not used to rank transport quality.
struct LagQualityComparison: Codable {
    let host: String
    var results: [LagQualityResult]
    var text: String {
        guard results.count == 2 else { return "" }
        let a = results[0], b = results[1]
        guard a.completed, b.completed, a.lastFrameMatched, b.lastFrameMatched,
              let ax = a.scaleX, let ay = a.scaleY, let bx = b.scaleX, let by = b.scaleY,
              let at = a.textDifference, let bt = b.textDifference,
              a.lineContrast.count == 3, b.lineContrast.count == 3 else {
            return "前后对比：至少一次诊断未完成或图案不完整，不能比较。"
        }
        guard let digest = a.sourceDigest, digest == b.sourceDigest else {
            return "前后对比：两次参考图内容不一致，不能直接比较。"
        }
        var rows = ["前后两次窗口对比（同一 mini、同一测试图）",
                    "指标 ｜ \(a.client ?? "上次") ｜ \(b.client ?? "本次")",
                    String(format: "显示比例（横/纵） ｜ %.0f/%.0f%% ｜ %.0f/%.0f%%", ax * 100, ay * 100, bx * 100, by * 100),
                    String(format: "文字图像差异（低更接近原图） ｜ %.1f%% ｜ %.1f%%", at * 100, bt * 100)]
        for i in 0..<3 {
            rows.append(String(format: "%d 点细线对比度（高更清楚） ｜ %.0f%% ｜ %.0f%%",
                               LagQualityChart.lineWidths[i], a.lineContrast[i] * 100, b.lineContrast[i] * 100))
        }
        if abs(ax - bx) > 0.03 || abs(ay - by) > 0.03 {
            rows.append("两次显示比例不同：可以比较当时看到的效果，不能据此认定哪个传输更清晰；请统一比例后重测。")
        } else { rows.append("显示比例接近；这里只比较本次固定图，不据此判断压缩、网络或物理屏幕的根因。") }
        return rows.joined(separator: "\n")
    }
}
