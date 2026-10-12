#!/usr/bin/env swift
// Draws the App Store product page header (night sky, crescent moon, mountains, sound-wave bars)
// in both sizes App Store Connect accepts, into build/store/.
// Usage (from the repo root): swift scripts/make_store_header.swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/store")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Deterministic pseudo-random numbers so the stars land in the same place every run.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return CGFloat((z ^ (z >> 31)) >> 11) / CGFloat(1 << 53)
    }
}

/// A smooth ridge line across the full width, built from a few sine waves.
func ridge(width w: CGFloat, height h: CGFloat, base: CGFloat, amplitude: CGFloat,
           waves: [(CGFloat, CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    let steps = 240
    for i in 0...steps {
        let x = w * CGFloat(i) / CGFloat(steps)
        var y: CGFloat = 0
        for (frequency, phase) in waves {
            y += sin(x / w * .pi * 2 * frequency + phase)
        }
        path.addLine(to: CGPoint(x: x, y: h * base + h * amplitude * y / CGFloat(waves.count)))
    }
    path.addLine(to: CGPoint(x: w, y: 0))
    path.closeSubpath()
    return path
}

func drawHeader(width: Int, height: Int) -> CGImage {
    let w = CGFloat(width), h = CGFloat(height)
    let unit = h / 1000
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

    let sky = CGGradient(colorsSpace: space,
                         colors: [color(0.10, 0.14, 0.27), color(0.06, 0.08, 0.15), color(0.04, 0.05, 0.09)] as CFArray,
                         locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

    let moonCenter = CGPoint(x: w * 0.5, y: h * 0.60)
    let moonRadius = h * 0.17
    let glow = CGGradient(colorsSpace: space,
                          colors: [color(0.596, 0.722, 0.902, 0.30), color(0.596, 0.722, 0.902, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: moonCenter, startRadius: 0,
                           endCenter: moonCenter, endRadius: moonRadius * 3.2, options: [])

    var random = SplitMix64(state: 0x5747_4152)
    for _ in 0..<Int(w / h * 90) {
        let x = random.next() * w
        let y = h * (0.35 + random.next() * 0.65)
        let r = unit * (1.2 + random.next() * 3.2)
        let distance = hypot(x - moonCenter.x, y - moonCenter.y)
        guard distance > moonRadius * 1.6 else { continue }
        ctx.setFillColor(color(0.92, 0.95, 1, 0.35 + random.next() * 0.55))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // Crescent moon, matching the app icon: a disc with an offset disc cut out.
    ctx.saveGState()
    let cutout = CGPath(ellipseIn: CGRect(x: moonCenter.x - moonRadius * 0.55, y: moonCenter.y - moonRadius * 0.62,
                                          width: moonRadius * 2, height: moonRadius * 2), transform: nil)
    let clip = CGMutablePath()
    clip.addRect(CGRect(x: 0, y: 0, width: w, height: h))
    clip.addPath(cutout)
    ctx.addPath(clip)
    ctx.clip(using: .evenOdd)
    ctx.addEllipse(in: CGRect(x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius,
                              width: moonRadius * 2, height: moonRadius * 2))
    ctx.clip()
    let moonFill = CGGradient(colorsSpace: space,
                              colors: [color(0.97, 0.97, 1), color(0.74, 0.82, 0.95)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(moonFill, start: CGPoint(x: moonCenter.x - moonRadius, y: moonCenter.y + moonRadius),
                           end: CGPoint(x: moonCenter.x + moonRadius, y: moonCenter.y - moonRadius), options: [])
    ctx.restoreGState()

    // Three mountain ranges, lighter and hazier towards the back.
    let ranges: [(base: CGFloat, amplitude: CGFloat, waves: [(CGFloat, CGFloat)], fill: CGColor)] = [
        (0.36, 0.10, [(1.3, 0.4), (3.1, 1.9), (5.7, 0.2)], color(0.13, 0.17, 0.29)),
        (0.26, 0.09, [(1.7, 2.2), (4.3, 0.7), (7.9, 1.1)], color(0.08, 0.11, 0.20)),
        (0.15, 0.07, [(2.3, 1.3), (5.1, 2.8), (9.7, 0.5)], color(0.05, 0.06, 0.12)),
    ]
    for range in ranges {
        ctx.addPath(ridge(width: w, height: h, base: range.base, amplitude: range.amplitude, waves: range.waves))
        ctx.setFillColor(range.fill)
        ctx.fillPath()
    }

    let heights: [CGFloat] = [0.05, 0.08, 0.12, 0.17, 0.12, 0.08, 0.05]
    let barWidth = h * 0.030
    let gap = h * 0.026
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let baseline = h * 0.25
    ctx.setFillColor(color(0.596, 0.722, 0.902, 0.95))
    for (i, barHeight) in heights.enumerated() {
        let height = h * barHeight * 0.75
        let rect = CGRect(x: (w - totalWidth) / 2 + CGFloat(i) * (barWidth + gap), y: baseline - height / 2,
                          width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    }
    ctx.fillPath()

    return ctx.makeImage()!
}

for (width, height) in [(5244, 2950), (3840, 1646)] {
    let url = outputDir.appendingPathComponent("header-\(width)x\(height).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, drawHeader(width: width, height: height), nil)
    guard CGImageDestinationFinalize(destination) else {
        print("Could not write \(url.path)")
        exit(1)
    }
    print("wrote \(url.path)")
}
