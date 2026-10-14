# Pluralism

Eigene Virtualisierungs-App für Macs mit Apple Silicon, gebaut als Alternative zu Parallels Desktop.
Zielrechner: MacBook Pro 14" mit M4 Pro (8 Performance- und 4 Effizienz-Kerne, 48 GB).

**Gäste:** Linux ARM64 und Windows 11 ARM64. x86 wird bewusst nicht unterstützt.

**Grundprinzip Isolation:** Die VMs laufen abgeschottet vom Mac. Es gibt keine gemeinsame Zwischenablage,
keine geteilten Ordner, keine Gast-Werkzeuge und keinen Kanal zwischen Mac und Gast. Nach außen gehen nur
**Netzwerk** und **Peripherie** (Bildschirm, Tastatur, Maus, Ton).

## Aufbau

| Gast | Engine | Warum |
|---|---|---|
| Linux ARM64 | Apples **Virtualization.framework** | Offiziell und sehr schnell, mit automatischer Auflösung, Ton und verschachtelter Virtualisierung |
| Windows 11 ARM64 | **QEMU** als eigener Prozess, beschleunigt über Apples **Hypervisor.framework** (`-accel hvf`) | Apples Framework startet Windows nur mit privaten APIs und ohne TPM. QEMU mit Hypervisor.framework ist dafür der bewährte Weg |

Die App ist in zwei Teile getrennt:

- `Sources/PluralismCore`: Logik ohne UI-Frameworks (Konfiguration, QEMU-Kommandozeile, Windows-Antwortdatei,
  VNC/RFB-Protokoll, Tastatur-Tabellen, Ressourcenempfehlungen). Läuft auch unter Linux und ist vollständig getestet.
- `Sources/Pluralism`: die macOS-App mit SwiftUI und AppKit.

Anleitung: [docs/ERSTE-SCHRITTE.md](docs/ERSTE-SCHRITTE.md). Aufbau: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Plan: [docs/ROADMAP.md](docs/ROADMAP.md). Recherche: [docs/research/](docs/research/).

## Was Version 0.1 kann

- VM-Bibliothek mit Assistent für neue VMs, Einstellungen, Klonen (APFS-Klon) und Papierkorb
- Ressourcenempfehlung passend zum Mac (M4 Pro: Linux 4 Kerne/8 GB, Windows 6 Kerne/12 GB)
- **Linux:** UEFI-Start vom ISO, virtio-Platte (RAW, auf macOS 26 auch ASIF), NAT-Netz, virtio-gpu mit
  automatischer Auflösung, Ton und Mikrofon (optional), verschachtelte Virtualisierung, Zustand sichern und
  fortsetzen, ISO im laufenden Betrieb einlegen (macOS 15)
- **Windows 11 ARM:** vollautomatische Installation (Antwortdatei mit Netzwerk-, Speicher- und Anzeigetreibern
  aus virtio-win, lokales Konto, Umgehung der Hardwareprüfung), NVMe-Systemplatte, emuliertes TPM 2.0 (optional),
  Secure Boot (mit passender Firmware), Bild im eigenen Fenster über VNC mit Mac-Tastenkürzeln
  (Cmd+C wird Strg+C im Gast), Strg+Alt+Entf, optionale Remote-Desktop-Weiterleitung ohne Geräte-Umleitung
- Portweiterleitungen für QEMU-VMs (nur 127.0.0.1)
- Snapshots per APFS-Klon für beide Engines
- Pause, Herunterfahren, Ausschalten, Logs

## Voraussetzungen

- Mac mit Apple Silicon, macOS 14 oder neuer (empfohlen macOS 15 oder neuer)
- Xcode 16 oder neuer bzw. Command Line Tools mit Swift 6 (für den Build)
- Für Windows-VMs: `brew install qemu swtpm`

## Bauen

```sh
./scripts/build-app.sh
open build/Pluralism.app
```

Das Skript baut mit SwiftPM, stellt das App-Bundle zusammen und signiert es ad hoc mit dem Entitlement
`com.apple.security.virtualization`. Ein bezahltes Apple-Entwicklerkonto ist dafür nicht nötig.

Jeder Push baut die App außerdem per GitHub Actions auf einem Apple-Silicon-Runner. Das fertige Bundle liegt
dort als Artefakt `Pluralism-app`. Eine aus dem Netz geladene, ad hoc signierte App blockiert macOS zunächst;
nach dem Entpacken einmal ausführen:

```sh
xattr -dr com.apple.quarantine Pluralism.app
```

## Tests

```sh
swift test
```

## Grenzen (Stand 0.1)

- Keine Brücke ins Netzwerk des Macs (bridged): braucht ein Entitlement, das Apple nur auf Anfrage vergibt.
- USB-Geräte lassen sich noch nicht durchreichen (geplant, siehe Roadmap).
- Keine 3D-Beschleunigung.
