#!/usr/bin/env swift
//
// Generates Resources/AppIcon.iconset/icon_512x512@2x.png (1024×1024).
// build.sh then uses `sips` + `iconutil` to produce AppIcon.icns.
//
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil,
    width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("CGContext failed") }

// macOS-style rounded square
let cornerRadius: CGFloat = size * 0.225
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

// Deep blue → purple background gradient
let bgColors: CFArray = [
    CGColor(red: 0.06, green: 0.05, blue: 0.18, alpha: 1.0),
    CGColor(red: 0.20, green: 0.09, blue: 0.36, alpha: 1.0),
] as CFArray
let bgGrad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1])!
ctx.drawLinearGradient(
    bgGrad,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

// Two side-by-side landscape monitors, 16:9, slightly above center
let count = 2
let monitorAreaW: CGFloat = size * 0.78
let gap: CGFloat = size * 0.022
let oneW = (monitorAreaW - gap * CGFloat(count - 1)) / CGFloat(count)
let oneH = oneW * (9.0 / 16.0)
let monitorAreaH = oneH
let monitorAreaX = (size - monitorAreaW) / 2
let monitorAreaY = size * 0.50 - monitorAreaH / 2 + size * 0.04   // tiny lift so stand fits
let monitorArea = CGRect(x: monitorAreaX, y: monitorAreaY, width: monitorAreaW, height: monitorAreaH)
let monitorCornerRadius: CGFloat = size * 0.020

// Build monitor path
let monitorsPath = CGMutablePath()
var monitorRects: [CGRect] = []
for i in 0..<count {
    let x = monitorArea.minX + CGFloat(i) * (oneW + gap)
    let r = CGRect(x: x, y: monitorArea.minY, width: oneW, height: oneH)
    monitorRects.append(r)
    monitorsPath.addPath(CGPath(
        roundedRect: r,
        cornerWidth: monitorCornerRadius,
        cornerHeight: monitorCornerRadius,
        transform: nil
    ))
}

// Soft outer shadow under the screens
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -size * 0.014),
    blur: size * 0.045,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
)
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.addPath(monitorsPath)
ctx.fillPath()
ctx.restoreGState()

// Wallpaper gradient that spans both rects continuously (left → right)
let wpColors: CFArray = [
    CGColor(red: 1.00, green: 0.34, blue: 0.52, alpha: 1.0),  // pink
    CGColor(red: 1.00, green: 0.62, blue: 0.20, alpha: 1.0),  // orange
    CGColor(red: 0.95, green: 0.86, blue: 0.20, alpha: 1.0),  // yellow
    CGColor(red: 0.36, green: 0.86, blue: 1.00, alpha: 1.0),  // cyan
] as CFArray
let wpGrad = CGGradient(colorsSpace: cs, colors: wpColors, locations: [0.0, 0.35, 0.65, 1.0])!

ctx.saveGState()
ctx.addPath(monitorsPath)
ctx.clip()
ctx.drawLinearGradient(
    wpGrad,
    start: CGPoint(x: monitorArea.minX, y: monitorArea.midY),
    end: CGPoint(x: monitorArea.maxX, y: monitorArea.midY),
    options: []
)
// Top-down highlight gloss across both screens
let glossColors: CFArray = [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.24),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
] as CFArray
let glossGrad = CGGradient(colorsSpace: cs, colors: glossColors, locations: [0, 1])!
ctx.drawLinearGradient(
    glossGrad,
    start: CGPoint(x: 0, y: monitorArea.maxY),
    end: CGPoint(x: 0, y: monitorArea.minY + monitorArea.height * 0.35),
    options: []
)
ctx.restoreGState()

// Subtle screen edge highlights
ctx.saveGState()
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.20))
ctx.setLineWidth(size * 0.0035)
for r in monitorRects {
    ctx.addPath(CGPath(
        roundedRect: r.insetBy(dx: size * 0.0017, dy: size * 0.0017),
        cornerWidth: monitorCornerRadius,
        cornerHeight: monitorCornerRadius,
        transform: nil
    ))
    ctx.strokePath()
}
ctx.restoreGState()

// Stand under the gap between monitors (centered on the seam)
let seamX = (monitorRects[0].maxX + monitorRects[1].minX) / 2
let standW = oneW * 0.32
let standH = size * 0.06
let standRect = CGRect(
    x: seamX - standW / 2,
    y: monitorArea.minY - standH,
    width: standW,
    height: standH
)
ctx.saveGState()
let standColors: CFArray = [
    CGColor(gray: 0.22, alpha: 1),
    CGColor(gray: 0.10, alpha: 1),
] as CFArray
let standGrad = CGGradient(colorsSpace: cs, colors: standColors, locations: [0, 1])!
let standPath = CGPath(
    roundedRect: standRect,
    cornerWidth: size * 0.010,
    cornerHeight: size * 0.010,
    transform: nil
)
ctx.addPath(standPath)
ctx.clip()
ctx.drawLinearGradient(
    standGrad,
    start: CGPoint(x: 0, y: standRect.maxY),
    end: CGPoint(x: 0, y: standRect.minY),
    options: []
)
ctx.restoreGState()

// Foot
let footW = oneW * 0.85
let footH = size * 0.022
let footRect = CGRect(
    x: seamX - footW / 2,
    y: standRect.minY - footH,
    width: footW,
    height: footH
)
ctx.saveGState()
ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
ctx.addPath(CGPath(
    roundedRect: footRect,
    cornerWidth: footH / 2,
    cornerHeight: footH / 2,
    transform: nil
))
ctx.fillPath()
ctx.restoreGState()

ctx.restoreGState()  // bg clip

// Write PNG
guard let cg = ctx.makeImage() else { fatalError("makeImage failed") }
let outputDir = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
let outURL = URL(fileURLWithPath: "\(outputDir)/icon_512x512@2x.png")
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("CGImageDestination failed") }
CGImageDestinationAddImage(dest, cg, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG finalize failed") }
print("✓ \(outURL.path)")
