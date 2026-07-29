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

        // Split out for the same reason: `Audio` needs a microphone, so the
        // decision "is this buffer speech?" can only be tested if it lives
        // somewhere that has never heard of AVFoundation.
        .target(name: "FoveaVoice", path: "Sources/FoveaVoice"),
        .testTarget(
            name: "FoveaVoiceTests",
            dependencies: ["FoveaVoice"],
            path: "Tests/FoveaVoiceTests"
        ),

        // And again: "does this element name something, or is it furniture?" is
        // a judgement about strings, but every way of ASKING it needs a live
        // accessibility tree and a running app to point at.
        .target(name: "FoveaGrounding", path: "Sources/FoveaGrounding"),
        .testTarget(
            name: "FoveaGroundingTests",
            dependencies: ["FoveaGrounding"],
            path: "Tests/FoveaGroundingTests"
        ),

        // No external dependencies on purpose: subcommand parsing is ~30 lines,
        // and a dependency-free build keeps `make dev` offline and fast.
        .executableTarget(
            name: "FoveaCapture",
            dependencies: ["FoveaGesture", "FoveaVoice", "FoveaGrounding"],
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
