import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var layout: MonitorLayout = .current()
    @Published var sourceURL: URL?
    @Published var sourcePreview: NSImage?
    @Published var sourcePixelSize: CGSize = .zero  // CGImage pixel dims (aspect source)
    @Published var mode: FitMode = .stretch {
        didSet { if mode == .manual { ensureManualTransform() } }
    }
    @Published var manualTransform: ManualTransform?
    @Published var status: String = "Bereit. Ziehe ein Bild hierher."
    @Published var isWorking: Bool = false

    func refreshLayout() {
        layout = .current()
    }

    func loadSource(_ url: URL) {
        sourceURL = url
        sourcePreview = NSImage(contentsOf: url)
        if let cg = try? WallpaperRenderer.loadCGImage(from: url) {
            sourcePixelSize = CGSize(width: cg.width, height: cg.height)
        } else {
            sourcePixelSize = .zero
        }
        if sourcePreview == nil {
            status = "Bild konnte nicht gelesen werden."
        } else {
            status = "Bild geladen: \(url.lastPathComponent)"
        }
        // Re-init manual transform for the new image.
        manualTransform = nil
        if mode == .manual { ensureManualTransform() }
    }

    // MARK: - Manual transform

    func ensureManualTransform() {
        if manualTransform == nil { resetManualTransform() }
    }

    func resetManualTransform() {
        let canvas = layout.canvas
        let imgSize = sourcePixelSize == .zero ? (sourcePreview?.size ?? .zero) : sourcePixelSize
        guard canvas.width > 0, canvas.height > 0,
              imgSize.width > 0, imgSize.height > 0 else {
            manualTransform = nil
            return
        }
        // Default to "fill": image covers the canvas, aspect preserved.
        let scale = max(canvas.width / imgSize.width, canvas.height / imgSize.height)
        let w = imgSize.width * scale
        let h = imgSize.height * scale
        let origin = CGPoint(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2)
        manualTransform = ManualTransform(
            imageOrigin: origin,
            imageSize: CGSize(width: w, height: h)
        )
    }

    func panBy(canvasDelta: CGSize) {
        guard var t = manualTransform else { return }
        t.imageOrigin.x += canvasDelta.width
        t.imageOrigin.y += canvasDelta.height
        manualTransform = t
    }

    /// Zoom around a point in canvas-point coordinates.
    func zoom(at canvasPoint: CGPoint, deltaPixels: CGFloat) {
        guard var t = manualTransform else { return }
        // Smooth exponential factor; positive scrollingDeltaY = scroll up = zoom in
        let factor = pow(1.0015, deltaPixels)
        let clampedFactor = max(0.92, min(1.08, factor))

        let canvas = layout.canvas
        let minDim = min(canvas.width, canvas.height) * 0.1   // don't shrink below 10% of canvas
        let maxDim = max(canvas.width, canvas.height) * 50    // sane upper bound

        let candidateW = t.imageSize.width * clampedFactor
        let candidateH = t.imageSize.height * clampedFactor
        if candidateW < minDim || candidateH < minDim { return }
        if candidateW > maxDim || candidateH > maxDim { return }

        // Keep the canvas point under the cursor pinned to the same image point.
        let newOriginX = canvasPoint.x - (canvasPoint.x - t.imageOrigin.x) * clampedFactor
        let newOriginY = canvasPoint.y - (canvasPoint.y - t.imageOrigin.y) * clampedFactor

        t.imageOrigin = CGPoint(x: newOriginX, y: newOriginY)
        t.imageSize = CGSize(width: candidateW, height: candidateH)
        manualTransform = t
    }

    func apply() {
        guard let url = sourceURL else {
            status = "Erst ein Bild auswählen."
            return
        }
        isWorking = true
        status = "Rendere und setze Wallpaper …"
        let mode = self.mode
        let layout = self.layout
        let transform = self.manualTransform

        Task.detached {
            do {
                let cg = try WallpaperRenderer.loadCGImage(from: url)
                let outDir = WallpaperApplier.outputDirectory
                let ts = Date().timeIntervalSince1970
                let images = try WallpaperRenderer.renderPerScreen(
                    sourceImage: cg,
                    layout: layout,
                    mode: mode,
                    manualTransform: transform,
                    outputDir: outDir,
                    timestamp: ts
                )
                try await MainActor.run {
                    try WallpaperApplier.apply(images)
                }
                WallpaperApplier.pruneOldOutputs()
                await MainActor.run {
                    self.status = "Wallpaper auf \(images.count) Monitor(en) gesetzt."
                    self.isWorking = false
                }
            } catch {
                await MainActor.run {
                    self.status = "Fehler: \(error.localizedDescription)"
                    self.isWorking = false
                }
            }
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var model = AppModel()

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

            HStack {
                Button {
                    pickFile()
                } label: {
                    Label("Bild auswählen …", systemImage: "photo")
                }
                if let url = model.sourceURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if model.mode == .manual && model.sourcePreview != nil {
                    Button("Zurücksetzen") { model.resetManualTransform() }
                        .help("Bild wieder auf Canvas einpassen (Füllen).")
                }
            }

            Picker("Modus", selection: $model.mode) {
                ForEach(FitMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text(displayedStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: { model.apply() }) {
                    Label("Anwenden", systemImage: "checkmark.circle.fill")
                }
                .keyboardShortcut(.return)
                .disabled(model.sourceURL == nil || model.isWorking)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            model.refreshLayout()
            if model.mode == .manual { model.ensureManualTransform() }
        }
    }

    private var displayedStatus: String {
        if model.mode == .manual && model.sourcePreview != nil {
            return model.status + "  ·  Ziehen = verschieben, Scrollen = zoomen"
        }
        return model.status
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        GeometryReader { geo in
            let layout = model.layout
            let canvas = layout.canvas
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
                // Image projected onto the canvas using the current mode.
                if let img = model.sourcePreview {
                    projectedImage(img: img, scale: scale)
                        .offset(x: originX, y: originY)
                }

                // Monitor outlines on top.
                ForEach(layout.monitors) { monitor in
                    let local = layout.canvasLocalImageRect(for: monitor)
                    let r = CGRect(
                        x: originX + local.minX * scale,
                        y: originY + local.minY * scale,
                        width: local.width * scale,
                        height: local.height * scale
                    )
                    monitorTile(monitor: monitor, rect: r)
                }

                // Interactive overlay for manual mode (pan + zoom).
                if model.mode == .manual && model.sourcePreview != nil {
                    InteractiveOverlay(
                        previewScale: scale,
                        onPan: { delta in
                            // Drag delta is in preview pixels, top-left origin.
                            model.panBy(canvasDelta: CGSize(
                                width: delta.width / scale,
                                height: delta.height / scale
                            ))
                        },
                        onZoom: { localPoint, deltaY in
                            // localPoint is in preview pixels, top-left origin.
                            let canvasPoint = CGPoint(
                                x: localPoint.x / scale,
                                y: localPoint.y / scale
                            )
                            model.zoom(at: canvasPoint, deltaPixels: deltaY)
                        }
                    )
                    .frame(width: displayW, height: displayH)
                    .offset(x: originX, y: originY)
                }
            }
        }
    }

    @ViewBuilder
    private func projectedImage(img: NSImage, scale: CGFloat) -> some View {
        let canvas = model.layout.canvas
        let canvasW = canvas.width * scale
        let canvasH = canvas.height * scale
        let imgSize = img.size

        // Compute the image's destination rect in canvas-preview coords
        // (top-left origin, in preview pixels). May extend beyond the canvas
        // — gets clipped by the outer .clipped() below.
        let rect: CGRect = {
            switch model.mode {
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
                if let t = model.manualTransform {
                    return CGRect(
                        x: t.imageOrigin.x * scale,
                        y: t.imageOrigin.y * scale,
                        width: t.imageSize.width * scale,
                        height: t.imageSize.height * scale
                    )
                }
                return CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
            }
        }()

        ZStack(alignment: .topLeading) {
            Color.black
                .frame(width: canvasW, height: canvasH)
            Image(nsImage: img)
                .resizable()
                .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: canvasW, height: canvasH, alignment: .topLeading)
        .compositingGroup()
        .clipped()
    }

    private func monitorTile(monitor: MonitorInfo, rect: CGRect) -> some View {
        Rectangle()
            .stroke(monitor.isPrimary ? Color.accentColor : Color.white.opacity(0.7), lineWidth: 2)
            .background(Color.clear)
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
            .allowsHitTesting(false)
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

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.loadSource(url) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async { model.loadSource(url) }
                }
            }
            return true
        }
        return false
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

    override var isFlipped: Bool { true }   // top-left origin to match SwiftUI
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only swallow events when we have callbacks attached.
        return (onPan != nil || onZoom != nil) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

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
