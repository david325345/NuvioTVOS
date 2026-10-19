import ProjectDescription

// Standalone test app for the upcoming-episodes calendar. Not part of
// NuvioTV: it exists only to try the calendar core on a real Apple TV
// without building the whole app.

let project = Project(
    name: "KalendarTest",
    packages: [
        .local(path: "../CalendarCore"),
    ],
    settings: .settings(base: [
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "3",
        "MARKETING_VERSION": "0.1.0",
        "CURRENT_PROJECT_VERSION": "1",
    ]),
    targets: [
        .target(
            name: "KalendarTest",
            destinations: [.appleTv],
            product: .app,
            bundleId: "cz.david325345.kalendartest",
            deploymentTargets: .tvOS("17.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Kalendář test",
            ]),
            sources: ["Sources/**/*.swift"],
            dependencies: [
                .package(product: "CalendarCore"),
            ]
        ),
    ]
)
