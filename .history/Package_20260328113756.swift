import PackageDescription

let package = Package(
    name: "Numaric",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "Numaric", targets: ["Numaric"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Numaric",
            dependencies: [],
            path: "Sources"
        )
    ]
)
