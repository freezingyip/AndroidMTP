// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AndroidMTP",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AndroidMTP", targets: ["AndroidMTP"])],
    targets: [
        .systemLibrary(name: "CLibMTP", pkgConfig: "libmtp", providers: [.brew(["libmtp"])]),
        .target(name: "CAndroidMTP", dependencies: ["CLibMTP"]),
        .target(name: "AndroidMTPCore", dependencies: ["CAndroidMTP"]),
        .executableTarget(name: "AndroidMTP", dependencies: ["AndroidMTPCore"]),
        .testTarget(name: "AndroidMTPCoreTests", dependencies: ["AndroidMTPCore"])
    ]
)
