// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DeikoCapture",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "deiko-capture", targets: ["DeikoCapture"])
    ],
    targets: [
        // The gesture state machine, split out for ONE reason: `Hotkey` needs a
        // CGEventTap and Accessibility permission, so nothing inside it can be
        // tested. This target has no dependencies at all, so it can.
        .target(name: "DeikoGesture", path: "Sources/DeikoGesture"),
        .testTarget(
            name: "DeikoGestureTests",
            dependencies: ["DeikoGesture"],
            path: "Tests/DeikoGestureTests"
        ),

        // Split out for the same reason: `Audio` needs a microphone, so the
        // decision "is this buffer speech?" can only be tested if it lives
        // somewhere that has never heard of AVFoundation.
        .target(name: "DeikoVoice", path: "Sources/DeikoVoice"),
        .testTarget(
            name: "DeikoVoiceTests",
            dependencies: ["DeikoVoice"],
            path: "Tests/DeikoVoiceTests"
        ),

        // And again: "does this element name something, or is it furniture?" is
        // a judgement about strings, but every way of ASKING it needs a live
        // accessibility tree and a running app to point at.
        .target(name: "DeikoGrounding", path: "Sources/DeikoGrounding"),
        .testTarget(
            name: "DeikoGroundingTests",
            dependencies: ["DeikoGrounding"],
            path: "Tests/DeikoGroundingTests"
        ),

        // The fling — press the orb, drag onto a window, release — split out
        // because resolving what is under the cursor needs a window server.
        // Distance and target arrive as parameters; only decisions live here.
        .target(name: "DeikoHandoff", path: "Sources/DeikoHandoff"),
        .testTarget(
            name: "DeikoHandoffTests",
            dependencies: ["DeikoHandoff"],
            path: "Tests/DeikoHandoffTests"
        ),

        // No external dependencies on purpose: subcommand parsing is ~30 lines,
        // and a dependency-free build keeps `make dev` offline and fast.
        .executableTarget(
            name: "DeikoCapture",
            dependencies: ["DeikoGesture", "DeikoVoice", "DeikoGrounding", "DeikoHandoff"],
            path: "Sources/DeikoCapture",
            // Neither is a source file, and both live here because they are
            // inputs to `make bundle` rather than to SwiftPM. Listed so a
            // clean build does not warn about "unhandled files" at everybody
            // who builds from source.
            exclude: ["Info.plist", "Deiko.icns"],
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
                    "-Xlinker", "Sources/DeikoCapture/Info.plist",
                ])
            ]
        )
    ]
)
