#!/usr/bin/env swift
// Frames raw 1320x2868 simulator captures from build/store/raw/ into captioned App Store screenshots
// in build/store/screenshots/. Capture the raw images on the iPhone 17 Pro Max simulator
// (xcrun simctl io booted screenshot ...) with the status bar overridden to 9:41.
// Usage (from the repo root): swift scripts/make_store_screenshots.swift

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let rawDir = root.appendingPathComponent("build/store/raw")
let outputDir = root.appendingPathComponent("build/store/screenshots")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let shots: [(raw: String, title: String, subtitle: String)] = [
    ("1-playing", "Real nature,\nfor real sleep", "Pick a sound, set a timer, drift off"),
    ("2-sounds", "16 calming sounds", "Waterfalls, rain, ocean, forest and noise"),
    ("3-lock-screen", "Plays all night", "Keeps going with your phone locked"),
    ("4-about", "Private and offline", "No account, no ads, no data collected"),
]

let width = 1320, height = 2868
let w = CGFloat(width), h = CGFloat(height)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("Could not read \(url.path)")
        exit(1)
    }
    return image
}

/// Draws centred, wrapped text whose top edge sits at `top`, and returns the y of its bottom edge.
func drawText(_ text: String, in ctx: CGContext, top: CGFloat, size: CGFloat, weight: CTFontUIFontType,
              color textColor: CGColor) -> CGFloat {
    let font = CTFontCreateUIFontForLanguage(weight, size, nil)!
    var alignment = CTTextAlignment.center
    var lineSpacing = size * 0.08
    let style = withUnsafePointer(to: &alignment) { alignmentPointer in
        withUnsafePointer(to: &lineSpacing) { spacingPointer in
            let settings = [
                CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                        value: alignmentPointer),
                CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size,
                                        value: spacingPointer),
            ]
            return CTParagraphStyleCreate(settings, settings.count)
        }
    }
    let attributed = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
    ])
    let setter = CTFramesetterCreateWithAttributedString(attributed)
    let margin = w * 0.08
    let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                           CGSize(width: w - margin * 2, height: .greatestFiniteMagnitude), nil)
    let rect = CGRect(x: margin, y: h - top - ceil(fit.height), width: w - margin * 2, height: ceil(fit.height))
    let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, ctx)
    return top + ceil(fit.height)
}

for shot in shots {
    let screen = loadImage(rawDir.appendingPathComponent("\(shot.raw).png"))
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

    let sky = CGGradient(colorsSpace: space,
                         colors: [color(0.12, 0.17, 0.32), color(0.06, 0.08, 0.15), color(0.04, 0.05, 0.09)] as CFArray,
                         locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
    let glowCenter = CGPoint(x: w / 2, y: h * 0.86)
    let glow = CGGradient(colorsSpace: space,
                          colors: [color(0.596, 0.722, 0.902, 0.22), color(0.596, 0.722, 0.902, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: w * 0.8, options: [])

    let titleBottom = drawText(shot.title, in: ctx, top: 170, size: 112, weight: .emphasizedSystem,
                               color: color(0.96, 0.97, 1))
    let subtitleBottom = drawText(shot.subtitle, in: ctx, top: titleBottom + 36, size: 54, weight: .system,
                                  color: color(0.596, 0.722, 0.902))

    // The app screen, scaled to fit below the caption, with rounded corners and a thin outline.
    let top = subtitleBottom + 90
    let screenHeight = h - top - 110
    let screenWidth = screenHeight * CGFloat(screen.width) / CGFloat(screen.height)
    let frameRect = CGRect(x: (w - screenWidth) / 2, y: 110, width: screenWidth, height: screenHeight)
    let radius = screenWidth * 0.11
    let rounded = CGPath(roundedRect: frameRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 80, color: color(0, 0, 0, 0.55))
    ctx.addPath(rounded)
    ctx.setFillColor(color(0.04, 0.05, 0.09))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(rounded)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(screen, in: frameRect)
    ctx.restoreGState()

    ctx.addPath(rounded)
    ctx.setStrokeColor(color(1, 1, 1, 0.14))
    ctx.setLineWidth(4)
    ctx.strokePath()

    let url = outputDir.appendingPathComponent("\(shot.raw).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else {
        print("Could not write \(url.path)")
        exit(1)
    }
    print("wrote \(url.path)")
}
