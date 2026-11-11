// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Founderizer",
    // The Mac app needs macOS 15; Fleet Mobile (ios/) needs iOS 18. Only `FleetCore` builds for both:
    // the other targets are the Mac app and its two services, and nothing in iOS depends on them.
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.executable(name: "Founderizer", targets: ["Founderizer"]),
               .executable(name: "FounderizerInstaller", targets: ["FounderizerInstaller"]),
               .library(name: "FleetCore", targets: ["FleetCore"]),
               .library(name: "FleetMark", targets: ["FleetMark"])],
    targets: [
        .target(name: "FleetCore"),
        // An agent's mark: the one definition of its shape and its colour, for both apps. It imports SwiftUI, which
        // is why it is beside `FleetCore` and not inside it.
        .target(name: "FleetMark"),
        .target(name: "FleetSetupIPC"),
        .target(name: "FleetVaultIPC"),
        .target(name: "FleetVaultCore", dependencies: ["FleetVaultIPC"]),
        // The import of secrets from another password manager's export file (Bitwarden, 1Password): it reads the file
        // in this process and gives rows to Add secret's own save. The Mac app only; the iPhone app does not link it.
        .target(name: "FleetImport", dependencies: ["FleetCore"]),
        .executableTarget(name: "Founderizer", dependencies: ["FleetCore", "FleetImport", "FleetMark", "FleetSetupIPC"]),
        .executableTarget(name: "FleetSetupService", dependencies: ["FleetCore", "FleetSetupIPC"]),
        // The installer for an always-on Mac (PRODUCT.md P3): it shows a link code and takes the owner's own order.
        .executableTarget(name: "FounderizerInstaller", dependencies: ["FleetCore", "FleetMark"]),
        .executableTarget(name: "FleetVault", dependencies: ["FleetVaultCore"]),
        .testTarget(name: "FleetCoreTests", dependencies: ["FleetCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FleetVaultTests", dependencies: ["FleetVaultCore", "FleetVaultIPC"]),
        .testTarget(name: "FleetImportTests", dependencies: ["FleetImport", "FleetCore"], exclude: ["make_fixtures.py"]),
        .testTarget(name: "FleetMarkTests", dependencies: ["FleetMark"])
    ]
)
