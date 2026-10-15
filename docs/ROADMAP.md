# Roadmap

Aufwand: S = Tage, M = 1 bis 2 Wochen, L = Wochen bis Monate, XL = Forschungsprojekt.

Ausführlicher Plan für Platte, Netzwerk, 3D und eigenen Hypervisor-Kern: [PLAN-LEISTUNG.md](PLAN-LEISTUNG.md).

Leitlinie: **Isolation.** Pluralism baut keine Kanäle zwischen Mac und Gast (keine Zwischenablage, keine
geteilten Ordner, keine Gastagenten, kein Coherence). Weiterentwickelt werden Netzwerk, Peripherie,
Leistung und Verwaltung.

## Stand 0.1 (erledigt)

- [x] VM-Bibliothek, Assistent, Einstellungen, Klonen, Papierkorb
- [x] Linux über Virtualization.framework: UEFI, virtio, NAT, automatische Auflösung, Ton, Mikrofon,
      verschachtelte Virtualisierung, Zustand sichern, ISO im Betrieb
- [x] Windows 11 ARM über QEMU + HVF: vollautomatische Installation mit Treibern, NVMe, TPM optional,
      Secure Boot optional, Bild im eigenen Fenster, Mac-Tastenkürzel, Strg+Alt+Entf
- [x] Isolation: keine Zwischenablage, keine Freigaben, keine Gastagenten, RDP nur ohne Umleitungen
- [x] Snapshots per APFS-Klon, Logs, Ressourcenempfehlung für den M4 Pro
- [x] Tests für den Kern, CI für Linux und macOS

## Stand 0.2 (erledigt)

- [x] QEMU 11.1.2 und swtpm in der App (aus dem Quellcode gebaut, Bibliotheken gebündelt, ohne Homebrew)
- [x] Zielsystem macOS 27, Build auf Xcode 27
- [x] Windows-Systemplatte als virtio-blk mit eigenem I/O-Thread, Rohformat, Treiber schon im Setup
- [x] Umstellung älterer Windows-VMs von NVMe auf virtio mit Hilfsplatte und automatischem Snapshot
- [x] Eigenes vmnet-Netz pro VM mit fester Adresse, Modi „Internet und Mac“, „Nur Mac“, „Kein Netzwerk“
- [x] Windows-Netz über Paketbrücke QEMU ↔ vmnet, Linux über `VZVmnetNetworkDeviceAttachment`
- [x] Netzwerk-Prüfprogramm in der CI (vmnet ohne Root, fester Bereich, DHCP-Reservierung, Neustarts, Ausweichbereich)
- [x] Adresse des Gasts wird an seinen Rahmen erkannt und angezeigt (ohne Gastagent)
- [x] Sprachmodus Swift 6 (Swift 6.4, Xcode 27) mit vollständiger Prüfung auf Datenrennen
- [x] 0.2.1: Windows-Netz wie UTM (QEMU mit vmnet-shared/-host), Paketbrücke als Ausweg über Stream-Socket,
      vmnet-Objekte werden freigegeben, Netzwerkkarte ohne PXE-ROM, Ende-zu-Ende-Netzprüfung in der CI
- [x] Linux-Platten standardmäßig ASIF

## 0.3: Netzwerk, Rest

| Aufgabe | Aufwand | Weg |
|---|---|---|
| Netz zwischen VMs | M | gemeinsames vmnet-Netz für ausgewählte VMs, auf Wunsch ohne Internet |
| Portweiterleitung auf dem Mac | S | vmnet-Portregeln (über Loopback ab macOS 27), nur falls direkter Zugriff auf die Adresse nicht reicht |
| Bridged-Netz | – | braucht `com.apple.vm.networking` von Apple; nur mit Freigabe möglich |

## 0.4: Peripherie

| Aufgabe | Aufwand | Weg |
|---|---|---|
| USB-Geräte für Linux | M | macOS 27: `VZUSBPassthroughDeviceConfiguration` + AccessoryAccess (Entitlement-Frage klären) |
| USB-Geräte für Windows | M | QEMU `usb-host` braucht Root oder `com.apple.vm.device-access`; Alternative prüfen |
| Mauszeiger als Mac-Cursor (Windows) | S | VNC-Kodierung „Cursor“ (-239), NSCursor aus Bild und Maske |
| Dynamische Auflösung (Windows) | M | virtio-gpu + viogpudo, Fenstergröße per VNC `SetDesktopSize` weitergeben |
| Mehrere Bildschirme | M | mehrere Scanouts (Apple) bzw. mehrere virtio-gpu-Ausgänge (QEMU) |
| Mikrofon für Windows | M | QEMUs CoreAudio kann keine Aufnahme; eigener Audio-Backend-Weg nötig |

## 0.5: Verwaltung und Sicherheit

| Aufgabe | Aufwand | Weg |
|---|---|---|
| Echtes TPM 2.0 | M | Eigener QEMU-Build mit CRB-TPM-Patch (`tpm-crb-device`) und Secure-Boot-Firmware |
| Secure Boot für Linux | S | macOS 27 `VZEFIVariableStore.enrollDefaultSecureBootSignatures()` |
| Snapshots im laufenden Betrieb (Windows) | M | QMP `snapshot-save` / `snapshot-load` (braucht qcow2 oder Zustand separat) |
| Geschichtete Platten | M | macOS 27 DiskImageKit: Basis plus Overlays, schnelle Klone und Rollback |
| Verschlüsselte VMs | M | VM-Ordner in verschlüsseltem APFS-Image |
| Linux unbeaufsichtigt installieren | M | cloud-init (NoCloud, Laufwerk `CIDATA`) mit Cloud-Images, Ubuntu-Autoinstall |
| Kommandozeile `pluralismctl` | S | list, start, stop, status |

## 0.6: Grafik

| Aufgabe | Aufwand | Weg |
|---|---|---|
| 3D für Linux (Apple-Engine) | L | macOS 27 `VZCustomVirtioDevice`: eigenes virtio-gpu mit virglrenderer + ANGLE auf Metal |
| 3D für Linux (QEMU-Engine) | M | QEMU mit virglrenderer/Venus und MoltenVK oder KosmicKrisp |
| DirectX für Windows | XL | experimentelle virtio-gpu-3D-Treiber für Windows ARM beobachten |

## Langfristig: eigener Hypervisor-Kern

Der Weg von Parallels: statt QEMU ein eigener VMM direkt auf Hypervisor.framework.

- vCPU-Threads, Speicher (`hv_vm_map`), GICv3 über `hv_gic_*` (macOS 15), Timer
- Geräte: virtio-blk/-net/-gpu über PCIe, PL011, PL031, TPM-CRB, ramfb
- Firmware: edk2 ArmVirtQemu
- SME/SME2-Zustand des M4 sichern und an Gäste geben (macOS 15.2 APIs)
- Ergebnis: keine QEMU-Abhängigkeit, volle Kontrolle über Leistung und darüber, welche Geräte ein Gast sieht

## Bewusst nicht geplant

- Gemeinsame Zwischenablage, geteilte Ordner, Drag-and-drop
- Gastagenten und Gast-Werkzeuge
- Coherence (Gast-Fenster als Mac-Fenster)
- x86-Gäste

## Bekannte Grenzen

- **Windows-Lizenz:** Microsoft autorisiert Windows 11 auf Apple Silicon offiziell nur in Parallels Desktop.
  Für den privaten Einsatz braucht jede VM eine Windows-11-Pro-Lizenz.
