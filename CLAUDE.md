# CLAUDE.md: Hinweise für die Entwicklung von Pluralism

Pluralism ist eine eigene Virtualisierungs-App für Apple-Silicon-Macs (Ziel: MacBook Pro M4 Pro) mit den
Fähigkeiten von Parallels Desktop. Aufbau und Hintergründe: `docs/ARCHITECTURE.md`, Plan: `docs/ROADMAP.md`
und `docs/PLAN-LEISTUNG.md`.

## Feste Vorgaben

- **Gäste:** nur Linux ARM64 und Windows 11 ARM64. Kein x86, auch keine Emulation.
- **Isolation:** keine gemeinsame Zwischenablage, keine geteilten Ordner, keine Gastagenten, kein Drag and
  Drop, keine Kanäle zwischen Mac und Gast. Genutzt werden nur Netzwerk und Peripherie (Tastatur, Maus,
  Ton, USB-Medien).
- **Zielsystem:** macOS 27 (`LSMinimumSystemVersion` 27.0), gebaut mit Xcode 27 und Swift 6.4.
- **Keine Fremd-Apps als Voraussetzung:** QEMU und swtpm sind in der App enthalten (`scripts/runtime/`).
  Andere Virtualisierungs-Apps nicht erwähnen und nicht als Abhängigkeit vorsehen.
- **Sprache:** Oberfläche, Doku und Commit-Nachrichten auf Deutsch, Fachbegriffe kurz erklärt.
  Keine Gedankenstriche als Satzzeichen (Bindestriche in Wörtern sind in Ordnung).

## Swift: Regeln nach „The Swift Programming Language“ 6.4

Nachschlagewerk: `docs/reference/swift-6.4-book.md` (Kapitelübersicht in `docs/reference/README.md`).

- **Sprachmodus Swift 6** für alle Targets. Nur damit prüft der Compiler vollständig auf Datenrennen
  (Kapitel „Version Compatibility“, Zeile 190).
- **Datenisolation** (Kapitel „Isolation“, Zeile 8007): Daten sind sicher, wenn sie unveränderlich sind, nur
  der aktuellen Task gehören oder von einem Actor geschützt werden. Jede veränderliche Klasse braucht genau
  eine dieser Antworten.
- **Main Actor für die Oberfläche** (Zeile 8015): `AppModel`, `VMSession`, die Engines und alle Views sind
  `@MainActor`. Lange Arbeit (Platten anlegen, Netz aufbauen, QEMU starten) läuft außerhalb und meldet das
  Ergebnis auf dem Main Actor zurück.
- **Sendable** (Zeile 8164): Werte, die zwischen Threads oder Queues wandern, sind `Sendable`.
  Konfigurationstypen in `PluralismCore` sind Wertetypen und damit `Sendable`.
  `@unchecked Sendable` nur für Klassen, die ihren Zustand selbst über genau eine Queue oder einen Lock
  schützen (z. B. `PacketRelay`, `VMNetworkRegistry`), und immer mit Kommentar, welche Queue oder welcher
  Lock das ist.
- **Locks und Semaphoren** nicht über `await` hinweg halten (Attribut `noasync`, Zeile 16210). Synchrones
  Warten auf asynchronen Code gibt es nicht („no safe way“, Zeile 7859). Bestehender Code mit
  `DispatchQueue` und Rückrufen bleibt, solange er klar isoliert ist.
- **Strukturierte Nebenläufigkeit** bevorzugen (`async let`, Task-Gruppen). `Task.detached` nur mit Grund.
- **Speichersicherheit** (Zeile 10935): Zeiger und `Unsafe…`-APIs nur in klar abgegrenzten Stellen
  (vmnet-Puffer, Bildpuffer, Sockets), Lebensdauer im Kommentar festhalten.

## Bauen und Prüfen

- Kern unter Linux: `swift build --target PluralismCore` und `swift test` (CI: Container `swift:6.4`).
- App: `swift build -c release --product Pluralism`, Bundle: `scripts/build-app.sh release`
  (braucht `build/runtime` aus `scripts/runtime/build-runtime.sh` oder `PLURALISM_RUNTIME`).
- Netzwerk ohne VM: `pluralism-netcheck` (mit `Resources/Pluralism.entitlements` signieren, sonst Code 1002).
- CI (`.github/workflows/build.yml`) schreibt Logs in die Branches `ci-logs-linux`, `ci-logs-runtime`,
  `ci-logs-macos`. Lesen: `git fetch origin +ci-logs-macos:refs/remotes/origin/ci-logs-macos` und
  `git show origin/ci-logs-macos:<datei>`.
- Release: Workflow mit `-f release=vX.Y.Z` starten, Notizen aus `docs/release-notes/vX.Y.Z.md`.

## Wichtige Erkenntnisse

- vmnet auf macOS 27: eigener Bereich nur mit der Adresse des Macs (.1), Bereich wird erst beim
  Prozessende frei, daher `VMNetworkRegistry`. Details in `docs/ARCHITECTURE.md`.
- Windows-Treiber kommen aus virtio-win, Speicher- und Netztreiber über `$WinPEDriver$` schon im Setup.
- Unix-Socket-Pfade sind auf 104 Bytes begrenzt, daher `/tmp/pluralism-<uid>/<kurz-ID>/`.
