// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "CepessaSessions",
  platforms: [
    .macOS("14.0")
  ],
  dependencies: [
    .package(path: "../../../typewhisper-mac/Vendor/whisper.spm"),
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", .upToNextMajor(from: "0.18.0")),
    .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.8943.0")),
  ],
  targets: [
    .executableTarget(
      name: "CepessaSessions",
      dependencies: [
        .product(name: "whisper", package: "whisper.spm"),
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
      ],
      path: "Sources",
      resources: [
        .process("Resources"),
      ]
    ),
    .executableTarget(
      name: "CepessaLocalModelRunner",
      dependencies: [
        .product(name: "LlamaSwift", package: "llama.swift"),
      ],
      path: "LocalModelRunner"
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
