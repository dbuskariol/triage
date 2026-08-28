// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Triage",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Triage", targets: ["Triage"])
    ],
    dependencies: [
        .package(path: "Vendor/GRDB.swift"),
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        )
    ],
    targets: [
        .executableTarget(
            name: "Triage",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Triage",
            exclude: [
                "Assets.xcassets",
                "Triage.entitlements",
                "TriageDebug.entitlements"
            ],
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "TriageTests",
            dependencies: ["Triage"],
            path: "TriageTests"
        )
    ]
)
