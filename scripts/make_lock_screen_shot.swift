#!/usr/bin/env swift
// The simulator's Lock Screen player has no transport controls, so this adds the row a real iPhone shows
// (rewind and forward dimmed, play, AirPlay) to build/store/raw/3-lock-screen-sim.png and writes
// build/store/raw/3-lock-screen.png for make_store_screenshots.swift.
// Usage (from the repo root): swift scripts/make_lock_screen_shot.swift

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let input = root.appendingPathComponent("build/store/raw/3-lock-screen-sim.png")
let output = root.appendingPathComponent("build/store/raw/3-lock-screen.png")

guard let data = try? Data(contentsOf: input), let source = NSBitmapImageRep(data: data),
      let base = source.cgImage else {
    print("Could not read \(input.path)")
    exit(1)
}
let width = base.width, height = base.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

// Player card measured on the 1320x2868 iPhone 17 Pro Max capture (top-left origin).
let cardLeft: CGFloat = 63, cardWidth: CGFloat = 1194
let rowCenterY: CGFloat = 2326
func flip(_ y: CGFloat) -> CGFloat { CGFloat(height) - y }

// Cover the simulator's volume glyph, blending each row between the card colours on either side.
let patch = CGRect(x: 1080, y: rowCenterY - 60, width: 150, height: 120)
let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
func canvasColor(x: Int, y: Int) -> CGColor {
    let offset = y * ctx.bytesPerRow + x * 4
    return CGColor(colorSpace: space, components: [CGFloat(pixels[offset]) / 255, CGFloat(pixels[offset + 1]) / 255,
                                                   CGFloat(pixels[offset + 2]) / 255, 1])!
}
for row in Int(patch.minY)..<Int(patch.maxY) {
    let left = canvasColor(x: Int(patch.minX) - 1, y: row)
    let right = canvasColor(x: Int(patch.maxX) + 1, y: row)
    guard let gradient = CGGradient(colorsSpace: space, colors: [left, right] as CFArray,
                                    locations: [0, 1]) else { continue }
    let y = flip(CGFloat(row) + 1)
    ctx.saveGState()
    ctx.clip(to: CGRect(x: patch.minX, y: y, width: patch.width, height: 1))
    ctx.drawLinearGradient(gradient, start: CGPoint(x: patch.minX, y: y), end: CGPoint(x: patch.maxX, y: y), options: [])
    ctx.restoreGState()
}

func drawSymbol(_ name: String, centerX fraction: CGFloat, pointSize: CGFloat, alpha: CGFloat) {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: alpha)]))
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        print("Missing symbol \(name)")
        exit(1)
    }
    var rect = CGRect(origin: .zero, size: symbol.size)
    guard let image = symbol.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { exit(1) }
    let size = symbol.size
    let center = CGPoint(x: cardLeft + cardWidth * fraction, y: flip(rowCenterY))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                               width: size.width, height: size.height))
}

drawSymbol("backward.fill", centerX: 0.297, pointSize: 70, alpha: 0.3)
drawSymbol("play.fill", centerX: 0.502, pointSize: 96, alpha: 1)
drawSymbol("forward.fill", centerX: 0.704, pointSize: 70, alpha: 0.3)
drawSymbol("airplay.audio", centerX: 0.904, pointSize: 54, alpha: 0.55)

let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else {
    print("Could not write \(output.path)")
    exit(1)
}
print("wrote \(output.path)")
