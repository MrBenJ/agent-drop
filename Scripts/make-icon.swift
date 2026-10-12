// Draws AgentDrop.app's icon and writes App/AppIcon.icns. The .icns is committed, so a
// build never runs this; rerun it only to change the icon:
//   swift Scripts/make-icon.swift && git add App/AppIcon.icns
// The glyph is the menu bar's tray-with-arrow symbol, on the macOS icon grid (an
// 824 px rounded square inside a 1024 px canvas).
import AppKit

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024) // draw in 1024-point units at any pixel size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    // Soft drop shadow under the body, as on other macOS icons.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.62, blue: 1.00, alpha: 1),
               ending: NSColor(srgbRed: 0.10, green: 0.33, blue: 0.86, alpha: 1))!
        .draw(in: shape, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(configuration)!
    let size = symbol.size
    symbol.draw(in: NSRect(x: 512 - size.width / 2, y: 512 - size.height / 2 - 10,
                           width: size.width, height: size.height))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let output = repo.appendingPathComponent("App/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print(output.path)
