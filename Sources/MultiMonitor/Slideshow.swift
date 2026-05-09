import Foundation
import AppKit

/// Drives a periodic rotation of wallpapers from a folder. Cycles through
/// the active assignment via `AppModel.loadSource(_:addToRecents:)` followed
/// by `AppModel.apply()`.
@MainActor
final class Slideshow: ObservableObject {
    @Published var folderURL: URL?
    @Published var intervalMinutes: Double = 5
    @Published var randomOrder: Bool = false
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var currentImageURL: URL?
    @Published private(set) var nextChangeAt: Date?
    @Published private(set) var imageCount: Int = 0

    weak var model: AppModel?

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif",
        "tiff", "tif", "gif", "webp", "bmp"
    ]

    private var imageURLs: [URL] = []
    private var currentIndex: Int = 0
    private var timer: Timer?

    // MARK: - Folder

    func setFolder(_ url: URL?) {
        folderURL = url
        reloadImageList()
        if isRunning && imageURLs.isEmpty { stop() }
    }

    func reloadImageList() {
        guard let folder = folderURL else {
            imageURLs = []
            imageCount = 0
            currentIndex = 0
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        imageURLs = files
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                    == .orderedAscending
            }
        imageCount = imageURLs.count
        currentIndex = 0
    }

    // MARK: - Control

    func start() {
        guard !imageURLs.isEmpty, model != nil else { return }
        isRunning = true
        tick()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        nextChangeAt = nil
    }

    func skipForward() {
        guard isRunning else { return }
        tick()
    }

    // MARK: - Internals

    private func tick() {
        guard !imageURLs.isEmpty, let model = model else { return }
        let url: URL
        if randomOrder {
            url = imageURLs.randomElement() ?? imageURLs[0]
        } else {
            url = imageURLs[currentIndex % imageURLs.count]
            currentIndex = (currentIndex + 1) % imageURLs.count
        }
        currentImageURL = url
        model.loadSource(url, addToRecents: false)
        model.apply()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = max(15, intervalMinutes * 60)
        let when = Date().addingTimeInterval(interval)
        nextChangeAt = when
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
}
