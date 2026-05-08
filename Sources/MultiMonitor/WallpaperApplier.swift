import AppKit

enum ApplierError: Error, LocalizedError {
    case screenNotFound(MonitorInfo)
    case setFailed(MonitorInfo, Error)

    var errorDescription: String? {
        switch self {
        case .screenNotFound(let m):
            return "Monitor \(m.name) wurde nicht mehr gefunden."
        case .setFailed(let m, let err):
            return "Wallpaper für \(m.name) konnte nicht gesetzt werden: \(err.localizedDescription)"
        }
    }
}

enum WallpaperApplier {

    /// Output directory for generated wallpapers.
    static var outputDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("MultiMonitor/wallpapers", isDirectory: true)
    }

    /// Apply each rendered image to its corresponding screen.
    /// Looks the actual NSScreen back up by displayID at apply-time so
    /// hot-plug changes between render and apply don't crash us.
    static func apply(_ images: [PerScreenImage]) throws {
        let screens = NSScreen.screens
        let workspace = NSWorkspace.shared

        for image in images {
            guard let screen = screens.first(where: { matchesDisplayID($0, image.monitor.displayID) })
            else { throw ApplierError.screenNotFound(image.monitor) }

            do {
                try workspace.setDesktopImageURL(image.url, for: screen, options: [:])
            } catch {
                throw ApplierError.setFailed(image.monitor, error)
            }
        }
    }

    /// Best-effort cleanup of older generated wallpapers (keep the 6 newest).
    static func pruneOldOutputs() {
        let dir = outputDirectory
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = items.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for url in sorted.dropFirst(6) {
            try? fm.removeItem(at: url)
        }
    }

    private static func matchesDisplayID(_ screen: NSScreen, _ displayID: CGDirectDisplayID) -> Bool {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return id == displayID
    }
}
