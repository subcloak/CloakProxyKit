// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CloakProxyKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "CloakProxyKit", targets: ["CloakProxyKit"]),
    ],
    targets: [
        .target(name: "CloakProxyKit"),
        // A command-line app that makes a few requests with the SDK running, for trying it against Cloak Proxy.
        .executableTarget(name: "CloakProxyKitExample", dependencies: ["CloakProxyKit"]),
        .testTarget(name: "CloakProxyKitTests", dependencies: ["CloakProxyKit"]),
    ]
)
