#!/usr/bin/env swift
// Draws the 1024x1024 app icon (night sky, crescent moon, sound-wave bars) into the AppIcon asset.
// Usage (from the repo root): swift scripts/make_app_icon.swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let s = CGFloat(size)
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("WhiteNoise/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
// App Store icons must be opaque, so there is no alpha channel.
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Night-sky gradient: deep navy at the top fading to the app's background colour at the bottom.
let sky = CGGradient(colorsSpace: space,
                     colors: [color(0.10, 0.14, 0.27), color(0.04, 0.05, 0.09)] as CFArray,
                     locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

// Soft glow behind the moon.
let moonCenter = CGPoint(x: s * 0.5, y: s * 0.60)
let moonRadius = s * 0.20
let glow = CGGradient(colorsSpace: space,
                      colors: [color(0.596, 0.722, 0.902, 0.28), color(0.596, 0.722, 0.902, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: moonCenter, startRadius: 0,
                       endCenter: moonCenter, endRadius: moonRadius * 2.2, options: [])

// A few small stars.
let stars: [(CGFloat, CGFloat, CGFloat)] = [
    (0.20, 0.82, 7), (0.25, 0.70, 4), (0.78, 0.84, 6), (0.84, 0.66, 4), (0.68, 0.92, 3.5), (0.14, 0.62, 3),
]
ctx.setFillColor(color(0.92, 0.95, 1, 0.85))
for (x, y, r) in stars {
    ctx.fillEllipse(in: CGRect(x: s * x - r, y: s * y - r, width: r * 2, height: r * 2))
}

// Crescent moon: a full disc with an offset disc cut out of it.
ctx.saveGState()
let cutout = CGPath(ellipseIn: CGRect(x: moonCenter.x - moonRadius * 0.55, y: moonCenter.y - moonRadius * 0.62,
                                      width: moonRadius * 2, height: moonRadius * 2), transform: nil)
let clip = CGMutablePath()
clip.addRect(CGRect(x: 0, y: 0, width: s, height: s))
clip.addPath(cutout)
ctx.addPath(clip)
ctx.clip(using: .evenOdd)
let moonFill = CGGradient(colorsSpace: space,
                          colors: [color(0.97, 0.97, 1), color(0.74, 0.82, 0.95)] as CFArray,
                          locations: [0, 1])!
ctx.addEllipse(in: CGRect(x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius,
                          width: moonRadius * 2, height: moonRadius * 2))
ctx.clip()
ctx.drawLinearGradient(moonFill, start: CGPoint(x: moonCenter.x - moonRadius, y: moonCenter.y + moonRadius),
                       end: CGPoint(x: moonCenter.x + moonRadius, y: moonCenter.y - moonRadius), options: [])
ctx.restoreGState()

// Sound-wave bars along the bottom, tallest in the middle.
let heights: [CGFloat] = [0.05, 0.08, 0.12, 0.17, 0.12, 0.08, 0.05]
let barWidth = s * 0.042
let gap = s * 0.034
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
let baseline = s * 0.25
ctx.setFillColor(color(0.596, 0.722, 0.902))
for (i, h) in heights.enumerated() {
    let height = s * h
    let rect = CGRect(x: (s - totalWidth) / 2 + CGFloat(i) * (barWidth + gap), y: baseline - height / 2,
                      width: barWidth, height: height)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
}
ctx.fillPath()

let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else {
    print("Could not write \(output.path)")
    exit(1)
}
print("wrote \(output.path)")
