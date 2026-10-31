// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Relay",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Relay", targets: ["Relay"]), .executable(name: "RelayAccessibilityFixture", targets: ["RelayAccessibilityFixture"])],
    dependencies: [.package(path: "Vendor/LiteRTLM")],
    targets: [
        .executableTarget(name: "Relay", dependencies: [.product(name: "LiteRTLM", package: "LiteRTLM")], swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        .executableTarget(name: "RelayAccessibilityFixture", swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "RelayTests", dependencies: ["Relay"])
    ]
)
