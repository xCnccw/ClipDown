// Generates a simple placeholder app icon (rounded square + "M↓").
// Usage: swift scripts/make-icon.swift <output.iconset-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.08
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.42, blue: 0.98, alpha: 1),
                        NSColor(red: 0.55, green: 0.30, blue: 0.95, alpha: 1)])!.draw(in: path, angle: -60)
    let text = NSAttributedString(string: "M↓", attributes: [
        .font: NSFont.systemFont(ofSize: size * 0.46, weight: .heavy),
        .foregroundColor: NSColor.white,
    ])
    let ts = text.size()
    text.draw(at: NSPoint(x: (size - ts.width) / 2, y: (size - ts.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
