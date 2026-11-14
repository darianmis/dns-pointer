// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DNSRedirectCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DNSRedirectCore", targets: ["DNSRedirectCore"]),
    ],
    targets: [
        .target(name: "DNSRedirectCore"),
        .testTarget(name: "DNSRedirectCoreTests", dependencies: ["DNSRedirectCore"]),
    ]
)
