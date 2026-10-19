// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CalendarCore",
    platforms: [.tvOS(.v17), .iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "CalendarCore", targets: ["CalendarCore"]),
    ],
    targets: [
        .target(name: "CalendarCore"),
        .testTarget(name: "CalendarCoreTests", dependencies: ["CalendarCore"]),
    ]
)
