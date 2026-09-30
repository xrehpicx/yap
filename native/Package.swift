// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "yap-helper",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4")
    ],
    targets: [
        .executableTarget(
            name: "yap-helper",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "yap-helper-tests",
            dependencies: ["yap-helper"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
