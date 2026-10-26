import ProjectDescription

// Gesture Lab: a small tvOS app for trying Siri Remote gestures before they go
// into the Nuvio player. Fork only; built unsigned by
// .github/workflows/build-gesture-lab.yml.
let project = Project(
    name: "GestureLab",
    packages: [
        .local(path: "GestureCore"),
    ],
    settings: .settings(base: [
        "SWIFT_VERSION": "5.0",
        "MARKETING_VERSION": "0.1",
        "CURRENT_PROJECT_VERSION": "1",
    ]),
    targets: [
        .target(
            name: "GestureLab",
            destinations: [.appleTv],
            product: .app,
            bundleId: "com.david325345.gesturelab",
            deploymentTargets: .tvOS("18.0"),
            infoPlist: .file(path: "GestureLab/Info.plist"),
            sources: ["GestureLab/Sources/**/*.swift"],
            resources: ["GestureLab/Resources/AppIcon.png"],
            dependencies: [
                .package(product: "GestureCore"),
            ]
        ),
    ]
)
