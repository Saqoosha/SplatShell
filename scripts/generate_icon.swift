#!/usr/bin/env swift
// Draws the app icon — a cluster of Gaussian splats on a dark rounded square —
// and writes Resources/AppIcon.icns.
//
//   swift scripts/generate_icon.swift [--preview <png>]
//
// --preview also writes the 1024 px master image to the given path.

import AppKit
import CoreGraphics

/// Fixed seed, so the icon is the same on every run.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: an 824 px rounded square centred on the 1024 px canvas
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

// soft shadow under the plate
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(platePath)
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()

// background
let background = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(srgbRed: 0.10, green: 0.11, blue: 0.20, alpha: 1),
        CGColor(srgbRed: 0.02, green: 0.02, blue: 0.05, alpha: 1),
    ] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(
    background, start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.minY), options: [])

/// One splat: an ellipse whose opacity falls off as a Gaussian from the centre.
func drawSplat(center: CGPoint, radius: CGFloat, aspect: CGFloat, angle: CGFloat, color: (CGFloat, CGFloat, CGFloat), opacity: CGFloat) {
    let stops = 12
    var colors: [CGColor] = []
    var locations: [CGFloat] = []
    for i in 0...stops {
        let t = CGFloat(i) / CGFloat(stops)
        // the gradient radius is 3 sigma
        let alpha = opacity * exp(-0.5 * pow(t * 3, 2))
        colors.append(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: alpha))
        locations.append(t)
    }
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    ctx.scaleBy(x: 1, y: aspect)
    ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
    ctx.restoreGState()
}

let palette: [(CGFloat, CGFloat, CGFloat)] = [
    (0.25, 0.80, 1.00),  // cyan
    (0.45, 0.50, 1.00),  // blue violet
    (1.00, 0.35, 0.65),  // pink
    (1.00, 0.70, 0.25),  // amber
    (0.95, 0.97, 1.00),  // near white
]

var rng = SplitMix64(state: 20261110)
ctx.setBlendMode(.screen)
let middle = CGPoint(x: plate.midX, y: plate.midY)

// large soft splats first, small bright ones on top
for layer in 0..<3 {
    let count = [14, 34, 60][layer]
    let spread = [250.0, 230.0, 210.0][layer]
    let radius = [(210.0, 320.0), (90.0, 170.0), (28.0, 70.0)][layer]
    let opacity = [(0.14, 0.26), (0.28, 0.50), (0.65, 0.95)][layer]
    for _ in 0..<count {
        // uniform over a disc, which reads as a ball of splats
        let r = spread * rng.next().squareRoot()
        let a = rng.range(0, 2 * .pi)
        let center = CGPoint(x: middle.x + r * cos(a), y: middle.y + r * sin(a) * 0.92)
        let colorIndex = Int(rng.range(0, Double(palette.count) - 0.001))
        drawSplat(
            center: center, radius: rng.range(radius.0, radius.1), aspect: rng.range(0.28, 0.75),
            angle: rng.range(0, .pi), color: palette[colorIndex], opacity: rng.range(opacity.0, opacity.1))
    }
}
ctx.restoreGState()

let master = ctx.makeImage()!

func png(_ image: CGImage, pixels: Int) -> Data {
    let scaled = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    scaled.interpolationQuality = .high
    scaled.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return NSBitmapImageRep(cgImage: scaled.makeImage()!).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("SplatShell-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try png(master, pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(master, pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print(output.path)

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--preview"), flag + 1 < arguments.count {
    try png(master, pixels: size).write(to: URL(fileURLWithPath: arguments[flag + 1]))
}
