# MultiMonitor

Eine kleine macOS-App, die ein einzelnes Bild als zusammenhängendes Wallpaper über mehrere Monitore spannt — als Ersatz für das eingestellte **Fresco**.

## Features

- **Spannen** eines Bildes über alle Monitore mit vier Skalierungsmodi: Strecken, Einpassen (Aspect Fit), Füllen (Aspect Fill), Zentrieren
- **Manuell** mit Maus verschieben + Mausrad-Zoom (Cursor-fix beim Zoom)
- **Bezel-Korrektur** (Slider) für eine virtuelle Lücke zwischen Monitoren, damit Linien physikalisch durchlaufen
- **Pro-Monitor-Modus**: jedes Display kann ein eigenes Bild und einen eigenen Modus bekommen — Drag-and-Drop direkt auf einen Monitor in der Vorschau
- **Bibliothek** der zuletzt verwendeten Bilder mit Thumbnail-Grid
- **Slideshow** rotiert Bilder aus einem Ordner (1–60 min, wahlweise zufällig)
- **Auto-Reapply** beim An- und Abstecken eines Monitors
- **Menüleisten-Modus**: App lebt in der Menüleiste, Hauptfenster optional, Slideshow läuft im Hintergrund weiter
- **Beim Login starten** über `SMAppService`
- **Persistenz**: Bild, Modus, manuelle Transformation, Bezel, Bibliothek und Slideshow-Settings überleben App-Neustart

## Installation

### Fertige App laden

Aktuelle Version aus den [Releases](https://github.com/kortschakonline/MultiMonitor/releases) ziehen, ZIP entpacken, `MultiMonitor.app` nach `/Applications`. Beim ersten Start meckert Gatekeeper (App ist nur ad-hoc-signiert). Lösung:

- **Rechtsklick → Öffnen** → „Trotzdem öffnen", oder
- Im Terminal: `xattr -d com.apple.quarantine /Applications/MultiMonitor.app`

### Aus dem Source bauen

Voraussetzungen: macOS 13+ und CommandLineTools (kein volles Xcode nötig). Prüfen mit `swift --version`.

```bash
chmod +x build.sh
./build.sh
```

Das Script erzeugt `MultiMonitor.app` im Projektordner.

## Benutzung

1. App starten — die Vorschau zeigt deine aktuelle Monitor-Anordnung.
2. Ein Bild ins Fenster ziehen oder über *Bild auswählen* öffnen.
3. Modus wählen (Strecken / Einpassen / Füllen / Zentrieren / Manuell).
4. Optional: **Pro-Monitor**-Toggle für unterschiedliche Bilder pro Display.
5. *Anwenden* klicken.

Wenn du das Hauptfenster schließt, läuft die App in der Menüleiste weiter — Auto-Reapply und Slideshow ticken dort weiter. Über das Menü erreichst du Hauptfenster, letzte Bilder, Slideshow-Steuerung und das „Beim Login starten"-Toggle.

## Wo werden die Wallpaper gespeichert?

```
~/Library/Application Support/MultiMonitor/wallpapers/
```

Pro Monitor wird ein PNG in nativer Auflösung geschrieben. Ältere Generationen werden automatisch aufgeräumt (die letzten sechs bleiben).

## Architektur

| Datei | Zweck |
| --- | --- |
| `MultiMonitorApp.swift` | App-Einstieg, WindowGroup + MenuBarExtra |
| `MenuBarMenu.swift` | Menü in der Menüleiste |
| `ContentView.swift` | Hauptfenster: AppModel, Vorschau, Drag-Drop, Modi, Popovers |
| `MonitorLayout.swift` | NSScreen → Canvas-Geometrie inkl. Bezel-Korrektur |
| `WallpaperRenderer.swift` | Modi (stretch/fit/fill/center/manual), Crop pro Monitor, PNG-Output |
| `WallpaperApplier.swift` | `NSWorkspace.setDesktopImageURL` pro Screen |
| `Slideshow.swift` | Timer + Ordner-Scan + Rotation |
| `LoginItemManager.swift` | `SMAppService`-Wrapper für „Beim Login starten" |
| `Persistence.swift` | UserDefaults JSON-State (Codable) |

## Bekannte Einschränkungen

- arm64-only Binary (Apple Silicon). Universal Binary für Intel-Macs wäre eine `lipo`-Erweiterung in `build.sh`.
- Bezel-Korrektur nimmt eine waagerechte Monitor-Anordnung an.
- Nicht codesigniert (Ad-hoc, kein Developer-ID-Zertifikat). Verteilte Builds brauchen ggf. einen Quarantine-Reset.
