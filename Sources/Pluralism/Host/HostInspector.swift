import Darwin
import Foundation
import PluralismCore

/// Liest die Daten des Macs (Chip, Kerne, Speicher, macOS-Version) per sysctl.
enum HostInspector {
    static func currentProfile() -> HostProfile {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let performance = sysctlInt("hw.perflevel0.physicalcpu") ?? sysctlInt("hw.physicalcpu") ?? 4
        let efficiency = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        let memory = UInt64(sysctlInt("hw.memsize") ?? 8 * 1024 * 1024 * 1024)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return HostProfile(chipName: chip,
                           performanceCores: performance,
                           efficiencyCores: efficiency,
                           physicalMemoryBytes: memory,
                           macOSMajorVersion: os.majorVersion,
                           macOSMinorVersion: os.minorVersion)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size {
            return Int(Int32(truncatingIfNeeded: value))
        }
        return Int(value)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
