// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FoveaCapture",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fovea-capture", targets: ["FoveaCapture"])
    ],
    targets: [
        // The gesture state machine, split out for ONE reason: `Hotkey` needs a
        // CGEventTap and Accessibility permission, so nothing inside it can be
        // tested. This target has no dependencies at all, so it can.
        .target(name: "FoveaGesture", path: "Sources/FoveaGesture"),
        .testTarget(
            name: "FoveaGestureTests",
            dependencies: ["FoveaGesture"],
            path: "Tests/FoveaGestureTests"
        ),

        // No external dependencies on purpose: subcommand parsing is ~30 lines,
        // and a dependency-free build keeps `make dev` offline and fast.
        .executableTarget(
            name: "FoveaCapture",
            dependencies: ["FoveaGesture"],
            path: "Sources/FoveaCapture",
            exclude: ["Info.plist"],
            linkerSettings: [
                // A SwiftPM executable has no bundle, so TCC has nowhere to read
                // usage descriptions from — and requesting Speech Recognition
                // without one does not fail gracefully, it kills the process
                // with SIGABRT. Linking the plist in as a __TEXT,__info_plist
                // section gives TCC what it needs without an app bundle.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/FoveaCapture/Info.plist",
                ])
            ]
        )
    ]
)
