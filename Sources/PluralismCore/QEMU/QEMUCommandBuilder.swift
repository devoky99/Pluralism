import Foundation

/// Ein zu startender Prozess.
public struct ProcessPlan: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Lesbare Kommandozeile für Logs und Fehlersuche.
    public var commandLine: String {
        ([executable] + arguments).map { arg in
            arg.contains(" ") ? "'\(arg)'" : arg
        }.joined(separator: " ")
    }
}

/// Zusätzliche Medien, die beim Start angehängt werden.
public struct QEMUMedia: Equatable, Sendable {
    public var installerISO: String?
    public var driverISO: String?
    public var unattendISO: String?
    public var toolsISO: String?

    public init(installerISO: String? = nil, driverISO: String? = nil, unattendISO: String? = nil, toolsISO: String? = nil) {
        self.installerISO = installerISO
        self.driverISO = driverISO
        self.unattendISO = unattendISO
        self.toolsISO = toolsISO
    }
}

public struct QEMULaunchPlan: Equatable, Sendable {
    public var qemu: ProcessPlan
    /// swtpm muss vor QEMU laufen, wenn ein TPM gewünscht ist.
    public var swtpm: ProcessPlan?
    public var usesIntegratedDisplay: Bool
    public var tpmDevice: String?
}

/// Baut die QEMU-Kommandozeile für eine VM.
///
/// Grundlage sind bewährte Konfigurationen für Windows 11 ARM64 unter QEMU, angepasst an
/// das normale QEMU aus Homebrew (siehe docs/research/windows-arm-guests.md, Abschnitt 6):
/// - `virt`-Maschine mit GICv3, Beschleunigung über Hypervisor.framework (`-accel hvf`)
/// - UEFI (edk2) mit eigener Variablen-Datei pro VM
/// - Systemplatte als NVMe (Windows hat dafür einen eingebauten Treiber)
/// - ISOs als USB-Massenspeicher (funktioniert im Windows-Setup ohne Treiber)
/// - USB-Tastatur und USB-Tablet (absolute Mauskoordinaten)
/// - virtio-net (Treiber NetKVM kommt per Antwortdatei aus dem virtio-win-ISO)
/// - QMP-Socket zur Steuerung, VNC-Socket für die Anzeige im Pluralism-Fenster
public enum QEMUCommandBuilder {
    public static func makePlan(config: VMConfiguration,
                                bundle: VMBundle,
                                toolchain: QEMUToolchain,
                                runtime: RuntimePaths,
                                media: QEMUMedia) throws -> QEMULaunchPlan {
        guard runtime.allSocketPathsFit else {
            throw QEMUPlanError.socketPathTooLong(runtime.directory.path)
        }
        guard config.disk.format != .asif else {
            throw QEMUPlanError.unsupportedDiskFormat(config.disk.format.displayName)
        }

        let isWindows = config.guestOS == .windows
        var args: [String] = []

        // Identität
        args += ["-name", escape(config.name)]
        args += ["-uuid", config.id.uuidString]
        args += ["-nodefaults"]

        // Maschine, CPU, Speicher
        var machine = "virt,gic-version=3"
        if config.advanced.nestedVirtualization {
            machine += ",virtualization=on"
        }
        args += ["-machine", machine]
        // Eigene -accel-Angabe in den Zusatzargumenten (z. B. hvf,kernel-irqchip=off) hat Vorrang.
        if !config.advanced.extraQEMUArguments.contains("-accel") {
            args += ["-accel", "hvf"]
        }
        var cpu = "host"
        if config.advanced.hideSME {
            cpu += ",sme=off"
        }
        args += ["-cpu", cpu]
        let cores = max(1, config.cpuCount)
        args += ["-smp", "cpus=\(cores),sockets=1,cores=\(cores),threads=1"]
        args += ["-m", "\(config.memoryMiB)M"]

        // Firmware
        let firmware = try toolchain.firmware(secureBoot: isWindows && config.windows.secureBoot)
        args += ["-drive", "if=pflash,format=raw,unit=0,file=\(escape(firmware.code)),readonly=on"]
        args += ["-drive", "if=pflash,format=raw,unit=1,file=\(escape(bundle.qemuEFIVariablesURL.path))"]

        // Grafik
        switch config.display.qemuDevice {
        case .ramfb:
            args += ["-device", "ramfb"]
        case .virtioGPU:
            args += ["-device", "virtio-gpu-pci"]
        }

        // USB-Controller, Tastatur, Zeigegerät
        args += ["-device", "qemu-xhci,id=xhci"]
        args += ["-device", "usb-kbd,bus=xhci.0"]
        args += ["-device", "usb-tablet,bus=xhci.0"]

        // Systemplatte
        let diskFormat = config.disk.format == .qcow2 ? "qcow2" : "raw"
        var drive = "if=none,id=system,format=\(diskFormat),file=\(escape(bundle.diskURL(for: config).path)),discard=unmap,detect-zeroes=unmap"
        if config.disk.syncMode == .none {
            drive += ",cache=unsafe"
        }
        args += ["-drive", drive]
        if isWindows {
            args += ["-device", "nvme,drive=system,serial=pluralism0,bootindex=1"]
        } else {
            args += ["-device", "virtio-blk-pci,drive=system,bootindex=1"]
        }

        // Wechselmedien als USB-Massenspeicher
        func addCD(id: String, path: String, bootIndex: Int?) {
            args += ["-drive", "if=none,id=\(id),media=cdrom,readonly=on,format=raw,file=\(escape(path))"]
            var device = "usb-storage,drive=\(id),removable=on,bus=xhci.0"
            if let bootIndex {
                device += ",bootindex=\(bootIndex)"
            }
            args += ["-device", device]
        }
        if let installer = media.installerISO {
            addCD(id: "installer", path: installer, bootIndex: 0)
        }
        if let driver = media.driverISO {
            addCD(id: "drivers", path: driver, bootIndex: nil)
        }
        if let unattend = media.unattendISO {
            addCD(id: "unattend", path: unattend, bootIndex: nil)
        }
        if let tools = media.toolsISO {
            addCD(id: "tools", path: tools, bootIndex: nil)
        }

        // Netzwerk (QEMU-Usermode-Netz: kein Root, keine Sonderrechte)
        if config.network.mode == .nat {
            var netdev = "user,id=net0"
            for forward in allPortForwards(config) {
                netdev += ",hostfwd=\(forward.proto.rawValue):127.0.0.1:\(forward.hostPort)-:\(forward.guestPort)"
            }
            args += ["-netdev", netdev]
            args += ["-device", "virtio-net-pci,netdev=net0,mac=\(config.network.macAddress)"]
        }

        // Zwischenablage über den SPICE-Agent-Kanal (im Gast: spice-vdagent)
        if config.integration.clipboard {
            args += ["-device", "virtio-serial-pci,id=vserial"]
            args += ["-chardev", "qemu-vdagent,id=vdagent,name=vdagent,clipboard=on"]
            args += ["-device", "virtserialport,bus=vserial.0,chardev=vdagent,name=com.redhat.spice.0"]
        }

        // Ton (QEMUs CoreAudio-Ausgabe; ein Mikrofon unterstützt sie nicht)
        if config.integration.audioOutput && !config.advanced.suspendable {
            args += ["-audiodev", "coreaudio,id=audio0"]
            args += ["-device", "intel-hda"]
            args += ["-device", "hda-output,audiodev=audio0"]
        }

        if config.advanced.entropyDevice {
            args += ["-device", "virtio-rng-pci"]
        }
        if config.advanced.memoryBalloon {
            args += ["-device", "virtio-balloon-pci"]
        }

        args += ["-rtc", isWindows ? "base=localtime" : "base=utc"]

        // Geteilte Ordner für Linux über virtio-9p (virtiofs gibt es mit QEMU auf macOS nicht)
        if !isWindows {
            for (index, folder) in config.sharedFolders.enumerated() {
                var fsdev = "local,id=fs\(index),path=\(escape(folder.hostPath)),security_model=mapped-xattr"
                if folder.readOnly {
                    fsdev += ",readonly=on"
                }
                args += ["-fsdev", fsdev]
                args += ["-device", "virtio-9p-pci,fsdev=fs\(index),mount_tag=\(folder.name)"]
            }
        }

        // TPM
        var swtpmPlan: ProcessPlan?
        var tpmDevice: String?
        if isWindows && config.windows.tpm == .emulated {
            guard let swtpm = toolchain.swtpmPath else {
                throw QEMUPlanError.missingSWTPM
            }
            if toolchain.supportsTPMCRB {
                tpmDevice = "tpm-crb-device"
            } else if toolchain.supportsTPMTIS || toolchain.devices.isEmpty {
                tpmDevice = "tpm-tis-device"
            } else {
                throw QEMUPlanError.noTPMDevice
            }
            args += ["-chardev", "socket,id=chrtpm,path=\(escape(runtime.tpmSocket.path))"]
            args += ["-tpmdev", "emulator,id=tpm0,chardev=chrtpm"]
            args += ["-device", "\(tpmDevice!),tpmdev=tpm0"]
            swtpmPlan = ProcessPlan(executable: swtpm, arguments: [
                "socket", "--tpm2",
                "--tpmstate", "dir=\(bundle.tpmStateDirectory.path)",
                "--ctrl", "type=unixio,path=\(runtime.tpmSocket.path),terminate",
                "--log", "file=\(bundle.tpmLogURL.path),level=5"
            ])
        }

        // Steuerung
        args += ["-qmp", "unix:\(escape(runtime.qmpSocket.path)),server=on,wait=off"]

        // Anzeige
        let integrated = config.display.qemuFrontend == .integrated
        if integrated {
            args += ["-display", "none"]
            args += ["-vnc", "unix:\(escape(runtime.vncSocket.path))"]
        } else {
            args += ["-display", "cocoa,zoom-to-fit=on,show-cursor=on"]
        }

        if config.advanced.serialLog {
            args += ["-serial", "file:\(escape(bundle.serialLogURL.path))"]
        }

        args += config.advanced.extraQEMUArguments

        return QEMULaunchPlan(
            qemu: ProcessPlan(executable: toolchain.qemuSystemPath, arguments: args),
            swtpm: swtpmPlan,
            usesIntegratedDisplay: integrated,
            tpmDevice: tpmDevice
        )
    }

    /// Alle Portweiterleitungen inklusive Remote Desktop.
    public static func allPortForwards(_ config: VMConfiguration) -> [PortForward] {
        var forwards = config.network.portForwards
        if config.guestOS == .windows, let rdp = config.windows.rdpHostPort {
            forwards.append(PortForward(proto: .tcp, hostPort: rdp, guestPort: 3389, label: "Remote Desktop"))
        }
        return forwards
    }

    /// QEMU trennt Optionen mit Kommas. Ein Komma im Wert wird durch Verdopplung geschützt.
    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: ",,")
    }

    /// Argumente für `qemu-img create`.
    public static func diskCreateArguments(path: String, sizeGiB: Int, format: DiskFormat) -> [String] {
        let fmt = format == .qcow2 ? "qcow2" : "raw"
        var args = ["create", "-f", fmt]
        if format == .qcow2 {
            args += ["-o", "lazy_refcounts=on,preallocation=off"]
        }
        args += [path, "\(sizeGiB)G"]
        return args
    }
}
