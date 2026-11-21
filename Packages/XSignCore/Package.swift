// swift-tools-version: 5.9
import PackageDescription

/// Platform-independent logic for XSign: models, version comparison,
/// release sources (GitHub / homelab feeds), provisioning profile parsing
/// and install-manifest generation. Kept free of UIKit so it can be unit
/// tested with `swift test` on any machine.
let package = Package(
    name: "XSignCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "XSignCore", targets: ["XSignCore"])
    ],
    targets: [
        .target(name: "XSignCore"),
        .testTarget(name: "XSignCoreTests", dependencies: ["XSignCore"])
    ]
)
