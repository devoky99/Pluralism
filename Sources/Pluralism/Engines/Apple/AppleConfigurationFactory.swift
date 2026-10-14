import Foundation
import PluralismCore
import Virtualization

/// Übersetzt eine Pluralism-Konfiguration in eine `VZVirtualMachineConfiguration`
/// für Linux-Gäste. Der Geräteaufbau folgt Apples Beispiel
/// "Running GUI Linux in a virtual machine on a Mac", ergänzt um Ton, USB-Controller und
/// verschachtelte Virtualisierung.
///
/// Isolation: Es gibt bewusst keine Zwischenablage (SPICE-Agent-Port), keine geteilten Ordner
/// (virtiofs) und keinen vsock-Kanal. Nach außen gehen nur Netzwerk und Peripherie.
enum AppleConfigurationFactory {
    static func make(config: VMConfiguration, bundle: VMBundle) throws -> VZVirtualMachineConfiguration {
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.logsDirectory, withIntermediateDirectories: true)

        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = clampCPU(config.cpuCount)
        vz.memorySize = clampMemory(UInt64(config.memoryMiB) * 1024 * 1024)
        vz.platform = try makePlatform(config: config, bundle: bundle)
        vz.bootLoader = try makeBootLoader(bundle: bundle)
        vz.storageDevices = try makeStorage(config: config, bundle: bundle)

        // Netzwerk: NAT über Apples eingebautes Netz (Gast bekommt eine Adresse per DHCP)
        if config.network.mode == .nat {
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            if let mac = VZMACAddress(string: config.network.macAddress) {
                network.macAddress = mac
            }
            vz.networkDevices = [network]
        }

        // Grafik: virtio-gpu (2D). Die Auflösung passt sich später dem Fenster an.
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: max(640, config.display.widthPixels),
                                                 heightInPixels: max(480, config.display.heightPixels))
        ]
        vz.graphicsDevices = [graphics]

        vz.keyboards = [VZUSBKeyboardConfiguration()]
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Ton. Ton-Geräte verhindern das Sichern des Zustands, daher im Modus "suspendable" aus.
        let peripherals = config.peripherals
        if !config.advanced.suspendable && (peripherals.audioOutput || peripherals.audioInput) {
            let sound = VZVirtioSoundDeviceConfiguration()
            var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
            if peripherals.audioOutput {
                let output = VZVirtioSoundDeviceOutputStreamConfiguration()
                output.sink = VZHostAudioOutputStreamSink()
                streams.append(output)
            }
            if peripherals.audioInput {
                let input = VZVirtioSoundDeviceInputStreamConfiguration()
                input.source = VZHostAudioInputStreamSource()
                streams.append(input)
            }
            sound.streams = streams
            vz.audioDevices = [sound]
        }

        if config.advanced.entropyDevice && !config.advanced.suspendable {
            vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        }
        if config.advanced.memoryBalloon {
            vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        }
        // Serielle Konsole in eine Logdatei (hilft bei Startproblemen)
        if config.advanced.serialLog && !config.advanced.suspendable {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = try VZFileSerialPortAttachment(url: bundle.serialLogURL, append: true)
            vz.serialPorts = [serial]
        }

        // USB-Controller für das Anhängen von Abbildern im laufenden Betrieb (macOS 15)
        if #available(macOS 15, *) {
            vz.usbControllers = [VZXHCIControllerConfiguration()]
        }

        try vz.validate()
        return vz
    }

    // MARK: - Teile

    private static func makePlatform(config: VMConfiguration, bundle: VMBundle) throws -> VZGenericPlatformConfiguration {
        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: bundle.machineIdentifierURL),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = identifier
        } else {
            let identifier = VZGenericMachineIdentifier()
            try identifier.dataRepresentation.write(to: bundle.machineIdentifierURL, options: .atomic)
            platform.machineIdentifier = identifier
        }
        if #available(macOS 15, *) {
            if config.advanced.nestedVirtualization && VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
                platform.isNestedVirtualizationEnabled = true
            }
        }
        return platform
    }

    private static func makeBootLoader(bundle: VMBundle) throws -> VZEFIBootLoader {
        let loader = VZEFIBootLoader()
        let url = bundle.appleEFIVariablesURL
        if FileManager.default.fileExists(atPath: url.path) {
            loader.variableStore = VZEFIVariableStore(url: url)
        } else {
            loader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: url)
        }
        return loader
    }

    private static func makeStorage(config: VMConfiguration, bundle: VMBundle) throws -> [VZStorageDeviceConfiguration] {
        let fm = FileManager.default
        let diskURL = bundle.diskURL(for: config)
        guard fm.fileExists(atPath: diskURL.path) else {
            throw PluralismError.message("Die Systemplatte fehlt: \(diskURL.path)")
        }
        let sync: VZDiskImageSynchronizationMode
        switch config.disk.syncMode {
        case .full: sync = .full
        case .fsync: sync = .fsync
        case .none: sync = .none
        }
        let systemAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false,
                                                                      cachingMode: .automatic,
                                                                      synchronizationMode: sync)
        var devices: [VZStorageDeviceConfiguration] = [VZVirtioBlockDeviceConfiguration(attachment: systemAttachment)]

        if config.media.attachInstaller, let path = config.media.installerISOPath, !path.isEmpty {
            guard fm.fileExists(atPath: path) else {
                throw PluralismError.message("Das Installationsmedium wurde nicht gefunden: \(path)")
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: path), readOnly: true)
            devices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }

        return devices
    }


    private static func clampCPU(_ value: Int) -> Int {
        min(max(value, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    }

    private static func clampMemory(_ value: UInt64) -> UInt64 {
        let clamped = min(max(value, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                          VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        // Vielfaches von 1 MiB
        return clamped - (clamped % (1024 * 1024))
    }
}
