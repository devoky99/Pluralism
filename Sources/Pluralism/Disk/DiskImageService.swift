import Foundation
import PluralismCore

/// Legt Systemplatten an und vergrößert sie.
enum DiskImageService {
    static func createDisk(at url: URL, sizeGiB: Int, format: DiskFormat, toolchain: QEMUToolchain?) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            throw PluralismError.message("Die Platte existiert bereits: \(url.path)")
        }
        switch format {
        case .raw:
            // Dünn belegt: APFS reserviert nur, was wirklich geschrieben wird.
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw PluralismError.message("Die Plattendatei konnte nicht angelegt werden.")
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(sizeGiB) * 1024 * 1024 * 1024)
        case .asif:
            // Apple Sparse Image Format (macOS 26), angelegt mit diskutil.
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) else {
                throw PluralismError.message("ASIF-Platten brauchen macOS 26 oder neuer.")
            }
            try ShellCommand.runChecked("/usr/sbin/diskutil", ["image", "create", "blank",
                                                               "--fs", "none",
                                                               "--format", "ASIF",
                                                               "--size", "\(sizeGiB)G",
                                                               url.path])
            if !fm.fileExists(atPath: url.path) {
                throw PluralismError.message("diskutil hat keine ASIF-Datei unter \(url.path) erzeugt.")
            }
        case .qcow2:
            guard let qemuImg = toolchain?.qemuImgPath else {
                throw PluralismError.message("Für qcow2-Platten fehlt qemu-img. Installiere QEMU mit „brew install qemu“.")
            }
            try ShellCommand.runChecked(qemuImg, QEMUCommandBuilder.diskCreateArguments(path: url.path, sizeGiB: sizeGiB, format: .qcow2))
        }
    }

    /// Vergrößert eine Platte. Verkleinern ist absichtlich nicht möglich (Datenverlust).
    /// Danach muss die Partition im Gast erweitert werden.
    static func grow(at url: URL, toGiB sizeGiB: Int, format: DiskFormat, toolchain: QEMUToolchain?) throws {
        switch format {
        case .raw:
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let newSize = UInt64(sizeGiB) * 1024 * 1024 * 1024
            let current = try handle.seekToEnd()
            guard newSize > current else { return }
            try handle.truncate(atOffset: newSize)
        case .asif:
            try ShellCommand.runChecked("/usr/sbin/diskutil", ["image", "resize", "--size", "\(sizeGiB)G", url.path])
        case .qcow2:
            guard let qemuImg = toolchain?.qemuImgPath else {
                throw PluralismError.message("Zum Vergrößern fehlt qemu-img.")
            }
            try ShellCommand.runChecked(qemuImg, ["resize", url.path, "\(sizeGiB)G"])
        }
    }

    /// Tatsächlich belegter Platz (dünn belegte Dateien sind kleiner als ihre Nenngröße).
    static func allocatedBytes(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if let total = values?.totalFileAllocatedSize { return Int64(total) }
        if let size = values?.fileAllocatedSize { return Int64(size) }
        return nil
    }
}

/// ISO-Abbilder bauen und einhängen (über die Bordmittel hdiutil).
enum ISOBuilder {
    /// Baut aus einem Ordner ein ISO (ISO 9660 + Joliet), das Windows und Linux lesen.
    static func makeISO(from folder: URL, volumeName: String, output: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }
        try ShellCommand.runChecked("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet",
                                                         "-default-volume-name", volumeName,
                                                         "-o", output.path, folder.path])
        // hdiutil hängt manchmal ".iso" an, wenn der Name anders endet.
        if !fm.fileExists(atPath: output.path) {
            let alternative = output.appendingPathExtension("iso")
            if fm.fileExists(atPath: alternative.path) {
                try fm.moveItem(at: alternative, to: output)
            }
        }
    }

    /// Hängt ein Abbild schreibgeschützt und unsichtbar ein und liefert den Mount-Punkt.
    static func attach(_ image: URL) throws -> URL {
        let output = try ShellCommand.runChecked("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noverify", "-plist", image.path], timeout: 120)
        guard let start = output.range(of: "<?xml"),
              let data = String(output[start.lowerBound...]).data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw PluralismError.message("Das Abbild konnte nicht eingehängt werden: \(image.lastPathComponent)")
        }
        return URL(fileURLWithPath: mount, isDirectory: true)
    }

    static func detach(_ mountPoint: URL) {
        _ = try? ShellCommand.run("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint.path], timeout: 60)
    }
}
