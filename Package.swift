// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "ReplayCenter",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ReplayCenter", targets: ["ReplayCenter"]),
        .executable(name: "ReplayCenterStreamFilter", targets: ["ReplayCenterStreamFilter"])
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
        ),
        .executableTarget(
            name: "ReplayCenterStreamFilter",
            path: "Sources/ReplayCenterStreamFilter",
            sources: [
                "filter.cpp",
                "third_party/tsreadex/aac.cpp",
                "third_party/tsreadex/huffman.cpp",
                "third_party/tsreadex/util.cpp"
            ],
            cxxSettings: [
                .unsafeFlags(["-std=c++17", "-DNDEBUG"])
            ]
        )
    ]
)
