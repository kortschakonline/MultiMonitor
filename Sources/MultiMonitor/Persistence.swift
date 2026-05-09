import Foundation
import CoreGraphics
import AppKit

// MARK: - Codable mirrors of runtime state

struct PersistedTransform: Codable, Equatable {
    var originX: Double
    var originY: Double
    var sizeW: Double
    var sizeH: Double
}

struct PersistedAssignment: Codable, Equatable {
    var sourceURL: URL?
    var mode: String          // FitMode rawValue
    var manualTransform: PersistedTransform?
}

struct PersistedState: Codable, Equatable {
    var splitMode: String                            // SplitMode rawValue
    var bezelPoints: Double
    var spanned: PersistedAssignment
    var perMonitor: [String: PersistedAssignment]    // keyed by displayID as string
    var autoReapply: Bool
    var recents: [String] = []                       // file paths, most-recent first

    enum CodingKeys: String, CodingKey {
        case splitMode, bezelPoints, spanned, perMonitor, autoReapply, recents
    }

    init(splitMode: String, bezelPoints: Double, spanned: PersistedAssignment,
         perMonitor: [String: PersistedAssignment], autoReapply: Bool, recents: [String] = []) {
        self.splitMode = splitMode
        self.bezelPoints = bezelPoints
        self.spanned = spanned
        self.perMonitor = perMonitor
        self.autoReapply = autoReapply
        self.recents = recents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.splitMode = try c.decode(String.self, forKey: .splitMode)
        self.bezelPoints = try c.decode(Double.self, forKey: .bezelPoints)
        self.spanned = try c.decode(PersistedAssignment.self, forKey: .spanned)
        self.perMonitor = try c.decode([String: PersistedAssignment].self, forKey: .perMonitor)
        self.autoReapply = try c.decode(Bool.self, forKey: .autoReapply)
        self.recents = (try? c.decode([String].self, forKey: .recents)) ?? []
    }
}

// MARK: - UserDefaults backing

enum Persistence {
    private static let key = "MultiMonitor.state.v1"

    static func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> PersistedState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Conversions to / from runtime types

extension MonitorAssignment {
    init(from p: PersistedAssignment) {
        self.init()
        self.sourceURL = p.sourceURL
        self.mode = FitMode(rawValue: p.mode) ?? .stretch
        self.manualTransform = p.manualTransform.map {
            ManualTransform(
                imageOrigin: CGPoint(x: $0.originX, y: $0.originY),
                imageSize: CGSize(width: $0.sizeW, height: $0.sizeH)
            )
        }
    }

    var persisted: PersistedAssignment {
        PersistedAssignment(
            sourceURL: sourceURL,
            mode: mode.rawValue,
            manualTransform: manualTransform.map {
                PersistedTransform(
                    originX: Double($0.imageOrigin.x),
                    originY: Double($0.imageOrigin.y),
                    sizeW: Double($0.imageSize.width),
                    sizeH: Double($0.imageSize.height)
                )
            }
        )
    }

    /// Reconstruct preview NSImage and pixel size from `sourceURL`.
    /// Returns true if a usable image was loaded.
    @discardableResult
    mutating func reloadPreview() -> Bool {
        guard let url = sourceURL else {
            sourcePreview = nil
            sourcePixelSize = .zero
            return false
        }
        sourcePreview = NSImage(contentsOf: url)
        if let cg = try? WallpaperRenderer.loadCGImage(from: url) {
            sourcePixelSize = CGSize(width: cg.width, height: cg.height)
            return true
        } else {
            sourcePixelSize = .zero
            return sourcePreview != nil
        }
    }
}

