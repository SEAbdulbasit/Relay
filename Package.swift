// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Relay",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Relay", targets: ["Relay"]), .executable(name: "RelayAccessibilityFixture", targets: ["RelayAccessibilityFixture"]), .executable(name: "JournalCrashFixture", targets: ["JournalCrashFixture"]), .executable(name: "RelayStandardPolicyFixture", targets: ["RelayStandardPolicyFixture"])],
    dependencies: [.package(path: "Vendor/LiteRTLM")],
    targets: [
        .target(name: "RelayJournal", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Relay", dependencies: ["RelayJournal", "PolicyMetadataProcess", .product(name: "LiteRTLM", package: "LiteRTLM")], swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        .executableTarget(name: "RelayAccessibilityFixture", swiftSettings: [.defaultIsolation(MainActor.self)]),
        .executableTarget(name: "JournalCrashFixture", dependencies: ["RelayJournal"], path: "Tests/JournalCrashFixture"),
        .testTarget(name: "RelayJournalTests", dependencies: ["RelayJournal"]),
        .target(name: "PolicyMetadataProcess", path: "Sources/PolicyMetadataProcess"),
        .executableTarget(name: "RelayStandardPolicyFixture", dependencies: ["PolicyMetadataProcess"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "RelayTests", dependencies: ["Relay", "RelayJournal", "PolicyMetadataProcess"])
    ]
)
