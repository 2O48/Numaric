// swift-tools-version: 6.8
import PackageDescription

let package = Package(
    name: "numaric",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "numaric", targets: ["numaric"])
    ],
    targets: [
        .executableTarget(
            name: "numaric"
        ),
        .testTarget(
            name: "numaricTests",
            dependencies: ["numaric"]
        ),
    ],
    swiftLanguageVersions: [.v6]
)
