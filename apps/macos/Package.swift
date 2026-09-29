// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DeikoCapture",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "deiko-capture", targets: ["DeikoCapture"])
    ],
    targets: [
        // Pure gesture logic, split out because `Hotkey` needs a CGEventTap and
        // Accessibility permission and cannot be tested.
        .target(name: "DeikoGesture", path: "Sources/DeikoGesture"),
        .testTarget(
            name: "DeikoGestureTests",
            dependencies: ["DeikoGesture"],
            path: "Tests/DeikoGestureTests"
        ),

        // Split out because `Audio` needs a microphone; the speech decision
        // must not depend on AVFoundation to be testable.
        .target(name: "DeikoVoice", path: "Sources/DeikoVoice"),
        .testTarget(
            name: "DeikoVoiceTests",
            dependencies: ["DeikoVoice"],
            path: "Tests/DeikoVoiceTests"
        ),

        // Split out because reading the accessibility tree needs a live app.
        .target(name: "DeikoGrounding", path: "Sources/DeikoGrounding"),
        .testTarget(
            name: "DeikoGroundingTests",
            dependencies: ["DeikoGrounding"],
            path: "Tests/DeikoGroundingTests"
        ),

        // The fling decisions. Resolving what is under the cursor needs a window
        // server, so distance and target arrive as parameters.
        .target(name: "DeikoHandoff", path: "Sources/DeikoHandoff"),
        .testTarget(
            name: "DeikoHandoffTests",
            dependencies: ["DeikoHandoff"],
            path: "Tests/DeikoHandoffTests"
        ),

        // No external dependencies, so the package builds offline.
        .executableTarget(
            name: "DeikoCapture",
            dependencies: ["DeikoGesture", "DeikoVoice", "DeikoGrounding", "DeikoHandoff"],
            path: "Sources/DeikoCapture",
            // Inputs to `make bundle`, not SwiftPM; excluded so a clean build
            // does not warn about unhandled files.
            exclude: ["Info.plist", "Deiko.icns", "Bricolage.ttf", "Bricolage-OFL.txt"],
            linkerSettings: [
                // A SwiftPM executable has no bundle for TCC to read usage
                // descriptions from, and requesting Speech Recognition without one
                // aborts the process. Linking the plist in as a
                // __TEXT,__info_plist section supplies them.
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
