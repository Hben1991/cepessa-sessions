import XCTest

@testable import CepessaSessions

final class LocalMeetingTranscriptionPreprocessingTests: XCTestCase {
  func testSpeechRegionDetectorSkipsLongSilentGap() {
    let detector = LocalMeetingSpeechRegionDetector()
    let samples =
      silence(duration: 1.0)
      + speech(duration: 1.0)
      + silence(duration: 2.4)
      + speech(duration: 1.2)

    let regions = detector.regions(in: samples)

    XCTAssertEqual(regions.count, 2)
    XCTAssertLessThan(abs(seconds(for: regions[0].startSample) - 0.84), 0.2)
    XCTAssertLessThan(abs(seconds(for: regions[0].endSample) - 2.24), 0.25)
    XCTAssertLessThan(abs(seconds(for: regions[1].startSample) - 4.24), 0.25)
    XCTAssertLessThan(abs(seconds(for: regions[1].endSample) - 5.84), 0.25)
  }

  func testSpeechRegionDetectorMergesShortPauseIntoSingleRegion() {
    let detector = LocalMeetingSpeechRegionDetector()
    let samples =
      silence(duration: 0.5)
      + speech(duration: 1.0)
      + silence(duration: 0.18)
      + speech(duration: 1.0)

    let regions = detector.regions(in: samples)

    XCTAssertEqual(regions.count, 1)
    XCTAssertLessThan(abs(seconds(for: regions[0].startSample) - 0.34), 0.2)
    XCTAssertLessThan(abs(seconds(for: regions[0].endSample) - 2.92), 0.25)
  }

  func testSpeechRegionDetectorReturnsNoRegionsForSilence() {
    let detector = LocalMeetingSpeechRegionDetector()
    let samples = Array(
      repeating: Float.zero, count: LocalMeetingSpeechRegionDetector.sampleRate * 3)

    XCTAssertTrue(detector.regions(in: samples).isEmpty)
  }

  func testSpeechChunkerReturnsNoChunksWhenNoSpeechRegionsWereDetected() {
    let samples = Array(
      repeating: Float.zero, count: LocalMeetingSpeechRegionDetector.sampleRate * 3)

    let chunks = LocalMeetingSpeechChunker().chunks(from: [], samples: samples)

    XCTAssertTrue(chunks.isEmpty)
  }

  func testTranscriptionPostprocessorRemovesTrailingRepeatedThankYouHallucinations() {
    let segments = [
      LocalSessionTranscriptionSegment(startTime: 0, endTime: 2, text: "Actual transcript"),
      LocalSessionTranscriptionSegment(startTime: 2, endTime: 3, text: "תודה רבה"),
      LocalSessionTranscriptionSegment(startTime: 3, endTime: 4, text: "תודה רבה"),
      LocalSessionTranscriptionSegment(startTime: 4, endTime: 5, text: "תודה רבה"),
    ]

    let cleaned = LocalSessionTranscriptionPostprocessor.cleanSegments(segments)

    XCTAssertEqual(cleaned.map(\.text), ["Actual transcript"])
  }

  func testTranscriptionPostprocessorKeepsSingleRealCourtesySegment() {
    let segments = [
      LocalSessionTranscriptionSegment(startTime: 0, endTime: 2, text: "Actual transcript"),
      LocalSessionTranscriptionSegment(startTime: 2, endTime: 3, text: "תודה רבה"),
    ]

    let cleaned = LocalSessionTranscriptionPostprocessor.cleanSegments(segments)

    XCTAssertEqual(cleaned.map(\.text), ["Actual transcript", "תודה רבה"])
  }

  func testNormalizedSamplesForRecognitionAmplifiesQuietAudio() {
    let samples: [Float] = [0.06, -0.03, 0.0, 0.015]

    let normalized = LocalSessionWhisperCppTranscriptionService.normalizedSamplesForRecognition(
      samples)

    XCTAssertEqual(normalized.count, samples.count)
    XCTAssertLessThan(abs(normalized[0] - 0.22), 0.001)
    XCTAssertLessThan(abs(normalized[1] + 0.11), 0.001)
    XCTAssertEqual(normalized[2], 0)
    XCTAssertLessThan(abs(normalized[3] - 0.055), 0.001)
  }

  func testTranscriptMixerRaisesQuietSystemSpeechAboveDetectorThreshold() {
    let frameCount = LocalMeetingSpeechRegionDetector.sampleRate
    let quietSystemSamples = Array(repeating: Int16(150), count: frameCount)
    let quietSystemData = quietSystemSamples.withUnsafeBufferPointer { Data(buffer: $0) }
    let silentMicData = Data(repeating: 0, count: frameCount * MemoryLayout<Int16>.size)

    let mixedData = LocalMeetingAudioMixer.mixMono(
      micPCM16: silentMicData,
      systemPCM16: quietSystemData
    )
    let mixedSamples = mixedData.withUnsafeBytes { rawBuffer in
      rawBuffer.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_767 }
    }

    XCTAssertFalse(LocalMeetingSpeechRegionDetector().regions(in: mixedSamples).isEmpty)
  }

  func testTranscriptMixerDoesNotAmplifyDigitalSilence() {
    XCTAssertEqual(LocalMeetingAudioMixer.systemGain(for: Array(repeating: 0, count: 320)), 1)
  }

  func testTranscriptMixerPreservesNormalTwoSidedPCM() {
    let mic = pcm16Data([1_000, -1_000, 30_000])
    let system = pcm16Data([2_000, -2_000, 10_000])

    let mixed = pcm16Samples(
      LocalMeetingAudioMixer.mixMono(micPCM16: mic, systemPCM16: system))

    XCTAssertEqual(mixed, [3_000, -3_000, Int16.max])
  }

  func testSynchronizedPCMBufferPairsNormalAlternatingSourcesWithoutRetainingAudio() {
    var buffer = LocalMeetingSynchronizedPCMBuffer(maximumSkewByteCount: 16)
    var output: [Data] = []

    buffer.appendMic(pcm16Data([1_000, -1_000])) { output.append($0) }
    buffer.appendSystem(pcm16Data([2_000, -2_000])) { output.append($0) }

    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(pcm16Samples(output[0]), [3_000, -3_000])
    XCTAssertEqual(buffer.bufferedByteCount, 0)
  }

  func testSynchronizedPCMBufferWaitsForDelayedSourceInsideSkewWindow() {
    var buffer = LocalMeetingSynchronizedPCMBuffer(maximumSkewByteCount: 8)
    var output: [Data] = []
    let mic = pcm16Data([1_000, 2_000, 3_000, 4_000])
    let system = pcm16Data([2_000, 2_000, 2_000, 2_000])

    buffer.appendMic(mic) { output.append($0) }
    XCTAssertTrue(output.isEmpty)
    XCTAssertEqual(buffer.bufferedByteCount, 8)

    buffer.appendSystem(system) { output.append($0) }

    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(pcm16Samples(output[0]), [3_000, 4_000, 5_000, 6_000])
    XCTAssertEqual(buffer.bufferedByteCount, 0)
  }

  func testSynchronizedPCMBufferBoundsOneHourOfMicOnlyAudio() {
    var buffer = LocalMeetingSynchronizedPCMBuffer()
    let oneSecond = Data(
      repeating: 0,
      count: LocalMeetingSynchronizedPCMBuffer.bytesPerSecond
    )
    var emittedByteCount = 0

    for _ in 0..<3_600 {
      buffer.appendMic(oneSecond) { emittedByteCount += $0.count }
    }

    XCTAssertEqual(
      buffer.pendingMicPCM.count,
      LocalMeetingSynchronizedPCMBuffer.defaultMaximumSkewByteCount
    )
    XCTAssertTrue(buffer.pendingSystemPCM.isEmpty)
    XCTAssertEqual(
      emittedByteCount + buffer.bufferedByteCount,
      oneSecond.count * 3_600
    )
  }

  func testSynchronizedPCMBufferBoundsOneHourOfSystemOnlyAudio() {
    var buffer = LocalMeetingSynchronizedPCMBuffer()
    let oneSecond = pcm16Data(Array(repeating: 2_000, count: 16_000))
    var emittedByteCount = 0

    for _ in 0..<3_600 {
      buffer.appendSystem(oneSecond) { emittedByteCount += $0.count }
    }

    XCTAssertEqual(
      buffer.pendingSystemPCM.count,
      LocalMeetingSynchronizedPCMBuffer.defaultMaximumSkewByteCount
    )
    XCTAssertTrue(buffer.pendingMicPCM.isEmpty)
    XCTAssertEqual(
      emittedByteCount + buffer.bufferedByteCount,
      oneSecond.count * 3_600
    )
  }

  func testMetalResourceLocatorPrefersDirectoryContainingRequiredShaderFiles() throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let nestedBundleDirectory =
      rootDirectory
      .appendingPathComponent("CepessaSessions_CepessaSessions.bundle", isDirectory: true)
    try FileManager.default.createDirectory(
      at: nestedBundleDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    try Data().write(to: nestedBundleDirectory.appendingPathComponent("ggml-metal.metal"))
    try Data().write(to: nestedBundleDirectory.appendingPathComponent("ggml-common.h"))

    let resolved = LocalMeetingMetalResourceLocator.resolveResourcePath(
      existingValue: nil,
      candidateDirectories: [rootDirectory, nestedBundleDirectory]
    )

    XCTAssertEqual(resolved, nestedBundleDirectory.path)
  }

  func testMetalResourceLocatorSearchesPackagedResourceBundle() throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appDirectory = rootDirectory.appendingPathComponent("Sessions.app", isDirectory: true)
    let contentsDirectory = appDirectory.appendingPathComponent("Contents", isDirectory: true)
    let resourcesDirectory = contentsDirectory.appendingPathComponent(
      "Resources", isDirectory: true)
    let nestedBundleDirectory =
      resourcesDirectory
      .appendingPathComponent("CepessaSessions_CepessaSessions.bundle", isDirectory: true)
    try FileManager.default.createDirectory(
      at: nestedBundleDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key>
      <string>Sessions</string>
      <key>CFBundleIdentifier</key>
      <string>me.cepessa.sessions.test</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
    </dict>
    </plist>
    """.write(
      to: contentsDirectory.appendingPathComponent("Info.plist"),
      atomically: true,
      encoding: .utf8)
    try Data().write(to: nestedBundleDirectory.appendingPathComponent("ggml-metal.metal"))
    try Data().write(to: nestedBundleDirectory.appendingPathComponent("ggml-common.h"))

    let bundle = try XCTUnwrap(Bundle(url: appDirectory))
    let resolved = LocalMeetingMetalResourceLocator.resolveResourcePath(
      existingValue: nil,
      candidateDirectories: LocalMeetingMetalResourceLocator.candidateDirectories(
        mainBundle: bundle)
    )

    XCTAssertEqual(resolved, nestedBundleDirectory.path)
  }

  func testMetalResourceLocatorIgnoresInvalidExistingEnvironmentValue() throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    try Data().write(to: rootDirectory.appendingPathComponent("ggml-metal.metal"))
    try Data().write(to: rootDirectory.appendingPathComponent("ggml-common.h"))

    let resolved = LocalMeetingMetalResourceLocator.resolveResourcePath(
      existingValue: "/Applications/Xcode.app/Contents/Developer/usr/bin",
      candidateDirectories: [rootDirectory]
    )

    XCTAssertEqual(resolved, rootDirectory.path)
  }

  func testMetalResourceLocatorInlinesCommonHeaderForRuntimeMetalCompiler() throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = rootDirectory.appendingPathComponent("source", isDirectory: true)
    let writableDirectory = rootDirectory.appendingPathComponent("prepared", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    try """
    #define GGML_COMMON_DECL_METAL
    #include "ggml-common.h"
    kernel void noop() {}
    """.write(
      to: sourceDirectory.appendingPathComponent("ggml-metal.metal"),
      atomically: true,
      encoding: .utf8)
    try "// fused common header\n".write(
      to: sourceDirectory.appendingPathComponent("ggml-common.h"),
      atomically: true,
      encoding: .utf8)

    let resolved = LocalMeetingMetalResourceLocator.preparedResourcePath(
      existingValue: nil,
      candidateDirectories: [sourceDirectory],
      writableDirectory: writableDirectory
    )

    let preparedDirectory = try XCTUnwrap(resolved).asFileURL
    XCTAssertNotEqual(preparedDirectory.path, sourceDirectory.path)
    let preparedSource = try String(
      contentsOf: preparedDirectory.appendingPathComponent("ggml-metal.metal"),
      encoding: .utf8)
    XCTAssertFalse(preparedSource.contains(#"#include "ggml-common.h""#))
    XCTAssertTrue(preparedSource.contains("// fused common header"))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: preparedDirectory.appendingPathComponent("ggml-common.h").path))

    let resolvedAgain = LocalMeetingMetalResourceLocator.preparedResourcePath(
      existingValue: preparedDirectory.path,
      candidateDirectories: [],
      writableDirectory: writableDirectory
    )

    XCTAssertEqual(resolvedAgain, preparedDirectory.path)
  }

  func testSpeechChunkerMergesNearbyShortRegions() {
    let samples = speech(duration: 20)
    let regions = [
      LocalMeetingSpeechRegion(startSample: sampleOffset(0), endSample: sampleOffset(3)),
      LocalMeetingSpeechRegion(startSample: sampleOffset(7), endSample: sampleOffset(10)),
      LocalMeetingSpeechRegion(startSample: sampleOffset(13), endSample: sampleOffset(16)),
    ]

    let chunks = LocalMeetingSpeechChunker().chunks(from: regions, samples: samples)

    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks[0].startSample, sampleOffset(0))
    XCTAssertEqual(chunks[0].endSample, sampleOffset(16))
    XCTAssertEqual(chunks[0].speechSampleCount, sampleOffset(9))
  }

  func testSpeechChunkerSplitsLongDistantRegions() {
    let samples = speech(duration: 100)
    let regions = [
      LocalMeetingSpeechRegion(startSample: sampleOffset(0), endSample: sampleOffset(30)),
      LocalMeetingSpeechRegion(startSample: sampleOffset(50), endSample: sampleOffset(80)),
    ]

    let chunks = LocalMeetingSpeechChunker().chunks(from: regions, samples: samples)

    XCTAssertEqual(chunks.count, 2)
    XCTAssertEqual(chunks[0].endSample, sampleOffset(30))
    XCTAssertEqual(chunks[1].startSample, sampleOffset(50))
  }

  private func silence(duration: Double) -> [Float] {
    Array(repeating: 0, count: Int(duration * Double(LocalMeetingSpeechRegionDetector.sampleRate)))
  }

  private func speech(duration: Double) -> [Float] {
    let sampleCount = Int(duration * Double(LocalMeetingSpeechRegionDetector.sampleRate))
    return (0..<sampleCount).map { index in
      let value = sin(Double(index) * 0.045) * 0.12
      return Float(value)
    }
  }

  private func seconds(for sampleOffset: Int) -> Double {
    Double(sampleOffset) / Double(LocalMeetingSpeechRegionDetector.sampleRate)
  }

  private func pcm16Data(_ samples: [Int16]) -> Data {
    samples.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  private func pcm16Samples(_ data: Data) -> [Int16] {
    data.withUnsafeBytes { rawBuffer in
      rawBuffer.bindMemory(to: Int16.self).map(Int16.init(littleEndian:))
    }
  }

  private func sampleOffset(_ seconds: Double) -> Int {
    Int(seconds * Double(LocalMeetingSpeechRegionDetector.sampleRate))
  }
}

extension String {
  fileprivate var asFileURL: URL {
    URL(fileURLWithPath: self, isDirectory: true)
  }
}
