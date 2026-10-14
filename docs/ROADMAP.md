# Roadmap: von 0.1 zur Parallels-Parität

Aufwand: S = Tage, M = 1 bis 2 Wochen, L = Wochen bis Monate, XL = Forschungsprojekt.
Grundlage: [research/feature-parity.md](research/feature-parity.md).

## Stand 0.1 (erledigt)

- [x] VM-Bibliothek, Assistent, Einstellungen, Klonen, Papierkorb
- [x] Linux über Virtualization.framework: UEFI, virtio, NAT, automatische Auflösung, virtiofs,
      Zwischenablage, Ton, Mikrofon, verschachtelte Virtualisierung, Zustand sichern, ISO im Betrieb
- [x] Windows 11 ARM über QEMU + HVF: vollautomatische Installation mit Treibern, NVMe, TPM optional,
      Secure Boot optional, Bild im eigenen Fenster, Mac-Tastenkürzel, Strg+Alt+Entf, RDP-Weiterleitung
- [x] Snapshots per APFS-Klon, Logs, Ressourcenempfehlung für den M4 Pro
- [x] Tests für den Kern, CI für Linux und macOS

## 0.2: Windows fühlt sich an wie Parallels

| Aufgabe | Aufwand | Weg |
|---|---|---|
| Pluralism Tools für Windows | M | Eigener ARM64-Agent über virtio-serial (Treiber vioserial aus virtio-win): Zwischenablage in beide Richtungen, Auflösung, Zeit nach dem Fortsetzen |
| Zwischenablage im Pluralism-Fenster | M | VNC „Extended Clipboard“ (Pseudo-Kodierung 0xC0A1E5CE) im RFB-Client, zlib-Daten |
| Mauszeiger des Gasts als Mac-Cursor | S | RFB-Kodierung „Cursor“ (-239), NSCursor aus Bild und Maske |
| Dynamische Auflösung | M | virtio-gpu + viogpudo, Fenstergröße per VNC `SetDesktopSize` bzw. QEMU-UI-Info weitergeben |
| Geteilte Ordner für Windows | M | QEMU `-netdev user,smb=` mit Samba aus Homebrew, alternativ SPICE-WebDAV |
| Snapshots im laufenden Betrieb | M | QMP `snapshot-save` / `snapshot-load` für qcow2 |
| Echtes TPM 2.0 | M | Eigener QEMU-Build mit CRB-TPM-Patch (`tpm-crb-device`) und Secure-Boot-Firmware |
| Netzwerk mit Portweiterleitung für Linux | M | macOS 26: `VZVmnetNetworkDeviceAttachment` mit vmnet-Portregeln |
| Kommandozeile `pluralismctl` | S | list, start, stop, ssh, ip über eine kleine XPC- oder Socket-Schnittstelle |

## 0.3: Komfort für Linux

| Aufgabe | Aufwand | Weg |
|---|---|---|
| Linux unbeaufsichtigt installieren | M | cloud-init (NoCloud, Laufwerk `CIDATA`) mit Cloud-Images, Ubuntu-Autoinstall |
| Gastagent über vsock | M | Zeit nach dem Fortsetzen, IP-Adresse anzeigen, sauberes Herunterfahren, Muster: Apples `containerization` |
| Geschichtete Platten | M | macOS 27 DiskImageKit: Basis plus Overlays, schnelle Klone und Rollback |
| USB-Geräte durchreichen | M | macOS 27 `VZUSBPassthroughDeviceConfiguration` + AccessoryAccess (Entitlement-Frage klären) |
| Secure Boot für Linux | S | macOS 27 `VZEFIVariableStore.enrollDefaultSecureBootSignatures()` |
| ASIF als Standard | S | ab macOS 26 Plattenformat ASIF für neue Linux-VMs |

## 0.4: Coherence (Apps wie Mac-Fenster)

| Aufgabe | Aufwand | Weg |
|---|---|---|
| Windows-Apps als einzelne Mac-Fenster | L bis XL | RDP RemoteApp (RAIL): Cocoa-Client auf Basis von IronRDP (MIT/Apache) oder libfreerdp; Gast braucht Pro |
| Startmenü-Apps im Dock | M | Gastagent listet Apps, Pluralism erzeugt Stub-Apps mit Symbol |
| Linux-Fenster einzeln | L | waypipe über vsock, Achtung GPL-3.0 |

## 0.5: Grafik

| Aufgabe | Aufwand | Weg |
|---|---|---|
| 3D für Linux (Apple-Engine) | L | macOS 27 `VZCustomVirtioDevice`: eigenes virtio-gpu mit virglrenderer + ANGLE auf Metal |
| 3D für Linux (QEMU-Engine) | M | QEMU mit virglrenderer/Venus und MoltenVK oder KosmicKrisp |
| DirectX für Windows | XL | Experimentelle virtio-gpu-3D-Treiber für Windows ARM verfolgen (noch instabil), Host-Seite DXMT |

## Langfristig: eigener Hypervisor-Kern

Der Weg von Parallels: statt QEMU ein eigener VMM direkt auf Hypervisor.framework.

- vCPU-Threads, Speicher (`hv_vm_map`), GICv3 über `hv_gic_*` (macOS 15), Timer
- Geräte: virtio-blk/-net/-gpu/-console über PCIe, PL011, PL031, TPM-CRB, ramfb
- Firmware: edk2 ArmVirtQemu
- SME/SME2-Zustand des M4 sichern und an Gäste geben (macOS 15.2 APIs), wie Parallels 27
- Ergebnis: keine QEMU-Abhängigkeit, volle Kontrolle über Leistung und Integration

## Bekannte Grenzen, die bleiben

- **Bridged-Netz** braucht `com.apple.vm.networking`, das Apple nur auf Anfrage an Hersteller vergibt.
- **Windows-Lizenz:** Microsoft autorisiert Windows 11 auf Apple Silicon offiziell nur in Parallels Desktop.
  Für den privaten Einsatz braucht jede VM eine Windows-11-Pro-Lizenz.
- **x86** ist bewusst nicht vorgesehen.
