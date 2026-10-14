import Foundation
@testable import PluralismCore
import XCTest

final class ConfigurationTests: XCTestCase {
    let host = HostProfile.macBookProM4Pro48GB

    func testHostProfileOfM4Pro() {
        XCTAssertEqual(host.appleChipGeneration, 4)
        XCTAssertEqual(host.totalCores, 12)
        XCTAssertTrue(host.supportsNestedVirtualization)
        XCTAssertTrue(host.hasSME)
        XCTAssertEqual(HostProfile.chipGeneration(from: "Apple M1"), 1)
        XCTAssertEqual(HostProfile.chipGeneration(from: "Apple M3 Max"), 3)
        XCTAssertEqual(HostProfile.chipGeneration(from: "Intel(R) Core(TM) i5"), 0)
    }

    func testNestedVirtualizationNeedsM3AndMacOS15() {
        let m1 = HostProfile(chipName: "Apple M1", performanceCores: 4, efficiencyCores: 4,
                             physicalMemoryBytes: 16 << 30, macOSMajorVersion: 15)
        XCTAssertFalse(m1.supportsNestedVirtualization)
        let m3OnSonoma = HostProfile(chipName: "Apple M3", performanceCores: 4, efficiencyCores: 4,
                                     physicalMemoryBytes: 16 << 30, macOSMajorVersion: 14)
        XCTAssertFalse(m3OnSonoma.supportsNestedVirtualization)
    }

    func testRecommendationsForM4Pro() {
        let linux = ResourceAdvisor.recommend(for: .linux, host: host)
        XCTAssertEqual(linux.cpuCount, 4)
        XCTAssertEqual(linux.memoryMiB, 8 * 1024)
        XCTAssertEqual(linux.diskGiB, 64)

        let windows = ResourceAdvisor.recommend(for: .windows, host: host)
        XCTAssertEqual(windows.cpuCount, 6)
        XCTAssertEqual(windows.memoryMiB, 12 * 1024)
        XCTAssertEqual(windows.diskGiB, 96)

        let limits = ResourceAdvisor.limits(host: host)
        XCTAssertEqual(limits.maxCPUCount, 12)
        XCTAssertEqual(limits.comfortableCPUCount, 8)
        XCTAssertEqual(limits.maxMemoryMiB, 36 * 1024)
    }

    func testRecommendationsOnSmallMac() {
        let small = HostProfile(chipName: "Apple M1", performanceCores: 4, efficiencyCores: 4,
                                physicalMemoryBytes: 8 << 30, macOSMajorVersion: 14)
        let windows = ResourceAdvisor.recommend(for: .windows, host: small)
        XCTAssertGreaterThanOrEqual(windows.cpuCount, 2)
        XCTAssertLessThanOrEqual(windows.memoryMiB, ResourceAdvisor.limits(host: small).maxMemoryMiB)
    }

    func testDefaultsPerGuest() {
        let linux = VMConfiguration.makeDefault(name: "Fedora", guestOS: .linux, host: host)
        XCTAssertEqual(linux.engine, .appleVirtualization)
        XCTAssertEqual(linux.disk.format, .raw)
        XCTAssertEqual(linux.disk.fileName, "disk.img")
        XCTAssertTrue(linux.validationIssues(host: host).isEmpty)

        let windows = VMConfiguration.makeDefault(name: "Windows 11", guestOS: .windows, host: host)
        XCTAssertEqual(windows.engine, .qemu)
        XCTAssertEqual(windows.disk.format, .qcow2)
        XCTAssertEqual(windows.disk.fileName, "disk.qcow2")
        XCTAssertEqual(windows.windows.rdpHostPort, 33389)
        XCTAssertEqual(windows.display.qemuDevice, .ramfb)
        XCTAssertTrue(windows.validationIssues(host: host).isEmpty)
    }

    func testValidationCatchesWindowsMinimums() {
        var config = VMConfiguration.makeDefault(name: "Win", guestOS: .windows, host: host)
        config.memoryMiB = 2048
        config.cpuCount = 1
        config.disk.sizeGiB = 32
        let issues = config.validationIssues(host: host)
        XCTAssertTrue(issues.contains { $0.contains("4 GB") })
        XCTAssertTrue(issues.contains { $0.contains("2 Kerne") })
        XCTAssertTrue(issues.contains { $0.contains("64 GB") })
    }

    func testValidationCatchesWrongEngineAndFormat() {
        var config = VMConfiguration.makeDefault(name: "Win", guestOS: .windows, host: host)
        config.engine = .appleVirtualization
        config.disk.format = .qcow2
        let issues = config.validationIssues(host: host)
        XCTAssertTrue(issues.contains { $0.contains("QEMU-Engine") })
        XCTAssertTrue(issues.contains { $0.contains("qcow2") })
    }

    func testValidationCatchesDuplicatePortsAndShares() {
        var config = VMConfiguration.makeDefault(name: "Win", guestOS: .windows, host: host)
        config.network.portForwards = [PortForward(hostPort: 33389, guestPort: 22)]
        config.sharedFolders = [SharedFolder(name: "Daten", hostPath: "/a"), SharedFolder(name: "daten", hostPath: "/b")]
        let issues = config.validationIssues(host: host)
        XCTAssertTrue(issues.contains { $0.contains("33389") })
        XCTAssertTrue(issues.contains { $0.contains("doppelt") })
    }

    func testJSONRoundTrip() throws {
        var config = VMConfiguration.makeDefault(name: "Test", guestOS: .windows, host: host)
        config.sharedFolders = [SharedFolder(name: "Projekte", hostPath: "/Users/musti/Projekte", readOnly: true)]
        config.network.portForwards = [PortForward(proto: .tcp, hostPort: 2222, guestPort: 22, label: "SSH")]
        let data = try PluralismJSON.encoder().encode(config)
        let decoded = try PluralismJSON.decoder().decode(VMConfiguration.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testDecodingOldFileWithMissingFields() throws {
        let json = """
        {
          "id": "6C2A2E8E-0000-4000-8000-000000000001",
          "name": "Alt",
          "guestOS": "linux",
          "cpuCount": 2,
          "memoryMiB": 4096
        }
        """
        let config = try PluralismJSON.decoder().decode(VMConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(config.name, "Alt")
        XCTAssertEqual(config.engine, .appleVirtualization)
        XCTAssertEqual(config.disk.sizeGiB, 64)
        XCTAssertTrue(config.integration.clipboard)
        XCTAssertTrue(MACAddress.isValid(config.network.macAddress))
        XCTAssertFalse(config.media.attachGuestTools)
    }

    func testMACAddresses() {
        for _ in 0..<50 {
            let mac = MACAddress.random()
            XCTAssertTrue(MACAddress.isValid(mac), mac)
            XCTAssertTrue(mac.hasPrefix("52:54:00:"))
        }
        XCTAssertFalse(MACAddress.isValid("52:54:00:zz:00:01"))
        XCTAssertFalse(MACAddress.isValid("52:54:00:00:01"))
    }

    func testSharedFolderNamesAreSanitized() {
        XCTAssertEqual(SharedFolder.sanitizedName("Meine Dateien/2026"), "Meine_Dateien_2026")
        XCTAssertEqual(SharedFolder.sanitizedName("..."), "Ordner")
        XCTAssertEqual(SharedFolder(name: "a b", hostPath: "/x").name, "a_b")
    }

    func testRuntimePathsAreShortEnoughForSockets() {
        let config = VMConfiguration.makeDefault(name: "X", guestOS: .windows, host: host)
        let runtime = RuntimePaths(config: config, userID: 501)
        XCTAssertTrue(runtime.allSocketPathsFit)
        XCTAssertEqual(runtime.qmpSocket.path, "/tmp/pluralism-501/\(config.shortID)/qmp.sock")
        XCTAssertEqual(config.shortID.count, 8)
    }

    func testDiskFormatSupport() {
        XCTAssertTrue(DiskFormat.raw.isSupported(by: .qemu))
        XCTAssertTrue(DiskFormat.raw.isSupported(by: .appleVirtualization))
        XCTAssertTrue(DiskFormat.asif.isSupported(by: .appleVirtualization))
        XCTAssertFalse(DiskFormat.asif.isSupported(by: .qemu))
        XCTAssertFalse(DiskFormat.qcow2.isSupported(by: .appleVirtualization))
    }

    func testRegionPresets() {
        var settings = UnattendSettings()
        let turkish = UnattendSettings.regionPresets.first { $0.locale == "tr-TR" }!
        settings.apply(turkish)
        XCTAssertEqual(settings.uiLanguage, "tr-TR")
        XCTAssertEqual(settings.inputLocale, "041f:0000041f")
        XCTAssertEqual(settings.timeZone, "Turkey Standard Time")
    }
}
