// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "ReplayCenter",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/harflabs/SwiftVLC.git", exact: "0.10.0")
    ],
    targets: [
        .executableTarget(
            name: "ReplayCenter",
            dependencies: [
                .product(name: "SwiftVLC", package: "SwiftVLC")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
