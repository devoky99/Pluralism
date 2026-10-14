# Plan: Pluralism auf Parallels-Niveau bringen

Stand: 14. Oktober 2026. Ziel: Rückstand bei **Platte**, **Netzwerk** und **Hypervisor-Kern** aufholen und
**3D-Beschleunigung** einbauen. Das Isolationsprinzip bleibt: keine Kanäle zwischen Mac und Gast. 3D läuft über
die virtuelle Grafikkarte (Peripherie), Netzwerk über virtuelle Netzwerkkarten.

## Ausgangslage

| Bereich | Pluralism heute | Parallels | Lücke |
|---|---|---|---|
| CPU | Linux und Windows ca. 90 % nativ | ca. 85 bis 90 % nativ | keine |
| Platte Linux | 3,4 bis 5,5 GB/s (Apple-Framework) | keine unabhängigen Zahlen | vermutlich gering |
| Platte Windows | 1,8 bis 2,2 GB/s (QEMU, NVMe-Emulation, qcow2) | keine unabhängigen Zahlen | groß, Mac schafft 5,5 bis 6 GB/s |
| Netzwerk Windows | QEMU-Usermode-Netz (slirp), langsam bei großen Datenmengen | eigener Netzstack | groß |
| 3D Linux | keine (virtio-gpu 2D) | OpenGL über VirGL | groß |
| 3D Windows | keine (Windows rendert per Software) | DirectX 11.1, OpenGL 4.3 über Metal | sehr groß |

Die Zahlen stammen aus Berichten mit denselben Bausteinen, nicht aus eigenen Messungen. Deshalb beginnt der Plan
mit einer Messbasis.

## Reihenfolge auf einen Blick

| Phase | Inhalt | Aufwand | Ergebnis |
|---|---|---|---|
| A | Messbasis auf deinem M4 Pro | 1 Woche | Zahlen statt Schätzungen, Vergleich mit Parallels |
| B | Schnellere Platte für Windows | 1 bis 2 Wochen | Ziel: mindestens 70 % des Mac-Durchsatzes |
| C | Schnelles Netzwerk über vmnet | 2 bis 3 Wochen | Ziel: Faktor 5 bis 10 gegenüber heute |
| D | 3D-Beschleunigung | Linux 4 bis 8 Wochen, Windows offen | Linux mit OpenGL über Metal |
| E | Eigener Hypervisor-Kern | mehrere Monate | QEMU wird ersetzbar |

Nach Phase A und nach Phase D gibt es je einen **Entscheidungspunkt**: Lohnt sich der nächste Schritt laut
Messung wirklich?

---

## Phase A: Messbasis (1 Woche)

**Ziel:** Belastbarer Vergleich Pluralism gegen Parallels auf derselben Hardware.

1. Messskript im Repo (`scripts/benchmark/`), das in allen Gästen gleich läuft:
   - CPU: Geekbench 6 (Single- und Multi-Core)
   - Platte: `fio` unter Linux, DiskSpd unter Windows (sequenziell 1 MB, zufällig 4 KB, mit und ohne Cache)
   - Netzwerk: `iperf3` zwischen Mac und Gast in beide Richtungen
   - Grafik: `glmark2` unter Linux, ein DirectX-Test unter Windows
   - Leerlauf: CPU-Last und Stromaufnahme des Macs mit `powermetrics`, VM 10 Minuten ohne Aktivität
2. Testpaare mit gleichen Ressourcen (z. B. 6 Kerne, 12 GB):
   - Ubuntu 26.04 ARM in Parallels gegen Ubuntu 26.04 ARM in Pluralism
   - Windows 11 ARM in Parallels gegen Windows 11 ARM in Pluralism
3. Ergebnisse als Tabelle in `docs/BENCHMARKS.md`, nach jeder Phase neu gemessen.

**Voraussetzung:** Der Mac ist mit der Claude-Desktop-App verbunden, damit ich die Tests ausführen kann.

---

## Phase B: Schnellere Platte für Windows (1 bis 2 Wochen)

**Ursache heute:** Windows sieht eine emulierte NVMe-Platte im Format qcow2. Beides kostet Leistung.

| Schritt | Umsetzung |
|---|---|
| B1 Paravirtuelle Platte | Systemplatte als `virtio-blk-pci` mit eigenem I/O-Thread (`-object iothread`) statt NVMe. Der Treiber `viostor` ist schon im Setup-Medium. |
| B2 Sicherer Wechsel | Während der Installation hängt eine kleine Hilfsplatte als virtio-blk an. So installiert Windows `viostor` als Starttreiber, bevor die Systemplatte umgestellt wird. Beim nächsten Start schaltet Pluralism die Systemplatte automatisch auf virtio-blk. Für bestehende VMs gibt es denselben Weg als Knopf. |
| B3 Rohformat | Neue Windows-VMs als RAW-Datei (APFS, dünn belegt) statt qcow2. Snapshots laufen weiter über APFS-Klone. qcow2 bleibt als Option. |
| B4 Feinabstimmung | Mehrere Warteschlangen (`num-queues` = Kernzahl), Cache-Modus und `discard` per Messung wählen. |
| B5 Linux prüfen | Apple-Framework: virtio-blk gegen NVMe, RAW gegen ASIF, Cache-Modi messen und den Standard anpassen. |

**Risiko:** Der Wechsel des Startlaufwerks kann bei Fehlern zu einem Windows-Bluescreen führen. Absicherung:
automatischer Snapshot vor dem Wechsel, Rückfall auf NVMe per Knopf.

---

## Phase C: Schnelles Netzwerk über vmnet (2 bis 3 Wochen)

**Ursache heute:** QEMUs Usermode-Netz baut jede Verbindung in Software nach. Apples schneller Netzstack
`vmnet` verlangt bei QEMU bisher Root-Rechte oder eine Apple-Freigabe.

**Lösung ab macOS 26:** Apple hat eine neue vmnet-Schnittstelle eingeführt (`vmnet_network_create`,
`vmnet_interface_start_with_network`). Laut Berichten funktioniert sie in nicht abgeschotteten Apps ohne Root.

| Schritt | Umsetzung |
|---|---|
| C1 Netzbrücke in Pluralism | Pluralism erzeugt das vmnet-Netz und eine Schnittstelle pro Windows-VM. QEMU schickt Ethernet-Pakete über einen lokalen Socket (`-netdev stream`) an Pluralism, Pluralism reicht sie gebündelt an vmnet weiter. Prüfsummen- und TSO-Entlastung einschalten. |
| C2 Linux auf dasselbe Netz | Apple-Engine von `VZNATNetworkDeviceAttachment` auf `VZVmnetNetworkDeviceAttachment` umstellen. Alle VMs liegen dann in einem gemeinsamen, von Pluralism verwalteten Netz. |
| C3 Netzwerkmodi | Pro VM wählbar: „Internet“, „nur Mac“, „nur VMs untereinander“, „kein Netz“. Passt zum Isolationsprinzip. |
| C4 Portweiterleitung und feste IPs | über vmnet-Regeln und DHCP-Reservierungen |
| C5 Rückfall | Auf macOS 14 und 15 bleibt das heutige Usermode-Netz. |

**Risiko:** Ob die neue vmnet-Schnittstelle ohne Root auch außerhalb von Apples Virtualization-Framework läuft,
ist nicht dokumentiert. Das klärt ein kleiner Test als erster Schritt. Fällt er negativ aus, bleibt C2 bis C4
für Linux und für Windows eine Weiterleitung über die Apple-Engine-Seite.

---

## Phase D: 3D-Beschleunigung

### D1 Linux mit QEMU-Engine (4 bis 6 Wochen)

Der erprobte Weg 2026: QEMU 11.1 mit **virglrenderer** und Googles **ANGLE**, das OpenGL in Apples **Metal**
übersetzt. Im Gast liefert Mesa den passenden Treiber, das ist in Fedora und Ubuntu schon enthalten.

| Schritt | Umsetzung |
|---|---|
| D1a Eigenes QEMU-Paket | GitHub Actions baut QEMU mit virglrenderer und ANGLE für Apple Silicon und veröffentlicht es als „Pluralism Runtime“. Die App lädt es bei Bedarf. Quellcode und Patches liegen offen im Repo (GPL). |
| D1b 3D im QEMU-Fenster | Gerät `virtio-gpu-gl-pci`, Anzeige zunächst im eigenen QEMU-Fenster mit OpenGL |
| D1c 3D im Pluralism-Fenster | Bildübergabe als Metal-Textur bzw. IOSurface an eine eigene Metal-Ansicht |
| D1d Vulkan | Sobald die Venus-Unterstützung für macOS in QEMU und virglrenderer stabil ist: Vulkan im Gast über MoltenVK oder KosmicKrisp |

### D2 Linux mit Apple-Engine (6 bis 8 Wochen, nur macOS 27)

macOS 27 erlaubt eigene virtio-Geräte (`VZCustomVirtioDevice`). Pluralism baut damit eine eigene
virtio-gpu mit virglrenderer und ANGLE direkt in der App und zeigt das Bild in einer Metal-Ansicht.
Vorteil: Linux bleibt auf Apples schnellem Framework und bekommt trotzdem 3D. Ein Projekt hat das 2026 bereits
gezeigt (glmark2 mit 2,6- bis 45-fachem Gewinn gegenüber Software-Rendering).

**Empfehlung:** D1 zuerst (schneller lauffähig), D2 danach, falls dein Mac macOS 27 hat.

### D3 Windows (Forschung, ohne Zusage)

Für Windows ARM gibt es 2026 keinen stabilen freien 3D-Treiber für virtio-gpu.

| Option | Bewertung |
|---|---|
| Software-Rendering (WARP) | Windows bringt DirectX 11/12 auf der CPU mit. Läuft heute schon, für Office und leichte 3D-Last brauchbar. Mit Messung in Phase A dokumentieren. |
| Experimenteller freier DirectX-11-Treiber (Projekte Neptune/Triton) | 2026 laut Entwicklern noch instabil. In einer Test-VM prüfen, nicht als Standard. |
| Eigener Windows-Grafiktreiber | Mehrjähriges Vorhaben (so hat es Parallels gemacht). Vorerst nicht geplant. |

**Ehrliche Einschätzung:** Bei 3D unter Windows wird Pluralism Parallels auf absehbare Zeit nicht einholen.

---

## Phase E: Eigener Hypervisor-Kern (mehrere Monate)

Der Weg von Parallels: ein eigener virtueller Rechner direkt auf Apples Hypervisor.framework statt QEMU.
**Die CPU-Leistung ändert sich dadurch nicht**, sie ist schon nahezu nativ. Gewinne entstehen bei Geräten,
Startzeit, Leerlauf und weil Netz und Platte ohne Umwege angebunden werden.

| Schritt | Inhalt | Aufwand |
|---|---|---|
| E1 Prototyp | VM anlegen, Speicher, vCPU-Threads, Interrupt-Controller über `hv_gic` (macOS 15), Timer, serielle Konsole, Linux-Kernel direkt starten | 4 bis 6 Wochen |
| E2 Geräte | PCIe, virtio-blk, virtio-net direkt an vmnet, virtio-gpu, virtio-input, UEFI-Firmware starten | 6 bis 10 Wochen |
| E3 Windows | ACPI-Tabellen, TPM 2.0, ramfb für die Installation, SME-Zustand des M4 | 8 bis 12 Wochen |
| E4 Umstieg | Windows-VMs laufen standardmäßig auf dem eigenen Kern, QEMU bleibt als Rückfall | 2 bis 4 Wochen |

**Entscheidungspunkt:** Phase E startet nur, wenn nach B bis D messbar noch ein deutlicher Abstand zu Parallels
bleibt. Sonst liefert optimiertes QEMU den Großteil des Gewinns für einen Bruchteil des Aufwands.

---

## Was ich von dir brauche

1. **macOS-Version** auf dem MacBook (entscheidet über Phase C ab macOS 26 und D2 ab macOS 27)
2. **Mac verbinden** über die Claude-Desktop-App: Ohne echten Mac kann ich nur kompilieren, nicht messen und
   nicht mit VMs testen
3. **Freigabe der Reihenfolge** A, B, C, D1, D3-Prüfung, dann Entscheidung über D2 und E

## Erfolgskriterien

| Messgröße | Heute (Schätzung) | Ziel |
|---|---|---|
| Windows Platte sequenziell | ca. 35 % des Mac | mindestens 70 % |
| Windows Netzwerk Mac ↔ Gast | Usermode-Netz | mindestens 5-fach |
| Linux 3D (glmark2) | Software-Rendering | Hardware über Metal |
| Leerlauf-Last Windows-VM | unbekannt | auf Parallels-Niveau |
