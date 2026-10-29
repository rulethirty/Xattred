import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let variants = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in variants {
    let pixels = points * scale
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: size * 0.05, y: size * 0.05, width: size * 0.9, height: size * 0.9),
                 xRadius: size * 0.2, yRadius: size * 0.2).fill()
    // Geometric X stays crisp and independent of installed fonts.
    NSColor.white.setStroke()
    let mark = NSBezierPath()
    mark.lineWidth = size * 0.115
    mark.lineCapStyle = .square
    mark.move(to: NSPoint(x: size * 0.32, y: size * 0.29))
    mark.line(to: NSPoint(x: size * 0.68, y: size * 0.71))
    mark.move(to: NSPoint(x: size * 0.32, y: size * 0.71))
    mark.line(to: NSPoint(x: size * 0.68, y: size * 0.29))
    mark.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let path = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: path)
}