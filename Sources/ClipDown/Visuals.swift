import AppKit
import SwiftUI
import ClipCore

/// Source-app icon + the dominant colour used for card headers.
enum AppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var colors: [String: Color] = [:]

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let id = bundleID else { return nil }
        if let i = icons[id] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        icons[id] = img
        return img
    }

    static func color(_ bundleID: String?, fallback: Color) -> Color {
        guard let id = bundleID else { return fallback }
        if let c = colors[id] { return c }
        guard let img = icon(id), let c = dominant(of: img) else { return fallback }
        colors[id] = c
        return c
    }

    private static func dominant(of img: NSImage) -> Color? {
        let n = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        img.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        var r = 0.0, g = 0.0, b = 0.0, w = 0.0
        for y in 0..<n { for x in 0..<n {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
            // weight saturated pixels more so white/grey glyphs don't wash the colour out
            let weight = 0.25 + Double(c.saturationComponent)
            r += Double(c.redComponent) * weight; g += Double(c.greenComponent) * weight
            b += Double(c.blueComponent) * weight; w += weight
        } }
        guard w > 0 else { return nil }
        var (rr, gg, bb) = (r / w, g / w, b / w)
        let lum = 0.299 * rr + 0.587 * gg + 0.114 * bb
        if lum > 0.6 { let k = 0.6 / lum; rr *= k; gg *= k; bb *= k }   // keep white header text legible
        return Color(red: rr, green: gg, blue: bb)
    }
}

/// Renders an item's RTF into a cached bitmap so rich cards look like the real content.
enum RichThumb {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for item: ClipItem, size: CGSize) -> NSImage? {
        let key = "\(item.id)-\(item.rtf?.count ?? 0)" as NSString
        if let c = cache.object(forKey: key) { return c }
        guard let a = RichText.attributed(from: item) else { return nil }
        let scale: CGFloat = 0.62
        let img = NSImage(size: size, flipped: true) { rect in
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            a.draw(with: NSRect(x: 0, y: 0, width: rect.width / scale, height: rect.height / scale),
                   options: [.usesLineFragmentOrigin])
            return true
        }
        cache.setObject(img, forKey: key)
        return img
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

let boardPalette = ["#E5534B", "#F28C28", "#F5B027", "#5DBE5B", "#5E9EF2", "#A25BD6", "#EE5470", "#8A8A8E"]

let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "zh_CN"); f.unitsStyle = .full
    return f
}()

// MARK: - Light / dark theme

extension NSColor {
    /// Colour that re-resolves automatically when the appearance changes.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

enum Theme {
    static let surfaceNS = NSColor.dynamic(light: NSColor(calibratedWhite: 0.93, alpha: 1),
                                           dark: NSColor(calibratedWhite: 0.12, alpha: 1))
    static let surface = Color(nsColor: surfaceNS)
    static let card = Color(nsColor: .dynamic(light: .white, dark: NSColor(calibratedWhite: 0.18, alpha: 1)))
    static let cardText = Color(nsColor: .dynamic(light: .black, dark: NSColor(calibratedWhite: 0.93, alpha: 1)))
    static let cardSecondary = Color(nsColor: .dynamic(light: NSColor(calibratedWhite: 0, alpha: 0.45),
                                                       dark: NSColor(calibratedWhite: 1, alpha: 0.5)))
    static let cardStroke = Color(nsColor: .dynamic(light: NSColor(calibratedWhite: 0, alpha: 0.08),
                                                    dark: NSColor(calibratedWhite: 1, alpha: 0.14)))
    static let link = Color(nsColor: .dynamic(light: .systemBlue, dark: NSColor(calibratedRed: 0.42, green: 0.68, blue: 1, alpha: 1)))
}

/// Layer-backed view whose background follows light/dark appearance changes.
final class SurfaceView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.surfaceNS.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
