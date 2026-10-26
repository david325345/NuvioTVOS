// swift-tools-version:5.9
import PackageDescription

// The gesture logic of Gesture Lab: no UIKit, so its tests run with
// `swift test` on the macOS build host.
let package = Package(
    name: "GestureCore",
    platforms: [.tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GestureCore", targets: ["GestureCore"]),
    ],
    targets: [
        .target(name: "GestureCore"),
        .testTarget(name: "GestureCoreTests", dependencies: ["GestureCore"]),
    ]
)
