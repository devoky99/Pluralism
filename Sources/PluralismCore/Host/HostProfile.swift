import Foundation

/// Beschreibung des Macs, auf dem Pluralism läuft. Wird in der App per sysctl befüllt,
/// in Tests von Hand. Für ein MacBook Pro M4 Pro (12 Kerne) gilt: 8 Performance-Kerne,
/// 4 Effizienz-Kerne.
public struct HostProfile: Equatable, Sendable {
    public var chipName: String
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var physicalMemoryBytes: UInt64
    public var macOSMajorVersion: Int
    public var macOSMinorVersion: Int
    /// Apple-Chip-Generation (1 für M1, 4 für M4). 0 = unbekannt.
    public var appleChipGeneration: Int

    public init(chipName: String, performanceCores: Int, efficiencyCores: Int, physicalMemoryBytes: UInt64,
                macOSMajorVersion: Int, macOSMinorVersion: Int = 0, appleChipGeneration: Int? = nil) {
        self.chipName = chipName
        self.performanceCores = max(1, performanceCores)
        self.efficiencyCores = max(0, efficiencyCores)
        self.physicalMemoryBytes = physicalMemoryBytes
        self.macOSMajorVersion = macOSMajorVersion
        self.macOSMinorVersion = macOSMinorVersion
        self.appleChipGeneration = appleChipGeneration ?? HostProfile.chipGeneration(from: chipName)
    }

    public var totalCores: Int { performanceCores + efficiencyCores }

    public var physicalMemoryMiB: Int { Int(physicalMemoryBytes / 1_048_576) }

    /// Verschachtelte Virtualisierung: M3 oder neuer und macOS 15 oder neuer.
    public var supportsNestedVirtualization: Bool {
        appleChipGeneration >= 3 && macOSMajorVersion >= 15
    }

    /// SME (Scalable Matrix Extension) gibt es ab dem M4.
    public var hasSME: Bool { appleChipGeneration >= 4 }

    /// Liest die Generation aus Namen wie "Apple M4 Pro".
    public static func chipGeneration(from chipName: String) -> Int {
        guard let range = chipName.range(of: #"M(\d+)"#, options: .regularExpression) else { return 0 }
        let digits = chipName[range].dropFirst()
        return Int(digits) ?? 0
    }

    /// Referenzprofil: MacBook Pro 14" mit M4 Pro (12 CPU-Kerne, 48 GB).
    public static let macBookProM4Pro48GB = HostProfile(
        chipName: "Apple M4 Pro",
        performanceCores: 8,
        efficiencyCores: 4,
        physicalMemoryBytes: 48 * 1024 * 1024 * 1024,
        macOSMajorVersion: 26
    )
}

public struct ResourceRecommendation: Equatable, Sendable {
    public var cpuCount: Int
    public var memoryMiB: Int
    public var diskGiB: Int
}

public struct ResourceLimits: Equatable, Sendable {
    public var maxCPUCount: Int
    /// Ab hier warnt die UI, weil vCPUs auf Effizienz-Kernen landen können.
    public var comfortableCPUCount: Int
    public var maxMemoryMiB: Int
}

/// Empfiehlt Ressourcen passend zum Gast und zum Mac.
///
/// Leitlinien aus der Recherche:
/// - vCPU-Threads werden von macOS frei auf P- und E-Kerne verteilt. Mehr vCPUs als
///   Performance-Kerne bringen meist wenig und kosten Akku. UTM nimmt für Windows
///   standardmäßig die Zahl der P-Kerne.
/// - Hypervisor-Gäste sehen alle Kerne als gleich (keine P/E-Unterscheidung im Gast).
/// - macOS braucht selbst genug Speicher, sonst fängt das System an auszulagern.
public enum ResourceAdvisor {
    public static func recommend(for guestOS: GuestOS, host: HostProfile) -> ResourceRecommendation {
        let p = host.performanceCores
        let hostGiB = host.physicalMemoryMiB / 1024

        let cpu: Int
        switch guestOS {
        case .linux:
            cpu = clamp(p / 2, 2, 6)
        case .windows:
            cpu = clamp((p * 3) / 4, 2, 8)
        }

        let memoryGiB: Int
        switch hostGiB {
        case ..<12: memoryGiB = guestOS == .windows ? 4 : 2
        case ..<20: memoryGiB = 4
        case ..<36: memoryGiB = 8
        default: memoryGiB = guestOS == .windows ? 12 : 8
        }

        let disk = guestOS == .windows ? 96 : 64
        let limits = limits(host: host)
        return ResourceRecommendation(
            cpuCount: min(cpu, limits.maxCPUCount),
            memoryMiB: min(memoryGiB * 1024, limits.maxMemoryMiB),
            diskGiB: disk
        )
    }

    public static func limits(host: HostProfile) -> ResourceLimits {
        // macOS bekommt mindestens 4 GB oder ein Viertel, je nachdem was größer ist.
        let reserveMiB = max(4096, host.physicalMemoryMiB / 4)
        let maxMemory = max(1024, host.physicalMemoryMiB - reserveMiB)
        return ResourceLimits(
            maxCPUCount: host.totalCores,
            comfortableCPUCount: host.performanceCores,
            maxMemoryMiB: (maxMemory / 256) * 256
        )
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }
}
