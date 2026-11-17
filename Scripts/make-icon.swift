// Draws Porthole's app icon and writes Resources/AppIcon.icns:
//
//   swift Scripts/make-icon.swift [preview.png]
//
// A brass ship's porthole on an ocean-blue tile. Drawn as vector shapes at every icon size, so
// small sizes stay crisp. Pass a path to also save a 1024-pixel preview.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                            CGFloat(hex & 0xff) / 255, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

/// The macOS icon tile: a superellipse ("squircle") 824 points wide on the 1024-point grid.
func squircle(_ rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    for step in 0...720 {
        let angle = CGFloat(step) / 720 * 2 * .pi
        let x = copysign(pow(abs(cos(angle)), 2 / exponent), cos(angle)) * rect.width / 2
        let y = copysign(pow(abs(sin(angle)), 2 / exponent), sin(angle)) * rect.height / 2
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// Draws the icon on a 1024 x 1024 canvas (y up).
func drawIcon(_ c: CGContext) {
    let tile = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))

    // The tile, with Apple's soft drop shadow.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    c.addPath(tile)
    c.setFillColor(color(0x0B2A5B))
    c.fillPath()
    c.restoreGState()

    // Open sea: bright at the top, deep at the bottom, with a couple of faint swells.
    c.saveGState()
    c.addPath(tile)
    c.clip()
    c.drawLinearGradient(gradient([(0, color(0x3A9BF5)), (0.5, color(0x1758C2)), (1, color(0x0A2457))]),
                         start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    for (height, alpha) in [(CGFloat(230), CGFloat(0.10)), (175, 0.07)] {
        let swell = CGMutablePath()
        swell.move(to: CGPoint(x: 80, y: height))
        for x in stride(from: CGFloat(80), through: 944, by: 8) {
            swell.addLine(to: CGPoint(x: x, y: height + 16 * sin((x - 80) / 864 * 4 * .pi)))
        }
        c.addPath(swell)
        c.setStrokeColor(color(0xFFFFFF, alpha))
        c.setLineWidth(10)
        c.setLineCap(.round)
        c.strokePath()
    }
    c.restoreGState()

    let center = CGPoint(x: 512, y: 520)
    let outer: CGFloat = 300, lip: CGFloat = 240, glassRadius: CGFloat = 222

    // The porthole's shadow on the sea.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: color(0x000814, 0.5))
    c.addEllipse(in: circle(center, outer))
    c.setFillColor(color(0x6E4511))
    c.fillPath()
    c.restoreGState()

    // Brass ring, lit from the top left.
    func ring(_ outerRadius: CGFloat, _ innerRadius: CGFloat, _ stops: [(CGFloat, CGColor)]) {
        c.saveGState()
        c.addEllipse(in: circle(center, outerRadius))
        c.addEllipse(in: circle(center, innerRadius))
        c.clip(using: .evenOdd)
        c.drawLinearGradient(gradient(stops), start: CGPoint(x: center.x - outerRadius, y: center.y + outerRadius),
                             end: CGPoint(x: center.x + outerRadius, y: center.y - outerRadius), options: [])
        c.restoreGState()
    }
    ring(outer, lip, [(0, color(0xFFF2C6)), (0.32, color(0xE9BF5F)), (0.62, color(0xB8812A)), (1, color(0x6B4210))])
    // The inner lip slopes the other way, so it reads as a step down to the glass.
    ring(lip, glassRadius, [(0, color(0x7A4E16)), (0.5, color(0xC08A33)), (1, color(0xFBE3A0))])
    c.setLineWidth(3)
    c.setStrokeColor(color(0xFFF7DC, 0.7))
    c.strokeEllipse(in: circle(center, outer - 2))
    c.setStrokeColor(color(0x4A2C08, 0.55))
    c.strokeEllipse(in: circle(center, lip))

    // Eight bolts.
    for index in 0..<8 {
        let angle = CGFloat(index) / 8 * 2 * .pi + .pi / 8
        let bolt = CGPoint(x: center.x + 270 * cos(angle), y: center.y + 270 * sin(angle))
        c.saveGState()
        c.setShadow(offset: CGSize(width: 2, height: -3), blur: 4, color: color(0x3A2205, 0.6))
        c.addEllipse(in: circle(bolt, 14))
        c.setFillColor(color(0xB8812A))
        c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addEllipse(in: circle(bolt, 14))
        c.clip()
        c.drawRadialGradient(gradient([(0, color(0xFFF8E0)), (0.45, color(0xD9A94A)), (1, color(0x704512))]),
                             startCenter: CGPoint(x: bolt.x - 5, y: bolt.y + 5), startRadius: 0,
                             endCenter: bolt, endRadius: 15, options: [])
        c.restoreGState()
    }

    // The glass: deep water, lighter in the middle.
    c.saveGState()
    c.addEllipse(in: circle(center, glassRadius))
    c.clip()
    c.drawRadialGradient(gradient([(0, color(0x2C7FD6)), (0.6, color(0x0E3E86)), (1, color(0x041633))]),
                         startCenter: center, startRadius: 0, endCenter: center, endRadius: glassRadius, options: [])

    // The glass itself: a faint sheen and a curved reflection at the top left.
    c.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.16)), (0.45, color(0xFFFFFF, 0)), (1, color(0xFFFFFF, 0))]),
                         start: CGPoint(x: center.x - glassRadius, y: center.y + glassRadius),
                         end: CGPoint(x: center.x + glassRadius, y: center.y - glassRadius), options: [])
    let glare = CGMutablePath()
    glare.addArc(center: center, radius: glassRadius - 34, startAngle: .pi * 0.58, endAngle: .pi * 0.92, clockwise: false)
    c.addPath(glare)
    c.setStrokeColor(color(0xFFFFFF, 0.42))
    c.setLineWidth(16)
    c.setLineCap(.round)
    c.strokePath()
    c.restoreGState()

    // A dark seam where the glass meets the brass.
    c.setStrokeColor(color(0x2A1A04, 0.6))
    c.setLineWidth(4)
    c.strokeEllipse(in: circle(center, glassRadius))
}

func png(size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(context)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Porthole-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if CommandLine.arguments.count > 1 {
    try png(size: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
