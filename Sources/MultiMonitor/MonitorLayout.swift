import AppKit
import CoreGraphics

struct MonitorInfo: Identifiable, Hashable {
    let id: Int
    let displayID: CGDirectDisplayID
    let name: String
    let frame: CGRect           // points, global coords (bottom-left origin)
    let backingScaleFactor: CGFloat
    let isPrimary: Bool

    var pixelSize: CGSize {
        CGSize(width: frame.width * backingScaleFactor,
               height: frame.height * backingScaleFactor)
    }
}

struct MonitorLayout {
    let monitors: [MonitorInfo]
    let canvas: CGRect          // points, bounding box of all monitor frames

    var maxBackingScale: CGFloat {
        monitors.map(\.backingScaleFactor).max() ?? 2.0
    }

    var canvasPixelSize: CGSize {
        CGSize(width: canvas.width * maxBackingScale,
               height: canvas.height * maxBackingScale)
    }

    static func current() -> MonitorLayout {
        let screens = NSScreen.screens
        let primaryScreen = NSScreen.screens.first
        var infos: [MonitorInfo] = []
        for (idx, screen) in screens.enumerated() {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let info = MonitorInfo(
                id: idx,
                displayID: displayID,
                name: screen.localizedName,
                frame: screen.frame,
                backingScaleFactor: screen.backingScaleFactor,
                isPrimary: screen == primaryScreen
            )
            infos.append(info)
        }

        let canvas = infos.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        return MonitorLayout(monitors: infos, canvas: canvas == .null ? .zero : canvas)
    }

    /// Convert a screen frame (global, bottom-left origin) to canvas-local
    /// rect with top-left origin — i.e. the rect to crop out of a top-left
    /// indexed canvas image.
    func canvasLocalImageRect(for monitor: MonitorInfo) -> CGRect {
        let f = monitor.frame
        let xLocal = f.minX - canvas.minX
        let yFromTop = canvas.height - (f.maxY - canvas.minY)
        return CGRect(x: xLocal, y: yFromTop, width: f.width, height: f.height)
    }
}
