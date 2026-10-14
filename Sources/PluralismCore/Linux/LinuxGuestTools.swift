import Foundation

/// "Pluralism Tools" für Linux-Gäste: ein Skript, das im Gast die Integration einrichtet.
/// Es landet auf einem kleinen ISO (pluralism-tools.iso), das Pluralism an die VM anhängt.
///
/// Was es tut:
/// - spice-vdagent installieren (gemeinsame Zwischenablage über Apples SPICE-Agent-Port)
/// - die virtiofs-Freigabe "pluralism" unter /mnt/pluralism dauerhaft einbinden
/// - qemu-guest-agent installieren (für die QEMU-Engine)
/// - Pakete passend zur Distribution (Fedora, Ubuntu/Debian, Arch, openSUSE)
public enum LinuxGuestTools {
    public static let shareTag = "pluralism"
    public static let mountPoint = "/mnt/pluralism"
    public static let scriptName = "install.sh"

    public static var installScript: String {
        """
        #!/bin/sh
        # Pluralism Tools für Linux-Gäste (ARM64)
        # Aufruf im Gast:  sudo sh /pfad/zum/medium/install.sh
        set -eu

        if [ "$(id -u)" -ne 0 ]; then
          echo "Bitte mit sudo ausführen: sudo sh $0"
          exit 1
        fi

        echo "== Pluralism Tools =="

        PKGS_FEDORA="spice-vdagent qemu-guest-agent"
        PKGS_DEBIAN="spice-vdagent qemu-guest-agent"
        PKGS_ARCH="spice-vdagent qemu-guest-agent"
        PKGS_SUSE="spice-vdagent qemu-guest-agent"

        if command -v dnf >/dev/null 2>&1; then
          dnf install -y $PKGS_FEDORA || true
        elif command -v apt-get >/dev/null 2>&1; then
          apt-get update || true
          DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS_DEBIAN || true
        elif command -v pacman >/dev/null 2>&1; then
          pacman -Sy --noconfirm $PKGS_ARCH || true
        elif command -v zypper >/dev/null 2>&1; then
          zypper --non-interactive install $PKGS_SUSE || true
        else
          echo "Unbekannte Distribution. Bitte spice-vdagent selbst installieren."
        fi

        # Zwischenablage: spice-vdagentd starten (der Benutzer-Agent startet mit der Sitzung)
        if command -v systemctl >/dev/null 2>&1; then
          systemctl enable --now spice-vdagentd.service 2>/dev/null || systemctl enable --now spice-vdagentd.socket 2>/dev/null || true
          systemctl enable --now qemu-guest-agent.service 2>/dev/null || true
        fi

        # Geteilte Ordner (virtiofs, Apple-Engine). Bei der QEMU-Engine heißen die
        # Freigaben wie die Ordner und laufen über 9p, siehe README.
        mkdir -p \(mountPoint)
        if ! grep -q "^\(shareTag) " /etc/fstab; then
          echo "\(shareTag) \(mountPoint) virtiofs rw,nofail,x-systemd.automount 0 0" >> /etc/fstab
          echo "Freigabe in /etc/fstab eingetragen."
        fi
        if command -v systemctl >/dev/null 2>&1; then
          systemctl daemon-reload || true
        fi
        mount \(mountPoint) 2>/dev/null || mount -t virtiofs \(shareTag) \(mountPoint) 2>/dev/null || \\
          echo "Hinweis: keine virtiofs-Freigabe gefunden (in Pluralism unter Freigaben einen Ordner hinzufügen)."

        echo "Fertig. Nach einer Ab- und Anmeldung funktioniert die Zwischenablage."
        echo "Geteilte Ordner liegen unter \(mountPoint)."
        """
    }

    public static var readme: String {
        """
        Pluralism Tools für Linux
        =====================

        1. Terminal im Gast öffnen.
        2. Das Medium "PLURALISM_TOOLS" ist meist unter /run/media/$USER/PLURALISM_TOOLS
           oder /media/$USER/PLURALISM_TOOLS eingebunden.
        3. Ausführen:  sudo sh /run/media/$USER/PLURALISM_TOOLS/install.sh

        Danach:
        - Zwischenablage zwischen Mac und Linux funktioniert (spice-vdagent).
        - Freigegebene Mac-Ordner erscheinen unter /mnt/pluralism/<Name>.
        - Die Bildschirmauflösung folgt der Fenstergröße automatisch (virtio-gpu).
        """
    }
}
