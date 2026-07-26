// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FoveaCapture",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fovea-capture", targets: ["FoveaCapture"])
    ],
    targets: [
        // No external dependencies on purpose: subcommand parsing is ~30 lines,
        // and a dependency-free build keeps `make dev` offline and fast.
        .executableTarget(
            name: "FoveaCapture",
            path: "Sources/FoveaCapture"
        )
    ]
)
