// swift-tools-version:5.10
//
// Pluralism: eine eigene Virtualisierungs-App für Apple-Silicon-Macs.
// Gäste: Linux ARM64 (Apple Virtualization.framework) und
// Windows 11 ARM64 (QEMU mit Hypervisor.framework). Kein x86.
//
// Aufbau:
//   PluralismCore  reine Logik ohne Apple-UI-Frameworks (Konfiguration, QEMU-Befehle,
//                  Antwortdatei, RFB-Protokoll, Tastatur-Tabellen). Läuft auch unter Linux
//                  und ist dort testbar.
//   Pluralism      die macOS-App (SwiftUI, AppKit, Virtualization). Nur auf macOS.

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
targets.append(
    .executableTarget(
        name: "Pluralism",
        dependencies: ["PluralismCore"],
        path: "Sources/Pluralism",
        linkerSettings: [
            .linkedFramework("Virtualization"),
            .linkedFramework("AppKit"),
            .linkedFramework("Carbon")
        ]
    )
)
#endif

let package = Package(
    name: "Pluralism",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
