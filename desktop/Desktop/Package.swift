// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "CepessaSessions",
  platforms: [
    .macOS("14.0")
  ],
  dependencies: [
    .package(path: "Vendor/whisper.spm"),
    .package(
      url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "0.18.0"),
    .package(url: "https://github.com/mattt/llama.swift", exact: "2.10549.0"),
  ],
  targets: [
    .executableTarget(
      name: "CepessaSessions",
      dependencies: [
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
      name: "CepessaLocalModelRunner",
      dependencies: [
        .product(name: "LlamaSwift", package: "llama.swift")
      ],
      path: "LocalModelRunner"
    ),
    .executableTarget(
      name: "CepessaMicrophoneCaptureHelper",
      path: "MicrophoneCaptureHelper"
    ),
    .testTarget(
      name: "CepessaSessionsTests",
      dependencies: [
        .target(name: "CepessaSessions")
      ],
      path: "Tests"
    ),
  ]
)
