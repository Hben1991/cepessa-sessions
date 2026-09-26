// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "CepessaSessions",
  platforms: [
    // Matches the Cepessa app, so the handoff library (and later the capture
    // core) can be embedded there without a second deployment floor.
    .macOS("26.0")
  ],
  products: [
    // The contract Cepessa consumes: read and verify finished-session
    // evidence from the shared outbox. Foundation and CryptoKit only.
    .library(name: "SessionsHandoff", targets: ["SessionsHandoff"])
  ],
  dependencies: [
    .package(path: "Vendor/whisper.spm"),
    .package(
      url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "0.18.0"),
  ],
  targets: [
    .target(
      name: "SessionsHandoff",
      path: "SessionsHandoff"
    ),
    .executableTarget(
      name: "CepessaSessions",
      dependencies: [
        "SessionsHandoff",
        .product(name: "whisper", package: "whisper.spm"),
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
        .product(name: "SpeakerKit", package: "argmax-oss-swift"),
      ],
      path: "Sources",
      resources: [
        .process("Resources")
      ],
      linkerSettings: [
        // SwiftUI's VideoPlayer resolves AVPlayerView dynamically at runtime.
        .linkedFramework("AVKit")
      ]
    ),
    .executableTarget(
      name: "CepessaMicrophoneCaptureHelper",
      path: "MicrophoneCaptureHelper"
    ),
    .testTarget(
      name: "CepessaSessionsTests",
      dependencies: [
        .target(name: "CepessaSessions"),
        "SessionsHandoff",
      ],
      path: "Tests"
    ),
  ]
)
