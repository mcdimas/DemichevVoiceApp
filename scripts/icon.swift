import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var specifications: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in 1...2 {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let unit = CGFloat(pixels)
        NSColor(calibratedRed: 0.06, green: 0.17, blue: 0.28, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: unit*0.05, y: unit*0.05, width: unit*0.9, height: unit*0.9),
            xRadius: unit*0.2, yRadius: unit*0.2).fill()
        NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.28, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: unit*0.39, y: unit*0.42, width: unit*0.22, height: unit*0.36),
            xRadius: unit*0.11, yRadius: unit*0.11).fill()
        NSColor.white.setStroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: unit*0.29, y: unit*0.55))
        stand.curve(to: NSPoint(x: unit*0.71, y: unit*0.55), controlPoint1: NSPoint(x: unit*0.29, y: unit*0.24), controlPoint2: NSPoint(x: unit*0.71, y: unit*0.24))
        stand.move(to: NSPoint(x: unit*0.5, y: unit*0.32))
        stand.line(to: NSPoint(x: unit*0.5, y: unit*0.22))
        stand.move(to: NSPoint(x: unit*0.39, y: unit*0.22))
        stand.line(to: NSPoint(x: unit*0.61, y: unit*0.22))
        stand.lineWidth = unit*0.045; stand.lineCapStyle = .round; stand.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "app-\(points)-\(scale).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
        specifications.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let catalog: [String: Any] = ["images": specifications, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys, .prettyPrinted]).write(to: destination.appendingPathComponent("Contents.json"))
