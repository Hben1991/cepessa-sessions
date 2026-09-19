// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "whisper.spm",
  platforms: [
    .macOS(.v11)
  ],
  products: [
    .library(name: "whisper", targets: ["whisper"])
  ],
  targets: [
    .target(
      name: "whisperMetal",
      path: ".",
      exclude: ["Sources/whisper/ggml-metal.metal"],
      sources: ["Sources/whisper/ggml-metal.m"],
      publicHeadersPath: "Sources/whisper-metal-headers",
      cSettings: [
        .unsafeFlags(["-fno-objc-arc"]),
        .headerSearchPath("Sources/whisper/include"),
        .define("GGML_USE_METAL"),
      ],
      linkerSettings: [
        .linkedFramework("Foundation"),
        .linkedFramework("Metal"),
      ]
    ),
    .target(
      name: "whisper",
      dependencies: ["whisperMetal"],
      path: ".",
      exclude: [
        "Sources/whisper/ggml-metal.m",
        "Sources/whisper/ggml-metal.metal",
      ],
      sources: [
        "Sources/whisper/ggml.c",
        "Sources/whisper/ggml-alloc.c",
        "Sources/whisper/ggml-backend.c",
        "Sources/whisper/ggml-quants.c",
        "Sources/whisper/coreml/whisper-encoder-impl.m",
        "Sources/whisper/coreml/whisper-encoder.mm",
        "Sources/whisper/whisper.cpp",
      ],
      publicHeadersPath: "Sources/whisper/include",
      cSettings: [
        .unsafeFlags(["-Wno-shorten-64-to-32"]),
        .define("GGML_USE_ACCELERATE"),
        .define("GGML_USE_METAL"),
        .define("WHISPER_USE_COREML"),
        .define("WHISPER_COREML_ALLOW_FALLBACK"),
      ],
      linkerSettings: [
        .linkedFramework("Accelerate"),
        .linkedFramework("Foundation"),
        .linkedFramework("Metal"),
      ]
    ),
  ],
  cxxLanguageStandard: .cxx11
)
