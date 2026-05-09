import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum FitMode: String, CaseIterable, Identifiable {
    case stretch, fit, fill, center, manual
    var id: String { rawValue }

    var label: String {
        switch self {
        case .stretch: return "Strecken"
        case .fit:     return "Einpassen"
        case .fill:    return "Füllen"
        case .center:  return "Zentrieren"
        case .manual:  return "Manuell"
        }
    }
}

/// Image placement on the canvas in canvas-point coordinates (top-left origin).
/// Only used in `.manual` mode.
struct ManualTransform: Equatable {
    var imageOrigin: CGPoint   // top-left of image rect in canvas coords
    var imageSize: CGSize      // displayed image size in canvas points
}

enum RendererError: Error, LocalizedError {
    case loadFailed(URL)
    case renderFailed
    case writeFailed(URL)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let url):  return "Bild konnte nicht geladen werden: \(url.lastPathComponent)"
        case .renderFailed:         return "Rendering fehlgeschlagen."
        case .writeFailed(let url): return "Schreiben fehlgeschlagen: \(url.path)"
        }
    }
}

struct PerScreenImage {
    let monitor: MonitorInfo
    let url: URL
}

enum WallpaperRenderer {

    static func loadCGImage(from url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw RendererError.loadFailed(url) }
        return cg
    }

    /// Render the source image onto a canvas-sized bitmap according to `mode`,
    /// then crop one PNG per monitor at native pixel resolution. Returns the
    /// per-screen file URLs ready to hand to `NSWorkspace`.
    static func renderPerScreen(
        sourceImage: CGImage,
        layout: MonitorLayout,
        mode: FitMode,
        manualTransform: ManualTransform? = nil,
        bezelPoints: CGFloat = 0,
        outputDir: URL,
        timestamp: TimeInterval
    ) throws -> [PerScreenImage] {

        let canvasPixelSize = layout.canvasPixelSize(bezelPoints: bezelPoints)
        let canvasW = Int(canvasPixelSize.width.rounded())
        let canvasH = Int(canvasPixelSize.height.rounded())
        guard canvasW > 0, canvasH > 0 else { throw RendererError.renderFailed }

        guard let canvasImage = drawCanvas(
            source: sourceImage,
            canvasPixelWidth: canvasW,
            canvasPixelHeight: canvasH,
            mode: mode,
            manualTransform: manualTransform,
            canvasPointSize: layout.effectiveCanvas(bezelPoints: bezelPoints).size
        ) else { throw RendererError.renderFailed }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var results: [PerScreenImage] = []
        for monitor in layout.monitors {
            // Rect in canvas points → canvas pixels (top-left origin)
            let pointRect = layout.canvasLocalImageRect(for: monitor, bezelPoints: bezelPoints)
            let scale = layout.maxBackingScale
            let canvasPixelRect = CGRect(
                x: (pointRect.minX * scale).rounded(),
                y: (pointRect.minY * scale).rounded(),
                width: (pointRect.width * scale).rounded(),
                height: (pointRect.height * scale).rounded()
            )

            guard let cropped = canvasImage.cropping(to: canvasPixelRect) else {
                throw RendererError.renderFailed
            }

            // Resample to the monitor's native pixel size so the wallpaper is
            // delivered at native resolution rather than the canvas's super-
            // sampled size. Skip if scales already match.
            let targetPixelSize = monitor.pixelSize
            let finalImage: CGImage
            if abs(scale - monitor.backingScaleFactor) < 0.001 {
                finalImage = cropped
            } else {
                guard let resampled = resample(cropped, to: targetPixelSize) else {
                    throw RendererError.renderFailed
                }
                finalImage = resampled
            }

            let fileURL = outputDir.appendingPathComponent(
                "screen-\(monitor.id)-\(Int(timestamp)).png"
            )
            try writePNG(finalImage, to: fileURL)
            results.append(PerScreenImage(monitor: monitor, url: fileURL))
        }
        return results
    }

    // MARK: - Canvas drawing

    private static func drawCanvas(
        source: CGImage,
        canvasPixelWidth: Int,
        canvasPixelHeight: Int,
        mode: FitMode,
        manualTransform: ManualTransform?,
        canvasPointSize: CGSize
    ) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: canvasPixelWidth,
            height: canvasPixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Black background
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: canvasPixelWidth, height: canvasPixelHeight))
        ctx.interpolationQuality = .high

        let canvasW = CGFloat(canvasPixelWidth)
        let canvasH = CGFloat(canvasPixelHeight)
        let imgW = CGFloat(source.width)
        let imgH = CGFloat(source.height)

        // CGContext's coordinate system is bottom-left origin. We compute
        // destination rects assuming top-left origin (matches our crop math)
        // and flip Y at draw time.
        let destTopLeft: CGRect
        switch mode {
        case .stretch:
            destTopLeft = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)

        case .fit:
            let scale = min(canvasW / imgW, canvasH / imgH)
            let w = imgW * scale, h = imgH * scale
            destTopLeft = CGRect(x: (canvasW - w) / 2, y: (canvasH - h) / 2, width: w, height: h)

        case .fill:
            let scale = max(canvasW / imgW, canvasH / imgH)
            let w = imgW * scale, h = imgH * scale
            destTopLeft = CGRect(x: (canvasW - w) / 2, y: (canvasH - h) / 2, width: w, height: h)

        case .center:
            destTopLeft = CGRect(
                x: (canvasW - imgW) / 2,
                y: (canvasH - imgH) / 2,
                width: imgW,
                height: imgH
            )

        case .manual:
            // Convert transform from canvas points to canvas pixels.
            let t = manualTransform ?? ManualTransform(
                imageOrigin: .zero,
                imageSize: CGSize(width: canvasW, height: canvasH)
            )
            let sx = canvasPointSize.width  > 0 ? canvasW / canvasPointSize.width  : 1
            let sy = canvasPointSize.height > 0 ? canvasH / canvasPointSize.height : 1
            destTopLeft = CGRect(
                x: t.imageOrigin.x * sx,
                y: t.imageOrigin.y * sy,
                width: t.imageSize.width * sx,
                height: t.imageSize.height * sy
            )
        }

        let destBottomLeft = CGRect(
            x: destTopLeft.minX,
            y: canvasH - destTopLeft.maxY,
            width: destTopLeft.width,
            height: destTopLeft.height
        )

        ctx.draw(source, in: destBottomLeft)
        return ctx.makeImage()
    }

    private static func resample(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1, nil
        ) else { throw RendererError.writeFailed(url) }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw RendererError.writeFailed(url)
        }
    }
}
