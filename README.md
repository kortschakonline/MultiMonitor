# MultiMonitor

Eine kleine macOS-App, die ein einzelnes Bild als zusammenhängendes Wallpaper über mehrere Monitore spannt — als Ersatz für das eingestellte **Fresco**.

## Features

- Bild über alle angeschlossenen Monitore hinweg spannen
- Vier Modi: **Strecken**, **Einpassen** (Aspect Fit), **Füllen** (Aspect Fill), **Zentrieren**
- Live-Vorschau der Monitor-Anordnung mit projiziertem Bild
- Drag & Drop direkt ins Fenster
- Pixel-genau für Retina-Displays
- Reagiert auf An-/Abstecken externer Monitore

## Bauen

Voraussetzungen: macOS 13+ und CommandLineTools (kein volles Xcode nötig). Prüfen mit `swift --version`.

```bash
chmod +x build.sh
./build.sh
```

Das Script erzeugt `MultiMonitor.app` im Projektordner. Doppelklick zum Starten oder nach `/Applications` ziehen.

## Benutzung

1. App starten — die Vorschau zeigt deine aktuelle Monitor-Anordnung.
2. Ein Bild ins Fenster ziehen oder über *Bild auswählen* öffnen.
3. Modus wählen (Strecken / Einpassen / Füllen / Zentrieren).
4. *Anwenden* klicken — die Wallpaper werden generiert und gesetzt.

## Wo werden die Wallpaper gespeichert?

```
~/Library/Application Support/MultiMonitor/wallpapers/
```

Das System speichert pro Monitor ein PNG in nativer Auflösung. Ältere Generationen werden automatisch aufgeräumt (die letzten sechs bleiben).

## Architektur

| Datei | Zweck |
| --- | --- |
| `MonitorLayout.swift` | Erfasst alle Bildschirme via `NSScreen`, berechnet die Canvas-Bounding-Box |
| `WallpaperRenderer.swift` | Rendert die Canvas, croppt pro Monitor, schreibt PNG |
| `WallpaperApplier.swift` | Setzt die Wallpaper via `NSWorkspace.setDesktopImageURL` |
| `ContentView.swift` | SwiftUI-UI mit Drag-Drop und Vorschau |
| `MultiMonitorApp.swift` | App-Einstieg |

## Bekannte Einschränkungen

- Aktuell ein Bild für alle Monitore. Pro-Monitor-Bilder, Slideshow und Bibliothek sind als spätere Erweiterung gedacht.
- Single-Architektur (arm64 oder x86_64, je nach Build-Host). Für ein Universal-Binary müsste `build.sh` zwei Archs bauen und mit `lipo` kombinieren.
- Nicht codesigniert (Ad-hoc, kein Developer-ID-Zertifikat). Der erste Start funktioniert lokal ohne weiteres; beim Verteilen nach woanders ggf. `xattr -d com.apple.quarantine MultiMonitor.app`.
