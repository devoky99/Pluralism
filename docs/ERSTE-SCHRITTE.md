# Erste Schritte mit Pluralism

## 1. App bauen oder laden

**Selbst bauen** (empfohlen, keine Gatekeeper-Warnung):

```sh
git clone https://github.com/devoky99/Pluralism.git
cd Pluralism
./scripts/build-app.sh
open build/Pluralism.app
```

Dafür reichen Xcode 16 oder neuer bzw. die Command Line Tools mit Swift 6.

**Fertig laden:** Auf GitHub unter Actions den letzten grünen Lauf öffnen, Artefakt `Pluralism-app`
herunterladen, entpacken und einmal ausführen:

```sh
xattr -dr com.apple.quarantine Pluralism.app
```

Pluralism am besten nach `/Programme` verschieben.

## 2. Linux-VM (Fedora oder Ubuntu)

1. ARM64-ISO laden, z. B. Fedora Workstation **aarch64** oder Ubuntu Desktop **arm64**.
2. In Pluralism: **Neue VM** → Linux → ISO wählen → Ressourcen übernehmen → **VM anlegen**.
3. **Starten**. Das Fenster öffnet sich, die Installation läuft wie auf einem echten Rechner.
4. Nach der Installation VM herunterfahren, unter Medien **Auswerfen**.
5. **Pluralism Tools einlegen**, VM starten und im Gast im Terminal ausführen:
   ```sh
   sudo sh /run/media/$USER/PLURALISM_TOOLS/install.sh
   ```
   (Ubuntu: `/media/$USER/PLURALISM_TOOLS/install.sh`). Danach ab- und wieder anmelden.
6. Ordner freigeben: VM ausschalten, unter **Geteilte Ordner** einen Mac-Ordner hinzufügen.
   Im Gast erscheint er unter `/mnt/pluralism/<Name>`.

Die Auflösung folgt der Fenstergröße automatisch. Mit **Anhalten** (Mond-Symbol) wird der Zustand
gesichert, wenn in den VM-Einstellungen unter Erweitert „Anhalten ermöglichen“ eingeschaltet ist.

## 3. Windows-11-VM

1. Einmalig im Terminal: `brew install qemu swtpm`. In Pluralism unter Einstellungen → QEMU prüfen,
   dass QEMU, qemu-img und die UEFI-Firmware gefunden werden.
2. Windows 11 **ARM64**-ISO bei Microsoft laden (Knopf im Assistenten öffnet die Seite).
3. **Neue VM** → Windows 11 → ISO wählen.
4. Im selben Schritt **virtio-win herunterladen** (Treiber, ca. 700 MB) und optional die
   **SPICE-Gasttools** (für die Zwischenablage).
5. Benutzername und Passwort eintragen, Sprache wählen, weiter bis **VM anlegen**.
6. **Starten**. Windows installiert sich selbst und startet dabei mehrmals neu (15 bis 30 Minuten).
   Erscheint am Anfang „Press any key to boot from CD“, einfach warten.
7. Nach der ersten Anmeldung läuft automatisch die Pluralism-Einrichtung (Treiber, Remote Desktop).
8. VM herunterfahren und unter Medien **Auswerfen**, damit Windows nicht mehr vom ISO startet.

Tipps:

- **Strg+Alt+Entf** gibt es in der Werkzeugleiste des VM-Fensters.
- **Cmd+C / Cmd+V** werden in Windows zu Strg+C / Strg+V.
- **Bessere Integration sofort:** die „Windows App“ von Microsoft aus dem Mac App Store installieren und
  in Pluralism **RDP-Verbindung öffnen** wählen. Damit gibt es dynamische Auflösung, Ton, Zwischenablage
  in beide Richtungen und Laufwerke.
- **Andere Auflösungen ohne RDP:** in Windows den Treiber `viogpudo` installieren
  (liegt im Ordner `pluralism-drivers` auf dem Setup-Medium bzw. auf dem virtio-win-ISO), VM ausschalten,
  in den Einstellungen unter Anzeige **virtio-gpu** wählen. Bei schwarzem Bild zurück auf ramfb.
- Aktivierung: eigenen Windows-11-Pro-Schlüssel in Windows unter Einstellungen → Aktivierung eingeben.

## 4. Wenn etwas nicht klappt

- **Logs:** in der VM-Ansicht unter „Mehr“ → Engine-Log öffnen (QEMU) oder Serielles Log (Linux).
- **Windows startet nicht vom ISO:** unter „Mehr“ die UEFI-Variablen zurücksetzen.
- **QEMU startet nicht:** Fehlermeldung zeigt die letzten Zeilen von QEMU. Häufig fehlt ein Paket
  (`brew install qemu swtpm`) oder ein Gerät, z. B. bei sehr alten QEMU-Versionen.
- **Windows-Probleme mit dem Interrupt-Controller:** in den VM-Einstellungen unter Erweitert bei
  „Zusätzliche QEMU-Argumente“ testweise `-accel` und `hvf,kernel-irqchip=off` eintragen (zwei Zeilen).
