import Foundation
@testable import PluralismCore
import XCTest

final class QEMUTests: XCTestCase {
    let host = HostProfile.macBookProM4Pro48GB
    let bundle = VMBundle(url: URL(fileURLWithPath: "/Users/musti/Library/Application Support/Pluralism/VMs/ABC.pluralismvm"))

    var toolchain: QEMUToolchain {
        QEMUToolchain(qemuSystemPath: "/opt/homebrew/bin/qemu-system-aarch64",
                      qemuImgPath: "/opt/homebrew/bin/qemu-img",
                      swtpmPath: "/opt/homebrew/bin/swtpm",
                      firmwareCodePath: "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
                      firmwareVarsTemplatePath: "/opt/homebrew/share/qemu/edk2-arm-vars.fd",
                      devices: ["tpm-tis-device", "nvme", "ramfb"],
                      version: "11.1.2")
    }

    func windowsConfig() -> VMConfiguration {
        var config = VMConfiguration.makeDefault(name: "Windows 11", guestOS: .windows, host: host)
        config.media.installerISOPath = "/Users/musti/Downloads/Win11_26H2_ARM64.iso"
        return config
    }

    func makePlan(_ config: VMConfiguration, media: QEMUMedia = QEMUMedia(), toolchain: QEMUToolchain? = nil) throws -> QEMULaunchPlan {
        try QEMUCommandBuilder.makePlan(config: config, bundle: bundle, toolchain: toolchain ?? self.toolchain,
                                        runtime: RuntimePaths(config: config, userID: 501), media: media)
    }

    /// Wert hinter einer Option, z. B. value(after: "-machine").
    func values(after option: String, in args: [String]) -> [String] {
        var result: [String] = []
        for (index, arg) in args.enumerated() where arg == option && index + 1 < args.count {
            result.append(args[index + 1])
        }
        return result
    }

    func testWindowsPlanCoreOptions() throws {
        let config = windowsConfig()
        let plan = try makePlan(config, media: QEMUMedia(installerISO: config.media.installerISOPath))
        let args = plan.qemu.arguments
        XCTAssertEqual(plan.qemu.executable, "/opt/homebrew/bin/qemu-system-aarch64")
        XCTAssertEqual(values(after: "-machine", in: args), ["virt,gic-version=3"])
        XCTAssertEqual(values(after: "-accel", in: args), ["hvf"])
        XCTAssertEqual(values(after: "-cpu", in: args), ["host"])
        XCTAssertEqual(values(after: "-smp", in: args), ["cpus=6,sockets=1,cores=6,threads=1"])
        XCTAssertEqual(values(after: "-m", in: args), ["12288M"])
        XCTAssertEqual(values(after: "-rtc", in: args), ["base=localtime"])
        XCTAssertTrue(args.contains("-nodefaults"))

        let devices = values(after: "-device", in: args)
        XCTAssertTrue(devices.contains("ramfb"))
        XCTAssertTrue(devices.contains("virtio-blk-pci,drive=system,iothread=iothread0,num-queues=6,bootindex=1"))
        XCTAssertEqual(values(after: "-object", in: args), ["iothread,id=iothread0"])
        XCTAssertFalse(devices.contains { $0.hasPrefix("nvme") })
        XCTAssertTrue(devices.contains("usb-storage,drive=installer,removable=on,bus=xhci.0,bootindex=0"))
        XCTAssertTrue(devices.contains("usb-kbd,bus=xhci.0"))
        XCTAssertTrue(devices.contains("usb-tablet,bus=xhci.0"))
        XCTAssertTrue(devices.contains { $0.hasPrefix("virtio-net-pci,netdev=net0,mac=52:54:00:") })
        // Isolation: kein Agentenkanal, keine Ordnerfreigabe
        XCTAssertFalse(devices.contains { $0.hasPrefix("virtio-serial") || $0.hasPrefix("virtserialport") || $0.hasPrefix("virtio-9p") })
        XCTAssertFalse(args.contains("-fsdev"))
        XCTAssertFalse(values(after: "-chardev", in: args).contains { $0.contains("vdagent") })

        let drives = values(after: "-drive", in: args)
        XCTAssertTrue(drives.contains("if=pflash,format=raw,unit=0,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd,readonly=on"))
        XCTAssertTrue(drives.contains { $0.hasPrefix("if=pflash,format=raw,unit=1,file=") && $0.hasSuffix("qemu-efi-vars.fd") })
        XCTAssertTrue(drives.contains { $0.contains("id=system,format=raw") && $0.contains("disk.img") && $0.contains("aio=threads") && $0.hasSuffix("cache=writeback") })

        XCTAssertEqual(values(after: "-netdev", in: args), ["user,id=net0"])
        XCTAssertEqual(values(after: "-qmp", in: args), ["unix:/tmp/pluralism-501/\(config.shortID)/qmp.sock,server=on,wait=off"])
        XCTAssertEqual(values(after: "-display", in: args), ["none"])
        XCTAssertEqual(values(after: "-vnc", in: args), ["unix:/tmp/pluralism-501/\(config.shortID)/vnc.sock"])
        XCTAssertTrue(plan.usesIntegratedDisplay)
        XCTAssertNil(plan.swtpm)
    }

    func testSeparateWindowUsesCocoa() throws {
        var config = windowsConfig()
        config.display.qemuFrontend = .separateWindow
        config.display.qemuDevice = .virtioGPU
        let plan = try makePlan(config)
        XCTAssertEqual(values(after: "-display", in: plan.qemu.arguments), ["cocoa,zoom-to-fit=on,show-cursor=on"])
        XCTAssertFalse(plan.qemu.arguments.contains("-vnc"))
        XCTAssertTrue(values(after: "-device", in: plan.qemu.arguments).contains("virtio-gpu-pci"))
        XCTAssertFalse(plan.usesIntegratedDisplay)
    }

    func testEmulatedTPMPrefersCRB() throws {
        var config = windowsConfig()
        config.windows.tpm = .emulated
        var tc = toolchain
        tc.devices.insert("tpm-crb-device")
        let plan = try makePlan(config, toolchain: tc)
        XCTAssertEqual(plan.tpmDevice, "tpm-crb-device")
        XCTAssertTrue(values(after: "-device", in: plan.qemu.arguments).contains("tpm-crb-device,tpmdev=tpm0"))
        XCTAssertEqual(values(after: "-tpmdev", in: plan.qemu.arguments), ["emulator,id=tpm0,chardev=chrtpm"])
        let swtpm = try XCTUnwrap(plan.swtpm)
        XCTAssertEqual(swtpm.executable, "/opt/homebrew/bin/swtpm")
        XCTAssertEqual(Array(swtpm.arguments.prefix(2)), ["socket", "--tpm2"])
        XCTAssertTrue(swtpm.arguments.contains { $0.hasPrefix("type=unixio,path=/tmp/pluralism-501/") && $0.hasSuffix("tpm.sock,terminate") })
    }

    func testEmulatedTPMFallsBackToTIS() throws {
        var config = windowsConfig()
        config.windows.tpm = .emulated
        let plan = try makePlan(config)
        XCTAssertEqual(plan.tpmDevice, "tpm-tis-device")
    }

    func testTPMWithoutSWTPMFails() {
        var config = windowsConfig()
        config.windows.tpm = .emulated
        var tc = toolchain
        tc.swtpmPath = nil
        XCTAssertThrowsError(try makePlan(config, toolchain: tc)) { error in
            XCTAssertEqual(error as? QEMUPlanError, .missingSWTPM)
        }
    }

    func testSecureBootNeedsSecureFirmware() {
        var config = windowsConfig()
        config.windows.secureBoot = true
        XCTAssertThrowsError(try makePlan(config)) { error in
            XCTAssertEqual(error as? QEMUPlanError, .missingSecureBootFirmware)
        }
        var tc = toolchain
        tc.secureFirmwareCodePath = "/x/edk2-aarch64-secure-code.fd"
        tc.secureFirmwareVarsTemplatePath = "/x/edk2-arm-secure-vars.fd"
        XCTAssertNoThrow(try makePlan(config, toolchain: tc))
    }

    func testMissingFirmwareFails() {
        var tc = toolchain
        tc.firmwareCodePath = nil
        XCTAssertThrowsError(try makePlan(windowsConfig(), toolchain: tc)) { error in
            XCTAssertEqual(error as? QEMUPlanError, .missingFirmware)
        }
    }

    func testASIFIsRejected() {
        var config = windowsConfig()
        config.disk = DiskSettings(sizeGiB: 96, format: .asif)
        XCTAssertThrowsError(try makePlan(config))
    }

    func testCommasInPathsAreEscaped() throws {
        let config = windowsConfig()
        let plan = try makePlan(config, media: QEMUMedia(installerISO: "/Users/musti/ISO/Win,11.iso"))
        XCTAssertTrue(values(after: "-drive", in: plan.qemu.arguments).contains { $0.hasSuffix("file=/Users/musti/ISO/Win,,11.iso") })
        XCTAssertEqual(QEMUCommandBuilder.escape("a,b,,c"), "a,,b,,,,c")
    }

    func testMediaOrderAndOptions() throws {
        var config = windowsConfig()
        config.advanced.nestedVirtualization = true
        config.advanced.hideSME = true
        config.disk.syncMode = .none
        let media = QEMUMedia(installerISO: "/i.iso", driverISO: "/v.iso", unattendISO: "/u.iso")
        let plan = try makePlan(config, media: media)
        let args = plan.qemu.arguments
        XCTAssertEqual(values(after: "-machine", in: args), ["virt,gic-version=3,virtualization=on"])
        XCTAssertEqual(values(after: "-cpu", in: args), ["host,sme=off"])
        XCTAssertTrue(values(after: "-drive", in: args).contains { $0.contains("id=system") && $0.hasSuffix(",cache=unsafe") })
        let storage = values(after: "-device", in: args).filter { $0.hasPrefix("usb-storage") }
        XCTAssertEqual(storage, [
            "usb-storage,drive=installer,removable=on,bus=xhci.0,bootindex=0",
            "usb-storage,drive=drivers,removable=on,bus=xhci.0",
            "usb-storage,drive=unattend,removable=on,bus=xhci.0"
        ])
    }

    func testRemoteDesktopForward() throws {
        var config = windowsConfig()
        config.windows.rdpHostPort = 33389
        config.network.portForwards = [PortForward(hostPort: 2222, guestPort: 22)]
        let plan = try makePlan(config)
        XCTAssertEqual(values(after: "-netdev", in: plan.qemu.arguments),
                       ["user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:33389-:3389"])
    }

    func testNVMeBusAndMigrationHelperDisk() throws {
        var config = windowsConfig()
        config.disk.bus = .nvme
        var plan = try makePlan(config)
        var devices = values(after: "-device", in: plan.qemu.arguments)
        XCTAssertTrue(devices.contains("nvme,drive=system,serial=pluralism0,bootindex=1"))
        XCTAssertFalse(plan.qemu.arguments.contains("-object"))

        config.disk.migration = .driverPending
        plan = try makePlan(config)
        devices = values(after: "-device", in: plan.qemu.arguments)
        XCTAssertTrue(devices.contains("nvme,drive=system,serial=pluralism0,bootindex=1"))
        XCTAssertTrue(devices.contains("virtio-blk-pci,drive=helper,iothread=iothread0"))
        XCTAssertTrue(values(after: "-drive", in: plan.qemu.arguments).contains { $0.hasPrefix("if=none,id=helper,format=raw") && $0.hasSuffix("virtio-helper.img") })
    }

    func testVmnetRelayBackend() throws {
        let config = windowsConfig()
        let runtime = RuntimePaths(config: config, userID: 501)
        let plan = try QEMUCommandBuilder.makePlan(config: config, bundle: bundle, toolchain: toolchain, runtime: runtime,
                                                   media: QEMUMedia(),
                                                   network: .vmnetRelay(socket: runtime.netSocket.path))
        let base = "/tmp/pluralism-501/\(config.shortID)"
        XCTAssertEqual(values(after: "-netdev", in: plan.qemu.arguments),
                       ["stream,id=net0,server=off,addr.type=unix,addr.path=\(base)/net.sock,reconnect-ms=1000"])
        XCTAssertTrue(values(after: "-device", in: plan.qemu.arguments).contains("virtio-net-pci,netdev=net0,mac=\(config.network.macAddress)"))
        XCTAssertTrue(runtime.allSocketPathsFit)
    }

    func testHostOnlyFallbackIsRestricted() throws {
        var config = windowsConfig()
        config.network.mode = .hostOnly
        let plan = try makePlan(config)
        XCTAssertEqual(values(after: "-netdev", in: plan.qemu.arguments), ["user,id=net0,restrict=on"])
    }

    func testLinuxPlanUsesVirtioBlock() throws {
        var config = VMConfiguration.makeDefault(name: "Debian", guestOS: .linux, host: host)
        config.engine = .qemu
        config.disk = DiskSettings(sizeGiB: 64, format: .qcow2, bus: .nvme)
        let plan = try makePlan(config)
        let devices = values(after: "-device", in: plan.qemu.arguments)
        // Linux-Gäste laufen in QEMU immer mit virtio-blk.
        XCTAssertTrue(devices.contains("virtio-blk-pci,drive=system,iothread=iothread0,num-queues=4,bootindex=1"))
        XCTAssertFalse(plan.qemu.arguments.contains("-fsdev"))
        XCTAssertEqual(values(after: "-rtc", in: plan.qemu.arguments), ["base=utc"])
        XCTAssertTrue(values(after: "-netdev", in: plan.qemu.arguments).first?.contains("hostfwd") == false)
    }

    func testCustomAccelReplacesDefault() throws {
        var config = windowsConfig()
        config.advanced.extraQEMUArguments = ["-accel", "hvf,kernel-irqchip=off"]
        let plan = try makePlan(config)
        XCTAssertEqual(values(after: "-accel", in: plan.qemu.arguments), ["hvf,kernel-irqchip=off"])
    }

    func testNoNetworkMode() throws {
        var config = windowsConfig()
        config.network.mode = .none
        let plan = try makePlan(config)
        XCTAssertFalse(plan.qemu.arguments.contains("-netdev"))
    }

    func testDiskCreateArguments() {
        XCTAssertEqual(QEMUCommandBuilder.diskCreateArguments(path: "/d.qcow2", sizeGiB: 96, format: .qcow2),
                       ["create", "-f", "qcow2", "-o", "lazy_refcounts=on,preallocation=off", "/d.qcow2", "96G"])
    }

    func testDeviceHelpAndVersionParsing() {
        let help = """
        Storage devices:
        name "nvme", bus PCI, desc "Non-Volatile Memory Express"
        name "usb-storage", bus usb-bus

        Misc devices:
        name "tpm-tis-device", bus System, desc "TPM TIS sysbus device"
        """
        let devices = QEMUToolchainLocator.parseDeviceHelp(help)
        XCTAssertEqual(devices, ["nvme", "usb-storage", "tpm-tis-device"])
        XCTAssertEqual(QEMUToolchainLocator.parseVersion("QEMU emulator version 11.1.2 (Homebrew)\nCopyright"), "11.1.2")
        XCTAssertNil(QEMUToolchainLocator.parseVersion("nonsense"))
        XCTAssertEqual(QEMUToolchainLocator.firmwareDirectories(forQEMUBinary: "/opt/homebrew/bin/qemu-system-aarch64").first,
                       "/opt/homebrew/share/qemu")
    }

    // MARK: QMP

    func testQMPCommandEncoding() throws {
        let data = QMPCommand.sendKeys(["ctrl", "alt", "delete"]).encoded(id: 7)
        XCTAssertEqual(data.last, 0x0A)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        XCTAssertEqual(object["execute"] as? String, "send-key")
        XCTAssertEqual(object["id"] as? Int, 7)
        let arguments = try XCTUnwrap(object["arguments"] as? [String: Any])
        let keys = try XCTUnwrap(arguments["keys"] as? [[String: String]])
        XCTAssertEqual(keys.map { $0["data"] }, ["ctrl", "alt", "delete"])
        XCTAssertEqual(keys.first?["type"], "qcode")

        let powerdown = String(decoding: QMPCommand.systemPowerdown.encoded(), as: UTF8.self)
        XCTAssertEqual(powerdown, "{\"execute\":\"system_powerdown\"}\n")
    }

    func testQMPMessageParsing() {
        let greeting = #"{"QMP": {"version": {"qemu": {"micro": 2, "minor": 1, "major": 11}, "package": ""}, "capabilities": ["oob"]}}"#
        XCTAssertEqual(QMPMessage.parse(Data(greeting.utf8)), .greeting(version: "11.1.2"))
        XCTAssertEqual(QMPMessage.parse(Data(#"{"return": {}}"#.utf8)), .success(id: nil, status: nil))
        XCTAssertEqual(QMPMessage.parse(Data(#"{"return": {"status": "running", "running": true}, "id": 3}"#.utf8)),
                       .success(id: 3, status: "running"))
        XCTAssertEqual(QMPMessage.parse(Data(#"{"event": "SHUTDOWN", "data": {"guest": true}}"#.utf8)), .event(name: "SHUTDOWN"))
        XCTAssertEqual(QMPMessage.parse(Data(#"{"error": {"class": "GenericError", "desc": "kaputt"}}"#.utf8)),
                       .failure(id: nil, description: "kaputt"))
        XCTAssertNil(QMPMessage.parse(Data("kein json".utf8)))
    }

    func testLineBuffer() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}"])
        XCTAssertEqual(buffer.append(Data(":2}\n\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"b\":2}"])
        XCTAssertTrue(buffer.append(Data()).isEmpty)
    }
}
