// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TellyscopeCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "TellyscopeCore", targets: ["TellyscopeCore"])],
    targets: [
        .target(name: "TellyscopeCore"),
        .testTarget(name: "TellyscopeCoreTests", dependencies: ["TellyscopeCore"]),
    ]
)
