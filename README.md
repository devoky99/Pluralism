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
| Windows 11 ARM64 | **QEMU** (in der App enthalten) als eigener Prozess, beschleunigt über Apples **Hypervisor.framework** (`-accel hvf`) | Apples Framework startet Windows nur mit privaten APIs und ohne TPM. QEMU mit Hypervisor.framework ist dafür der bewährte Weg |

Die App ist in zwei Teile getrennt:

- `Sources/PluralismCore`: Logik ohne UI-Frameworks (Konfiguration, QEMU-Kommandozeile, Windows-Antwortdatei,
  VNC/RFB-Protokoll, Tastatur-Tabellen, Ressourcenempfehlungen). Läuft auch unter Linux und ist vollständig getestet.
- `Sources/PluralismNet`: Netzwerk über Apples vmnet (eigenes Netz pro VM, Paketbrücke für QEMU).
- `Sources/Pluralism`: die macOS-App mit SwiftUI und AppKit.
- `Sources/PluralismNetCheck`: Prüfprogramm, das ein vmnet-Netz aufbaut und per DHCP eine Adresse holt.

Anleitung: [docs/ERSTE-SCHRITTE.md](docs/ERSTE-SCHRITTE.md). Aufbau: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Plan: [docs/ROADMAP.md](docs/ROADMAP.md). Recherche: [docs/research/](docs/research/).

## Was Version 0.2 kann

- VM-Bibliothek mit Assistent für neue VMs, Einstellungen, Klonen (APFS-Klon) und Papierkorb
- Ressourcenempfehlung passend zum Mac (M4 Pro: Linux 4 Kerne/8 GB, Windows 6 Kerne/12 GB)
- **QEMU ist in der App enthalten** (Version 11.1.2, nur ARM64, mit swtpm). Homebrew ist nicht nötig.
- **Netzwerk über Apples vmnet:** jede VM hat ihr eigenes Netz mit fester Adresse (z. B. 192.168.160.2),
  wählbar „Internet und Mac“, „Nur Mac“ oder „Kein Netzwerk“. Kein Root, keine Sonderrechte.
  Windows: QEMU legt das Netz selbst an (`vmnet-shared`/`vmnet-host`), Ausweg ist die Paketbrücke von Pluralism.
  Die CI prüft bei jedem Push DHCP, DNS, Internet und die Verbindung zwischen Mac und VM.
- **Linux:** UEFI-Start vom ISO, virtio-Platte im ASIF-Format, virtio-gpu mit automatischer Auflösung,
  Ton und Mikrofon (optional), verschachtelte Virtualisierung, Zustand sichern und fortsetzen,
  ISO im laufenden Betrieb einlegen
- **Windows 11 ARM:** vollautomatische Installation (Antwortdatei mit Netzwerk-, Speicher- und Anzeigetreibern
  aus virtio-win, lokales Konto, Umgehung der Hardwareprüfung), schnelle virtio-Systemplatte mit eigenem
  I/O-Thread im Rohformat (Umstellung älterer NVMe-VMs per Knopf), emuliertes TPM 2.0 (optional),
  Secure Boot (mit passender Firmware), Bild im eigenen Fenster über VNC mit Mac-Tastenkürzeln
  (Cmd+C wird Strg+C im Gast), Strg+Alt+Entf, optionale Remote-Desktop-Weiterleitung ohne Geräte-Umleitung
- Snapshots per APFS-Klon für beide Engines
- Pause, Herunterfahren, Ausschalten, Logs

## Voraussetzungen

- Mac mit Apple Silicon und **macOS 27**
- Zum Selbstbauen: Xcode 27 und Homebrew (nur für den QEMU-Bau, siehe unten)

## Bauen

```sh
./scripts/runtime/build-runtime.sh   # QEMU und swtpm bauen (einmalig, ca. 10 Minuten)
./scripts/build-app.sh               # App bauen, Laufzeit einpacken, signieren
open build/Pluralism.app
```

`build-runtime.sh` lädt QEMU als Quellcode (Prüfsumme fest im Repo), baut nur, was Pluralism braucht, und
bündelt alle Bibliotheken mit relativen Pfaden. `build-app.sh` packt das nach
`Pluralism.app/Contents/Resources/Runtime` und signiert ad hoc: die App mit `com.apple.security.virtualization`,
QEMU mit `com.apple.security.hypervisor`. Ein bezahltes Apple-Entwicklerkonto ist nicht nötig.

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

## Lizenzen

Pluralism liefert QEMU (GPL-2.0) und swtpm/libtpms (BSD-3-Clause) mit. Lizenztexte liegen in der App unter
`Contents/Resources/Runtime/share/licenses`, die Bauanleitung mit Quellen und Prüfsummen unter
[scripts/runtime/](scripts/runtime/).

## Grenzen (Stand 0.2)

- Keine Brücke ins Netzwerk des Macs (bridged): braucht ein Entitlement, das Apple nur auf Anfrage vergibt.
- USB-Geräte lassen sich noch nicht durchreichen (geplant, siehe Roadmap).
- Keine 3D-Beschleunigung.
