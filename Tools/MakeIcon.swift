import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Expected output .icns path") }
let destination = URL(fileURLWithPath: CommandLine.arguments[1])

func drawIcon(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = AffineTransform(scaleByX: CGFloat(size) / 1024, byY: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()
    let body = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904),
                            xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.81, alpha: 1),
               ending: NSColor(calibratedRed: 0.06, green: 0.16, blue: 0.37, alpha: 1))!
        .draw(in: body, angle: -90)

    let card = NSBezierPath(roundedRect: NSRect(x: 318, y: 350, width: 480, height: 396),
                            xRadius: 74, yRadius: 74)
    NSColor.white.withAlphaComponent(0.95).setFill()
    card.fill()

    NSColor(calibratedRed: 0.12, green: 0.28, blue: 0.51, alpha: 0.23).setFill()
    for (x, y, width) in [(CGFloat(393), CGFloat(627), CGFloat(290)),
                           (393, 536, 210), (393, 445, 250)] {
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 30),
                     xRadius: 15, yRadius: 15).fill()
    }

    let center = NSPoint(x: 301, y: 310)
    NSColor(calibratedRed: 0.44, green: 0.96, blue: 0.8, alpha: 0.3).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 132, y: center.y - 132,
                                         width: 264, height: 264))
    ring.lineWidth = 25
    ring.stroke()
    NSColor(calibratedRed: 0.44, green: 0.96, blue: 0.8, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 73, y: center.y - 73,
                              width: 146, height: 146)).fill()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

func bigEndian(_ value: Int) -> Data {
    var number = UInt32(value).bigEndian
    return Data(bytes: &number, count: MemoryLayout<UInt32>.size)
}

var chunks = Data()
for (type, size) in [("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    let png = try drawIcon(size: size)
    chunks.append(contentsOf: type.utf8)
    chunks.append(bigEndian(png.count + 8))
    chunks.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndian(chunks.count + 8))
icon.append(chunks)
try icon.write(to: destination)
guard let loaded = NSImage(contentsOf: destination), loaded.isValid else {
    fatalError("Generated icon could not be read by AppKit")
}
