// swift-tools-version:5.10
//
// Pluralism: eigene Virtualisierungs-App für Apple-Silicon-Macs.
// Gäste: Linux ARM64 (Apple Virtualization.framework) und
// Windows 11 ARM64 (mitgeliefertes QEMU mit Hypervisor.framework). Kein x86.
// Zielsystem: macOS 27.
//
// Aufbau:
//   PluralismCore      reine Logik ohne Apple-Frameworks (Konfiguration, QEMU-Befehle,
//                      Antwortdatei, RFB-Protokoll, Tastatur, DHCP-Test). Läuft auch unter
//                      Linux und ist dort testbar.
//   PluralismNet       Netzwerk über Apples vmnet (eigenes Netz pro VM, Paketbrücke für QEMU).
//   Pluralism          die macOS-App (SwiftUI, AppKit, Virtualization).
//   pluralism-netcheck Prüfprogramm für CI: baut ein vmnet-Netz und holt per DHCP eine Adresse.

import PackageDescription

var products: [Product] = [
    .library(name: "PluralismCore", targets: ["PluralismCore"])
]

var targets: [Target] = [
    .target(
        name: "PluralismCore",
        path: "Sources/PluralismCore"
    ),
    .testTarget(
        name: "PluralismCoreTests",
        dependencies: ["PluralismCore"],
        path: "Tests/PluralismCoreTests"
    )
]

#if os(macOS)
products.append(.executable(name: "Pluralism", targets: ["Pluralism"]))
products.append(.executable(name: "pluralism-netcheck", targets: ["PluralismNetCheck"]))
targets.append(contentsOf: [
    .target(
        name: "PluralismNet",
        dependencies: ["PluralismCore"],
        path: "Sources/PluralismNet",
        linkerSettings: [
            .linkedFramework("vmnet")
        ]
    ),
    .executableTarget(
        name: "Pluralism",
        dependencies: ["PluralismCore", "PluralismNet"],
        path: "Sources/Pluralism",
        linkerSettings: [
            .linkedFramework("Virtualization"),
            .linkedFramework("AppKit"),
            .linkedFramework("Carbon")
        ]
    ),
    .executableTarget(
        name: "PluralismNetCheck",
        dependencies: ["PluralismCore", "PluralismNet"],
        path: "Sources/PluralismNetCheck"
    )
])
#endif

let package = Package(
    name: "Pluralism",
    platforms: [
        .macOS("27.0")
    ],
    products: products,
    targets: targets
)
