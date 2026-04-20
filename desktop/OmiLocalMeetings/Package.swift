// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OmiLocalMeetings",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OmiLocalMeetings", targets: ["OmiLocalMeetings"])
    ],
    dependencies: [
        .package(path: "../../../typewhisper-mac/Vendor/whisper.spm")
    ],
    targets: [
        .executableTarget(
            name: "OmiLocalMeetings",
            dependencies: [
                .product(name: "whisper", package: "whisper.spm")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "OmiLocalMeetingsTests",
            dependencies: ["OmiLocalMeetings"],
            path: "Tests"
        )
    ]
)
