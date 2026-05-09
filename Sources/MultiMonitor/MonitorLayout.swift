import AppKit
import CoreGraphics

struct MonitorInfo: Identifiable, Hashable {
    let id: Int                 // 0-based, left-to-right
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
    let monitors: [MonitorInfo]   // sorted left-to-right by frame.minX
    let canvas: CGRect            // points, bounding box (no bezel)

    var maxBackingScale: CGFloat {
        monitors.map(\.backingScaleFactor).max() ?? 2.0
    }

    // MARK: - Bezel-aware geometry

    /// Canvas widened to make room for virtual gaps between adjacent monitors.
    /// `bezelPoints` is the gap inserted between each consecutive pair, in
    /// canvas points. Only horizontal expansion is applied (assumes monitors
    /// are arranged primarily in a row).
    func effectiveCanvas(bezelPoints: CGFloat = 0) -> CGRect {
        guard bezelPoints > 0, monitors.count > 1 else { return canvas }
        return CGRect(
            x: canvas.minX,
            y: canvas.minY,
            width: canvas.width + bezelPoints * CGFloat(monitors.count - 1),
            height: canvas.height
        )
    }

    func canvasPixelSize(bezelPoints: CGFloat = 0) -> CGSize {
        let c = effectiveCanvas(bezelPoints: bezelPoints)
        return CGSize(width: c.width * maxBackingScale,
                      height: c.height * maxBackingScale)
    }

    /// Position of the given monitor within the (possibly bezel-expanded)
    /// canvas, in image coordinates (top-left origin, in canvas points).
    func canvasLocalImageRect(for monitor: MonitorInfo, bezelPoints: CGFloat = 0) -> CGRect {
        let f = monitor.frame
        let xLocal = f.minX - canvas.minX
        let shiftX = bezelPoints * CGFloat(monitor.id)
        let effCanvas = effectiveCanvas(bezelPoints: bezelPoints)
        let yFromTop = effCanvas.height - (f.maxY - canvas.minY)
        return CGRect(x: xLocal + shiftX, y: yFromTop, width: f.width, height: f.height)
    }

    // MARK: - Construction

    static func current() -> MonitorLayout {
        let screens = NSScreen.screens
        let primaryScreen = screens.first

        // Build raw tuples, sort by X, then assign 0..n-1 ids in left-to-right order.
        let raw: [(CGRect, CGDirectDisplayID, String, CGFloat, Bool)] = screens.map { screen in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return (screen.frame, displayID, screen.localizedName, screen.backingScaleFactor, screen == primaryScreen)
        }
        let sorted = raw.sorted { $0.0.minX < $1.0.minX }

        var infos: [MonitorInfo] = []
        for (idx, item) in sorted.enumerated() {
            infos.append(MonitorInfo(
                id: idx,
                displayID: item.1,
                name: item.2,
                frame: item.0,
                backingScaleFactor: item.3,
                isPrimary: item.4
            ))
        }

        let canvas = infos.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        return MonitorLayout(monitors: infos, canvas: canvas == .null ? .zero : canvas)
    }
}
