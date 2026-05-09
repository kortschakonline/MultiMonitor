import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Models

struct MonitorAssignment {
    var sourceURL: URL?
    var sourcePreview: NSImage?
    var sourcePixelSize: CGSize = .zero
    var mode: FitMode = .stretch
    var manualTransform: ManualTransform?
}

enum SplitMode: String, CaseIterable, Identifiable {
    case spanned, perMonitor
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spanned:    return "Spannen"
        case .perMonitor: return "Pro Monitor"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var layout: MonitorLayout = .current()
    @Published var splitMode: SplitMode = .spanned { didSet { savePersistedState() } }
    @Published var bezelPoints: CGFloat = 0       { didSet { savePersistedState() } }
    @Published var autoReapply: Bool = true       { didSet { savePersistedState() } }
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var status: String = "Bereit. Ziehe ein Bild hierher."
    @Published var isWorking: Bool = false

    @Published var spanned: MonitorAssignment = .init()
    @Published var perMonitor: [CGDirectDisplayID: MonitorAssignment] = [:]
    @Published var recents: [URL] = []
    let slideshow = Slideshow()
    private var cancellables = Set<AnyCancellable>()
    private static let recentsLimit = 20

    init() {
        selectedDisplayID = layout.monitors.first?.displayID
        slideshow.model = self
        restorePersistedState()

        // Persist slideshow settings whenever the user tweaks them.
        slideshow.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.savePersistedState() }
            }
            .store(in: &cancellables)
    }

    func refreshLayout() {
        let oldMonitorCount = layout.monitors.count
        layout = .current()
        // Validate selection — if previously selected display is gone, pick first.
        if let id = selectedDisplayID,
           !layout.monitors.contains(where: { $0.displayID == id }) {
            selectedDisplayID = layout.monitors.first?.displayID
        } else if selectedDisplayID == nil {
            selectedDisplayID = layout.monitors.first?.displayID
        }
        if activeAssignment.mode == .manual { ensureManualTransform() }

        // Auto-reapply on hot-plug, only if the count actually changed (avoid
        // re-applying for spurious notifications like wake-from-sleep with
        // identical setup).
        if autoReapply,
           layout.monitors.count != oldMonitorCount,
           canApply {
            apply()
        }
    }

    // MARK: - Active assignment dispatch

    var activeAssignment: MonitorAssignment {
        get {
            switch splitMode {
            case .spanned: return spanned
            case .perMonitor:
                guard let id = selectedDisplayID else { return MonitorAssignment() }
                return perMonitor[id] ?? MonitorAssignment()
            }
        }
        set {
            switch splitMode {
            case .spanned: spanned = newValue
            case .perMonitor:
                guard let id = selectedDisplayID else { return }
                perMonitor[id] = newValue
            }
        }
    }

    /// The canvas the active assignment is positioned in.
    /// Spanned: bezel-expanded global canvas. PerMonitor: selected display only.
    var activeCanvas: CGRect {
        switch splitMode {
        case .spanned:
            return layout.effectiveCanvas(bezelPoints: bezelPoints)
        case .perMonitor:
            guard let id = selectedDisplayID,
                  let m = layout.monitors.first(where: { $0.displayID == id }) else { return .zero }
            return CGRect(origin: .zero, size: m.frame.size)
        }
    }

    // MARK: - Loading source images

    func loadSource(_ url: URL, addToRecents: Bool = true) {
        var a = activeAssignment
        a.sourceURL = url
        a.sourcePreview = NSImage(contentsOf: url)
        if let cg = try? WallpaperRenderer.loadCGImage(from: url) {
            a.sourcePixelSize = CGSize(width: cg.width, height: cg.height)
        } else {
            a.sourcePixelSize = .zero
        }
        a.manualTransform = nil
        activeAssignment = a
        if a.sourcePreview == nil {
            status = "Bild konnte nicht gelesen werden."
        } else {
            status = "Bild geladen: \(url.lastPathComponent)"
            if addToRecents { self.addRecent(url) }
        }
        if a.mode == .manual { ensureManualTransform() }
        savePersistedState()
    }

    // MARK: - Recents

    func addRecent(_ url: URL) {
        var list = recents.filter { $0 != url }
        list.insert(url, at: 0)
        if list.count > Self.recentsLimit { list = Array(list.prefix(Self.recentsLimit)) }
        recents = list
    }

    func removeRecent(_ url: URL) {
        recents.removeAll { $0 == url }
        savePersistedState()
    }

    func clearRecents() {
        recents.removeAll()
        savePersistedState()
    }

    /// Per-monitor variant: select the given monitor first, then load.
    func loadSource(_ url: URL, intoDisplayID id: CGDirectDisplayID) {
        if splitMode == .perMonitor { selectedDisplayID = id }
        loadSource(url)
    }

    // MARK: - Mode

    func setMode(_ newMode: FitMode) {
        var a = activeAssignment
        a.mode = newMode
        activeAssignment = a
        if newMode == .manual { ensureManualTransform() }
        savePersistedState()
    }

    // MARK: - Manual transform

    func ensureManualTransform() {
        if activeAssignment.manualTransform == nil { resetManualTransform() }
    }

    func resetManualTransform() {
        let canvas = activeCanvas
        let a0 = activeAssignment
        let imgSize = a0.sourcePixelSize == .zero
            ? (a0.sourcePreview?.size ?? .zero)
            : a0.sourcePixelSize
        var a = a0
        guard canvas.width > 0, canvas.height > 0,
              imgSize.width > 0, imgSize.height > 0 else {
            a.manualTransform = nil
            activeAssignment = a
            return
        }
        let scale = max(canvas.width / imgSize.width, canvas.height / imgSize.height)
        let w = imgSize.width * scale
        let h = imgSize.height * scale
        let origin = CGPoint(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2)
        a.manualTransform = ManualTransform(imageOrigin: origin, imageSize: CGSize(width: w, height: h))
        activeAssignment = a
        savePersistedState()
    }

    /// Persist after a pan/zoom interaction completes (called by overlay on mouseUp).
    func commitInteractiveTransform() {
        savePersistedState()
    }

    func panBy(canvasDelta: CGSize) {
        var a = activeAssignment
        guard var t = a.manualTransform else { return }
        t.imageOrigin.x += canvasDelta.width
        t.imageOrigin.y += canvasDelta.height
        a.manualTransform = t
        activeAssignment = a
    }

    func zoom(at canvasPoint: CGPoint, deltaPixels: CGFloat) {
        var a = activeAssignment
        guard var t = a.manualTransform else { return }
        let factor = pow(1.0015, deltaPixels)
        let clampedFactor = max(0.92, min(1.08, factor))
        let canvas = activeCanvas
        let minDim = min(canvas.width, canvas.height) * 0.1
        let maxDim = max(canvas.width, canvas.height) * 50
        let candidateW = t.imageSize.width * clampedFactor
        let candidateH = t.imageSize.height * clampedFactor
        if candidateW < minDim || candidateH < minDim { return }
        if candidateW > maxDim || candidateH > maxDim { return }
        let newOriginX = canvasPoint.x - (canvasPoint.x - t.imageOrigin.x) * clampedFactor
        let newOriginY = canvasPoint.y - (canvasPoint.y - t.imageOrigin.y) * clampedFactor
        t.imageOrigin = CGPoint(x: newOriginX, y: newOriginY)
        t.imageSize = CGSize(width: candidateW, height: candidateH)
        a.manualTransform = t
        activeAssignment = a
    }

    // MARK: - Apply

    var canApply: Bool {
        if isWorking { return false }
        switch splitMode {
        case .spanned: return spanned.sourceURL != nil
        case .perMonitor: return perMonitor.values.contains(where: { $0.sourceURL != nil })
        }
    }

    func apply() {
        switch splitMode {
        case .spanned:    applySpanned()
        case .perMonitor: applyPerMonitor()
        }
    }

    private func applySpanned() {
        guard let url = spanned.sourceURL else {
            status = "Erst ein Bild auswählen."
            return
        }
        isWorking = true
        status = "Rendere und setze Wallpaper …"
        let mode = spanned.mode
        let transform = spanned.manualTransform
        let layout = self.layout
        let bezel = self.bezelPoints

        Task.detached {
            do {
                let cg = try WallpaperRenderer.loadCGImage(from: url)
                let outDir = WallpaperApplier.outputDirectory
                let ts = Date().timeIntervalSince1970
                let images = try WallpaperRenderer.renderPerScreen(
                    sourceImage: cg, layout: layout, mode: mode,
                    manualTransform: transform, bezelPoints: bezel,
                    outputDir: outDir, timestamp: ts
                )
                try await MainActor.run { try WallpaperApplier.apply(images) }
                WallpaperApplier.pruneOldOutputs()
                await MainActor.run {
                    self.status = "Wallpaper auf \(images.count) Monitor(en) gesetzt."
                    self.isWorking = false
                    self.savePersistedState()
                }
            } catch {
                await MainActor.run {
                    self.status = "Fehler: \(error.localizedDescription)"
                    self.isWorking = false
                }
            }
        }
    }

    private func applyPerMonitor() {
        let pairs: [(MonitorInfo, MonitorAssignment)] = layout.monitors.compactMap { m in
            guard let a = perMonitor[m.displayID], a.sourceURL != nil else { return nil }
            return (m, a)
        }
        guard !pairs.isEmpty else {
            status = "Kein Monitor hat ein Bild zugewiesen."
            return
        }
        isWorking = true
        status = "Rendere und setze \(pairs.count) Wallpaper …"
        let totalMonitors = layout.monitors.count

        Task.detached {
            do {
                let outDir = WallpaperApplier.outputDirectory
                let ts = Date().timeIntervalSince1970
                var collected: [PerScreenImage] = []
                for (monitor, a) in pairs {
                    guard let url = a.sourceURL else { continue }
                    let cg = try WallpaperRenderer.loadCGImage(from: url)
                    let img = try WallpaperRenderer.renderSingleMonitor(
                        sourceImage: cg, monitor: monitor, mode: a.mode,
                        manualTransform: a.manualTransform,
                        outputDir: outDir, timestamp: ts
                    )
                    collected.append(img)
                }
                let results = collected
                try await MainActor.run { try WallpaperApplier.apply(results) }
                WallpaperApplier.pruneOldOutputs()
                await MainActor.run {
                    self.status = "Wallpaper auf \(results.count) von \(totalMonitors) Monitor(en) gesetzt."
                    self.isWorking = false
                    self.savePersistedState()
                }
            } catch {
                await MainActor.run {
                    self.status = "Fehler: \(error.localizedDescription)"
                    self.isWorking = false
                }
            }
        }
    }

    // MARK: - Persistence

    func savePersistedState() {
        var pm: [String: PersistedAssignment] = [:]
        for (displayID, a) in perMonitor {
            pm[String(displayID)] = a.persisted
        }
        let state = PersistedState(
            splitMode: splitMode.rawValue,
            bezelPoints: Double(bezelPoints),
            spanned: spanned.persisted,
            perMonitor: pm,
            autoReapply: autoReapply,
            recents: recents.map(\.path),
            slideshow: PersistedSlideshow(
                folderPath: slideshow.folderURL?.path,
                intervalMinutes: slideshow.intervalMinutes,
                randomOrder: slideshow.randomOrder
            )
        )
        Persistence.save(state)
    }

    private func restorePersistedState() {
        guard let state = Persistence.load() else { return }
        autoReapply = state.autoReapply
        bezelPoints = CGFloat(state.bezelPoints)
        splitMode = SplitMode(rawValue: state.splitMode) ?? .spanned

        var spannedAssign = MonitorAssignment(from: state.spanned)
        spannedAssign.reloadPreview()
        spanned = spannedAssign

        var pm: [CGDirectDisplayID: MonitorAssignment] = [:]
        for (idStr, persisted) in state.perMonitor {
            guard let displayID = CGDirectDisplayID(idStr) else { continue }
            var a = MonitorAssignment(from: persisted)
            a.reloadPreview()
            pm[displayID] = a
        }
        perMonitor = pm

        let fm = FileManager.default
        recents = state.recents
            .map { URL(fileURLWithPath: $0) }
            .filter { fm.fileExists(atPath: $0.path) }

        // Slideshow settings (don't auto-start)
        slideshow.intervalMinutes = state.slideshow.intervalMinutes
        slideshow.randomOrder = state.slideshow.randomOrder
        if let path = state.slideshow.folderPath {
            let folder = URL(fileURLWithPath: path)
            if fm.fileExists(atPath: folder.path) {
                slideshow.setFolder(folder)
            }
        }

        if spanned.sourceURL != nil || !perMonitor.isEmpty {
            status = "Letzten Zustand wiederhergestellt."
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showRecents = false
    @State private var showSlideshow = false

    var body: some View {
        VStack(spacing: 12) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if model.layout.monitors.count >= 2 {
                Picker("Aufteilung", selection: $model.splitMode) {
                    ForEach(SplitMode.allCases) { sm in
                        Text(sm.label).tag(sm)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
            }

            HStack {
                Button {
                    pickFile()
                } label: {
                    Label(pickFileLabel, systemImage: "photo")
                }
                Button {
                    showRecents.toggle()
                } label: {
                    Label("Bibliothek", systemImage: "clock.arrow.circlepath")
                }
                .disabled(model.recents.isEmpty)
                .help(model.recents.isEmpty
                    ? "Noch keine Bilder geladen."
                    : "Letzte Bilder schnell wieder anwenden.")
                .popover(isPresented: $showRecents, arrowEdge: .bottom) {
                    RecentsView(model: model) { showRecents = false }
                }
                Button {
                    showSlideshow.toggle()
                } label: {
                    Label(
                        model.slideshow.isRunning ? "Slideshow läuft" : "Slideshow",
                        systemImage: model.slideshow.isRunning ? "play.circle.fill" : "play.circle"
                    )
                }
                .help("Bilder aus einem Ordner automatisch rotieren.")
                .popover(isPresented: $showSlideshow, arrowEdge: .bottom) {
                    SlideshowView(slideshow: model.slideshow)
                }
                if let url = model.activeAssignment.sourceURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if model.activeAssignment.mode == .manual && model.activeAssignment.sourcePreview != nil {
                    Button("Zurücksetzen") { model.resetManualTransform() }
                        .help("Bild wieder auf Canvas einpassen (Füllen).")
                }
            }

            Picker("Modus", selection: Binding(
                get: { model.activeAssignment.mode },
                set: { model.setMode($0) }
            )) {
                ForEach(FitMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if model.splitMode == .spanned && model.layout.monitors.count >= 2 {
                bezelControl
            }

            HStack {
                Text(displayedStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(isOn: $model.autoReapply) {
                    Text("Auto-Reapply")
                        .font(.callout)
                }
                .toggleStyle(.checkbox)
                .help("Beim An- oder Abstecken eines Monitors automatisch erneut anwenden.")
                Button(action: { model.apply() }) {
                    Label("Anwenden", systemImage: "checkmark.circle.fill")
                }
                .keyboardShortcut(.return)
                .disabled(!model.canApply)
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 520)
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: nil) { providers in
            handleDrop(providers: providers, atDisplayID: nil)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            model.refreshLayout()
        }
    }

    private var displayedStatus: String {
        var s = model.status
        if model.splitMode == .perMonitor,
           let id = model.selectedDisplayID,
           let m = model.layout.monitors.first(where: { $0.displayID == id }) {
            s = "[\(m.name)] " + s
        }
        if model.activeAssignment.mode == .manual && model.activeAssignment.sourcePreview != nil {
            s += "  ·  Ziehen = verschieben, Scrollen = zoomen"
        }
        return s
    }

    private var pickFileLabel: String {
        switch model.splitMode {
        case .spanned: return "Bild auswählen …"
        case .perMonitor:
            if let id = model.selectedDisplayID,
               let m = model.layout.monitors.first(where: { $0.displayID == id }) {
                return "Bild für \(m.name) …"
            }
            return "Bild auswählen …"
        }
    }

    @ViewBuilder
    private var bezelControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
                .foregroundStyle(.secondary)
                .help("Bezel-Korrektur: virtuelle Lücke zwischen Monitoren, " +
                      "damit das Bild physikalisch durchläuft.")
            Text("Bezel-Lücke")
                .font(.callout)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(model.bezelPoints) },
                    set: { v in
                        model.bezelPoints = CGFloat(v)
                        if model.activeAssignment.mode == .manual { model.resetManualTransform() }
                    }
                ),
                in: 0...200
            )
            Text("\(Int(model.bezelPoints)) pt")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Button("0") {
                model.bezelPoints = 0
                if model.activeAssignment.mode == .manual { model.resetManualTransform() }
            }
            .buttonStyle(.borderless)
            .help("Bezel-Korrektur ausschalten.")
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        GeometryReader { geo in
            let layout = model.layout
            let bezel = (model.splitMode == .spanned) ? model.bezelPoints : 0
            let canvas = layout.effectiveCanvas(bezelPoints: bezel)
            let inset: CGFloat = 16
            let availW = max(geo.size.width - inset * 2, 1)
            let availH = max(geo.size.height - inset * 2, 1)
            let scale: CGFloat = (canvas.width > 0 && canvas.height > 0)
                ? min(availW / canvas.width, availH / canvas.height)
                : 1
            let displayW = canvas.width * scale
            let displayH = canvas.height * scale
            let originX = (geo.size.width - displayW) / 2
            let originY = (geo.size.height - displayH) / 2

            ZStack(alignment: .topLeading) {
                if model.splitMode == .spanned {
                    if let img = model.spanned.sourcePreview {
                        spannedProjectedImage(img: img, scale: scale)
                            .mask(monitorsMask(scale: scale, bezel: bezel))
                            .offset(x: originX, y: originY)
                    }
                } else {
                    // Per-monitor: each display renders independently
                    ForEach(layout.monitors) { monitor in
                        let local = layout.canvasLocalImageRect(for: monitor, bezelPoints: 0)
                        let r = CGRect(
                            x: originX + local.minX * scale,
                            y: originY + local.minY * scale,
                            width: local.width * scale,
                            height: local.height * scale
                        )
                        if let a = model.perMonitor[monitor.displayID], let img = a.sourcePreview {
                            perMonitorProjectedImage(
                                img: img,
                                monitor: monitor,
                                assignment: a,
                                scale: scale
                            )
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                        }
                    }
                }

                // Monitor outlines + selection highlight
                ForEach(layout.monitors) { monitor in
                    let local = layout.canvasLocalImageRect(for: monitor, bezelPoints: bezel)
                    let r = CGRect(
                        x: originX + local.minX * scale,
                        y: originY + local.minY * scale,
                        width: local.width * scale,
                        height: local.height * scale
                    )
                    monitorTile(
                        monitor: monitor,
                        rect: r,
                        isSelected: model.splitMode == .perMonitor &&
                                    model.selectedDisplayID == monitor.displayID,
                        showHint: model.splitMode == .perMonitor &&
                                  model.perMonitor[monitor.displayID]?.sourcePreview == nil
                    )
                    .onTapGesture {
                        if model.splitMode == .perMonitor {
                            model.selectedDisplayID = monitor.displayID
                        }
                    }
                    .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: nil) { providers in
                        handleDrop(providers: providers, atDisplayID: monitor.displayID)
                    }
                }

                // Interactive overlay (manual mode, attached to active canvas)
                if model.activeAssignment.mode == .manual,
                   model.activeAssignment.sourcePreview != nil {
                    let activeRect = activeCanvasRectInPreview(
                        scale: scale, bezel: bezel, originX: originX, originY: originY
                    )
                    InteractiveOverlay(
                        previewScale: scale,
                        onPan: { delta in
                            model.panBy(canvasDelta: CGSize(
                                width: delta.width / scale,
                                height: delta.height / scale
                            ))
                        },
                        onZoom: { localPoint, deltaY in
                            let canvasPoint = CGPoint(
                                x: localPoint.x / scale,
                                y: localPoint.y / scale
                            )
                            model.zoom(at: canvasPoint, deltaPixels: deltaY)
                        }
                    )
                    .frame(width: activeRect.width, height: activeRect.height)
                    .offset(x: activeRect.minX, y: activeRect.minY)
                }
            }
        }
    }

    /// Where (in preview coords) the active canvas sits — used to place the
    /// interactive overlay for manual pan/zoom.
    private func activeCanvasRectInPreview(scale: CGFloat, bezel: CGFloat,
                                           originX: CGFloat, originY: CGFloat) -> CGRect {
        switch model.splitMode {
        case .spanned:
            let canvas = model.layout.effectiveCanvas(bezelPoints: bezel)
            return CGRect(x: originX, y: originY,
                          width: canvas.width * scale, height: canvas.height * scale)
        case .perMonitor:
            guard let id = model.selectedDisplayID,
                  let m = model.layout.monitors.first(where: { $0.displayID == id }) else {
                return .zero
            }
            let local = model.layout.canvasLocalImageRect(for: m, bezelPoints: 0)
            return CGRect(
                x: originX + local.minX * scale,
                y: originY + local.minY * scale,
                width: local.width * scale,
                height: local.height * scale
            )
        }
    }

    /// Spanned-mode projection across the bezel-expanded canvas.
    @ViewBuilder
    private func spannedProjectedImage(img: NSImage, scale: CGFloat) -> some View {
        let canvas = model.layout.effectiveCanvas(bezelPoints: model.bezelPoints)
        let canvasW = canvas.width * scale
        let canvasH = canvas.height * scale
        let imgSize = img.size
        let rect = imageRect(
            mode: model.spanned.mode,
            transform: model.spanned.manualTransform,
            canvasW: canvasW, canvasH: canvasH,
            imgSize: imgSize, scale: scale
        )
        canvasView(img: img, canvasW: canvasW, canvasH: canvasH, rect: rect)
    }

    /// Per-monitor projection — canvas IS the monitor's frame.
    @ViewBuilder
    private func perMonitorProjectedImage(
        img: NSImage, monitor: MonitorInfo, assignment: MonitorAssignment, scale: CGFloat
    ) -> some View {
        let canvasW = monitor.frame.width * scale
        let canvasH = monitor.frame.height * scale
        let imgSize = img.size
        let rect = imageRect(
            mode: assignment.mode,
            transform: assignment.manualTransform,
            canvasW: canvasW, canvasH: canvasH,
            imgSize: imgSize, scale: scale
        )
        canvasView(img: img, canvasW: canvasW, canvasH: canvasH, rect: rect)
    }

    private func imageRect(
        mode: FitMode, transform: ManualTransform?,
        canvasW: CGFloat, canvasH: CGFloat,
        imgSize: CGSize, scale: CGFloat
    ) -> CGRect {
        switch mode {
        case .stretch:
            return CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        case .fit:
            let s = min(canvasW / imgSize.width, canvasH / imgSize.height)
            let w = imgSize.width * s, h = imgSize.height * s
            return CGRect(x: (canvasW - w) / 2, y: (canvasH - h) / 2, width: w, height: h)
        case .fill:
            let s = max(canvasW / imgSize.width, canvasH / imgSize.height)
            let w = imgSize.width * s, h = imgSize.height * s
            return CGRect(x: (canvasW - w) / 2, y: (canvasH - h) / 2, width: w, height: h)
        case .center:
            let w = imgSize.width * scale, h = imgSize.height * scale
            return CGRect(x: (canvasW - w) / 2, y: (canvasH - h) / 2, width: w, height: h)
        case .manual:
            if let t = transform {
                return CGRect(
                    x: t.imageOrigin.x * scale,
                    y: t.imageOrigin.y * scale,
                    width: t.imageSize.width * scale,
                    height: t.imageSize.height * scale
                )
            }
            return CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        }
    }

    @ViewBuilder
    private func canvasView(img: NSImage, canvasW: CGFloat, canvasH: CGFloat, rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.frame(width: canvasW, height: canvasH)
            Image(nsImage: img)
                .resizable()
                .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: canvasW, height: canvasH, alignment: .topLeading)
        .compositingGroup()
        .clipped()
    }

    private func monitorsMask(scale: CGFloat, bezel: CGFloat) -> some View {
        let layout = model.layout
        let canvas = layout.effectiveCanvas(bezelPoints: bezel)
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: canvas.width * scale, height: canvas.height * scale)
            ForEach(layout.monitors) { monitor in
                let local = layout.canvasLocalImageRect(for: monitor, bezelPoints: bezel)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: local.width * scale, height: local.height * scale)
                    .offset(x: local.minX * scale, y: local.minY * scale)
            }
        }
        .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
    }

    private func monitorTile(
        monitor: MonitorInfo, rect: CGRect,
        isSelected: Bool, showHint: Bool
    ) -> some View {
        let strokeColor: Color = {
            if isSelected { return .accentColor }
            if monitor.isPrimary { return .accentColor.opacity(0.6) }
            return .white.opacity(0.7)
        }()
        let lineW: CGFloat = isSelected ? 3 : 2
        return Rectangle()
            .stroke(strokeColor, lineWidth: lineW)
            .background(Color.clear.contentShape(Rectangle()))
            .overlay(alignment: .center) {
                if showHint {
                    Text("Bild hierher ziehen")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text("\(monitor.name)\n\(Int(monitor.frame.width))×\(Int(monitor.frame.height))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.55))
                    .cornerRadius(4)
                    .padding(4)
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    // MARK: - Input handling

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.loadSource(url)
        }
    }

    private func handleDrop(providers: [NSItemProvider], atDisplayID displayID: CGDirectDisplayID?) -> Bool {
        guard let provider = providers.first else { return false }
        let target: (URL) -> Void = { url in
            DispatchQueue.main.async {
                if let id = displayID {
                    model.loadSource(url, intoDisplayID: id)
                } else {
                    model.loadSource(url)
                }
            }
        }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                target(url)
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    target(url)
                }
            }
            return true
        }
        return false
    }
}

// MARK: - Recents popover

private struct RecentsView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Letzte Bilder")
                    .font(.headline)
                Spacer()
                if !model.recents.isEmpty {
                    Button("Liste leeren") { model.clearRecents() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red.opacity(0.85))
                }
            }
            if model.recents.isEmpty {
                Text("Noch keine Bilder geladen.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(model.recents, id: \.self) { url in
                            RecentTile(url: url) {
                                model.loadSource(url)
                                dismiss()
                            } remove: {
                                model.removeRecent(url)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding(14)
        .frame(width: 520, height: 360)
    }
}

private struct RecentTile: View {
    let url: URL
    let action: () -> Void
    let remove: () -> Void

    @State private var thumbnail: NSImage?
    @State private var hovered: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.secondary.opacity(0.18)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(height: 88)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(hovered ? Color.accentColor : Color.secondary.opacity(0.3),
                                lineWidth: hovered ? 2 : 1)
                )

                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Aus Liste entfernen.")
                .opacity(hovered ? 1 : 0)
            }
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .onHover { hovered = $0 }
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        let url = self.url
        Task.detached(priority: .userInitiated) {
            let img = makeThumbnail(url: url, maxPixelSize: 320)
            await MainActor.run { self.thumbnail = img }
        }
    }
}

private func makeThumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: .zero)
}

// MARK: - Slideshow popover

private struct SlideshowView: View {
    @ObservedObject var slideshow: Slideshow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Slideshow")
                .font(.headline)

            // Folder picker row
            HStack(alignment: .firstTextBaseline) {
                Text("Ordner:")
                    .frame(width: 70, alignment: .leading)
                if let folder = slideshow.folderURL {
                    Text(folder.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                } else {
                    Text("Kein Ordner gewählt")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Wählen …") { pickFolder() }
            }

            HStack {
                Text("\(slideshow.imageCount) Bild\(slideshow.imageCount == 1 ? "" : "er")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if slideshow.folderURL != nil && slideshow.imageCount == 0 {
                    Text("· keine unterstützten Formate gefunden")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if slideshow.folderURL != nil {
                    Button("Neu einlesen") { slideshow.reloadImageList() }
                        .buttonStyle(.borderless)
                }
            }

            Divider()

            // Interval
            HStack(alignment: .firstTextBaseline) {
                Text("Intervall:")
                    .frame(width: 70, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { slideshow.intervalMinutes },
                        set: { slideshow.intervalMinutes = $0 }
                    ),
                    in: 1...60, step: 1
                )
                Text(intervalLabel)
                    .font(.callout.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }

            // Random toggle
            Toggle("Zufällige Reihenfolge", isOn: Binding(
                get: { slideshow.randomOrder },
                set: { slideshow.randomOrder = $0 }
            ))
            .toggleStyle(.checkbox)

            Divider()

            // Status + controls
            statusRow

            HStack {
                if slideshow.isRunning {
                    Button {
                        slideshow.stop()
                    } label: {
                        Label("Stoppen", systemImage: "stop.circle.fill")
                    }
                    Button {
                        slideshow.skipForward()
                    } label: {
                        Label("Nächstes", systemImage: "forward.fill")
                    }
                } else {
                    Button {
                        slideshow.start()
                    } label: {
                        Label("Starten", systemImage: "play.fill")
                    }
                    .disabled(slideshow.imageCount == 0)
                    .keyboardShortcut(.return)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private var intervalLabel: String {
        let min = Int(slideshow.intervalMinutes)
        return "\(min) min"
    }

    @ViewBuilder
    private var statusRow: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            VStack(alignment: .leading, spacing: 4) {
                if let url = slideshow.currentImageURL {
                    Text("Aktuell: \(url.lastPathComponent)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if slideshow.isRunning, let next = slideshow.nextChangeAt {
                    let remaining = max(0, next.timeIntervalSince(context.date))
                    Text("Nächster Wechsel in \(formatRemaining(remaining))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !slideshow.isRunning && slideshow.imageCount > 0 {
                    Text("Bereit zum Starten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        if panel.runModal() == .OK, let url = panel.url {
            slideshow.setFolder(url)
        }
    }
}

// MARK: - Interactive overlay (pan + scroll wheel)

private struct InteractiveOverlay: NSViewRepresentable {
    let previewScale: CGFloat
    let onPan: (CGSize) -> Void
    let onZoom: (CGPoint, CGFloat) -> Void

    func makeNSView(context: Context) -> InteractiveCanvasNSView {
        let v = InteractiveCanvasNSView()
        v.onPan = onPan
        v.onZoom = onZoom
        return v
    }

    func updateNSView(_ nsView: InteractiveCanvasNSView, context: Context) {
        nsView.onPan = onPan
        nsView.onZoom = onZoom
    }
}

final class InteractiveCanvasNSView: NSView {
    var onPan: ((CGSize) -> Void)?
    var onZoom: ((CGPoint, CGFloat) -> Void)?
    private var lastDragPoint: NSPoint?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        return (onPan != nil || onZoom != nil) ? self : nil
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func scrollWheel(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.deltaY * 10
        guard delta != 0 else { return }
        onZoom?(CGPoint(x: loc.x, y: loc.y), delta)
    }

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        let delta = CGSize(width: p.x - last.x, height: p.y - last.y)
        lastDragPoint = p
        onPan?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        if lastDragPoint != nil { NSCursor.pop() }
        lastDragPoint = nil
    }
}
