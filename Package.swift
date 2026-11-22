// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Founderizer",
    // The Mac app needs macOS 15; Fleet Mobile (ios/) needs iOS 18. Only `FleetCore` builds for both:
    // the other targets are the Mac app and its two services, and nothing in iOS depends on them.
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.executable(name: "Founderizer", targets: ["Founderizer"]),
               .executable(name: "FounderizerInstaller", targets: ["FounderizerInstaller"]),
               // The program inside the app for the owner's own AI agent (OWNER-MCP.md, "The program inside the app").
               // Not `founderizer`: a Mac's disk takes that and the app's own `Founderizer` as one file.
               .executable(name: "founderizer-cli", targets: ["FounderizerCLI"]),
               .library(name: "FleetCore", targets: ["FleetCore"]),
               .library(name: "FleetMark", targets: ["FleetMark"])],
    targets: [
        .target(name: "FleetCore"),
        // An agent's mark: the one definition of its shape and its colour, for both apps. It imports SwiftUI, which
        // is why it is beside `FleetCore` and not inside it.
        .target(name: "FleetMark"),
        .target(name: "FleetSetupIPC"),
        // The owner API for the program inside the app: the table of the tools, the calls, the four reads, the MCP
        // server, the lock and the link. No view.
        .target(name: "FleetOwnerAPI"),
        .executableTarget(name: "FounderizerCLI", dependencies: ["FleetOwnerAPI"]),
        .target(name: "FleetVaultIPC"),
        .target(name: "FleetVaultCore", dependencies: ["FleetVaultIPC"]),
        // The import of secrets from another password manager's export file (Bitwarden, 1Password): it reads the file
        // in this process and gives rows to Add secret's own save. The Mac app only; the iPhone app does not link it.
        .target(name: "FleetImport", dependencies: ["FleetCore"]),
        // The client of a cluster's store (the door's stage B): Bitwarden Secrets Manager in plain HTTPS calls, with
        // CryptoKit and CommonCrypto, and the steps of a Save that writes the store before the vault. The Mac app only.
        .target(name: "FleetStoreKeys", dependencies: ["FleetCore"]),
        .executableTarget(name: "Founderizer", dependencies: ["FleetCore", "FleetImport", "FleetMark", "FleetSetupIPC",
                                                             "FleetOwnerAPI"]),
        .executableTarget(name: "FleetSetupService", dependencies: ["FleetCore", "FleetSetupIPC"]),
        // The installer for an always-on Mac (PRODUCT.md P3): it shows a link code and takes the owner's own order.
        .executableTarget(name: "FounderizerInstaller", dependencies: ["FleetCore", "FleetMark"]),
        .executableTarget(name: "FleetVault", dependencies: ["FleetVaultCore"]),
        .testTarget(name: "FleetCoreTests", dependencies: ["FleetCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FleetVaultTests", dependencies: ["FleetVaultCore", "FleetVaultIPC"]),
        .testTarget(name: "FleetImportTests", dependencies: ["FleetImport", "FleetCore"], exclude: ["make_fixtures.py"]),
        .testTarget(name: "FleetStoreKeysTests", dependencies: ["FleetStoreKeys", "FleetCore"]),
        .testTarget(name: "FleetMarkTests", dependencies: ["FleetMark"]),
        .testTarget(name: "FleetOwnerAPITests", dependencies: ["FleetOwnerAPI", "FleetCore"], resources: [.copy("Fixtures")]),
        // The tests of the Mac app's views: the real views in a window that no screen shows, on a test's own defaults
        // and folder and a hub address where no server answers (`ViewHost`).
        .testTarget(name: "FounderizerViewTests", dependencies: ["Founderizer", "FleetCore"])
    ]
)
