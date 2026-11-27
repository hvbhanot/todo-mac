// Renders the 1024px app icon PNG. Usage: swift icon.swift out.png
// The mark is a tally gate: four strokes and an accent strike, the same marks the Today page uses for the daily goal.
import AppKit

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
let bg = NSGradient(starting: rgb(0x2C303B), ending: rgb(0x15171C))!
bg.draw(in: tile, angle: -90)

// Four upright strokes, centred on the tile.
let w: CGFloat = 58, gap: CGFloat = 66, h: CGFloat = 392
let x0 = 512 - (4 * w + 3 * gap) / 2, y0: CGFloat = 512 - h / 2
rgb(0xE6E8ED).setFill()
for i in 0..<4 {
    NSBezierPath(roundedRect: NSRect(x: x0 + CGFloat(i) * (w + gap), y: y0, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
}

// The strike: cut a gap through the strokes (repainting the tile there), then the accent bar.
let strike = NSBezierPath()
strike.move(to: NSPoint(x: x0 - 52, y: y0 + 58))
strike.line(to: NSPoint(x: 1024 - x0 + 52, y: y0 + h - 58))
strike.lineCapStyle = .round
let ctx = NSGraphicsContext.current!.cgContext
ctx.saveGState()
ctx.addPath(strike.cgPath.copy(strokingWithWidth: 64 + 40, lineCap: .round, lineJoin: .round, miterLimit: 10))
ctx.clip()
bg.draw(in: tile, angle: -90)
ctx.restoreGState()
strike.lineWidth = 64
rgb(0x7D91D6).setStroke()
strike.stroke()

NSGraphicsContext.current?.flushGraphics()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
