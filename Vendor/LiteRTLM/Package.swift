// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "LiteRTLM",
    platforms: [.macOS(.v12)],
    products: [.library(name: "LiteRTLM", targets: ["LiteRTLM"])],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM_mac",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.1/CLiteRTLM_mac.xcframework.zip",
            checksum: "91b8c968fb61486c3eb6b0e7a6a1dfa32181efd4f2e5df14fb8bb5746dd8dd9f"
        ),
        .target(name: "LiteRTLM", dependencies: ["CLiteRTLM_mac"])
    ]
)
