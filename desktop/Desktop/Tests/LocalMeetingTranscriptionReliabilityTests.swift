import AVFoundation
import Foundation
import XCTest

@testable import CepessaSessions

final class LocalMeetingTranscriptionReliabilityTests: XCTestCase {
  private var tempRoot: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "LocalMeetingTranscriptionReliabilityTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot { try? fileManager.removeItem(at: tempRoot) }
  }

  func testAutomaticWhisperLanguageTranscribesAfterDetectingLanguage() {
    let automatic = LocalMeetingWhisperLanguageParameters(requestedLanguage: "auto")
    XCTAssertNil(automatic.languageCode)
    XCTAssertFalse(automatic.detectLanguageOnly)

    let empty = LocalMeetingWhisperLanguageParameters(requestedLanguage: "  ")
    XCTAssertNil(empty.languageCode)
    XCTAssertFalse(empty.detectLanguageOnly)

    let hebrew = LocalMeetingWhisperLanguageParameters(requestedLanguage: "Hebrew")
    XCTAssertEqual(hebrew.languageCode, "he")
    XCTAssertFalse(hebrew.detectLanguageOnly)
  }

  func testProgressDurationFormattingKeepsSubminuteSpeechAccurate() {
    XCTAssertEqual(LocalSessionTranscriptionDurationFormatter.string(from: 19.259), "19s")
    XCTAssertEqual(LocalSessionTranscriptionDurationFormatter.string(from: 0.2), "0s")
    XCTAssertEqual(LocalSessionTranscriptionDurationFormatter.string(from: 61), "1:01")
    XCTAssertEqual(LocalSessionTranscriptionDurationFormatter.string(from: 120), "2:00")
  }

  func testExistingAudioSkipsEmptyMixedFileAndSelectsValidMicrophoneFile() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let mixedURL = layout.mixedAudioURL(for: sessionID)
    let micURL = layout.micAudioURL(for: sessionID)
    try Data().write(to: mixedURL)
    try writeWave(to: micURL)

    let selected = layout.existingAudioURL(
      for: sessionID,
      artifacts: .init(
        micFileName: "mic.wav",
        micTranscriptFileName: nil,
        systemFileName: "system.wav",
        mixedFileName: "mixed.wav"
      ),
      fileManager: fileManager
    )

    XCTAssertEqual(selected, micURL)
  }

  func testExistingAudioPrefersExplicitImportedArtifactOverMixedFallback() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let sessionID = UUID()
    try layout.ensureDirectories(fileManager: fileManager, for: sessionID)
    let importedURL = layout.importedAudioURL(for: sessionID)
    try writeWave(to: importedURL)
    try writeWave(to: layout.mixedAudioURL(for: sessionID))

    let selected = layout.existingAudioURL(
      for: sessionID,
      artifacts: .init(
        micFileName: nil,
        systemFileName: nil,
        mixedFileName: "mixed.wav",
        importedFileName: "imported.wav"
      ),
      fileManager: fileManager
    )

    XCTAssertEqual(selected, importedURL)
  }

  func testResolvedHebrewModelReusesVerifiedTypeWhisperModel() throws {
    let applicationSupport = tempRoot.appendingPathComponent(
      "Application Support", isDirectory: true)
    let layout = LocalMeetingFileLayout(
      baseDirectory: applicationSupport.appendingPathComponent("Cepessa", isDirectory: true)
    )
    let modelURL =
      applicationSupport
      .appendingPathComponent(
        "TypeWhisper/PluginData/com.typewhisper.ivrit-asr/models", isDirectory: true
      )
      .appendingPathComponent(LocalMeetingFileLayout.defaultHebrewModelID, isDirectory: true)
      .appendingPathComponent("ggml-model.bin")
    try writeGGMLModel(to: modelURL)

    XCTAssertEqual(
      layout.resolvedHebrewModelURL(fileManager: fileManager),
      modelURL
    )
  }

  func testCustomRecordingRootCanUseIndependentTypeWhisperApplicationSupportRoot() throws {
    let customRecordingRoot = tempRoot.appendingPathComponent(
      "Custom Recordings", isDirectory: true)
    let typeWhisperRoot = tempRoot.appendingPathComponent(
      "User Application Support/TypeWhisper/PluginData/com.typewhisper.ivrit-asr/models",
      isDirectory: true
    )
    let layout = LocalMeetingFileLayout(
      baseDirectory: customRecordingRoot,
      compatibleModelSearchRoots: [typeWhisperRoot, typeWhisperRoot]
    )
    let modelURL =
      typeWhisperRoot
      .appendingPathComponent(LocalMeetingFileLayout.defaultHebrewModelID, isDirectory: true)
      .appendingPathComponent("ggml-model.bin")
    try writeGGMLModel(to: modelURL)

    XCTAssertEqual(layout.resolvedHebrewModelURL(fileManager: fileManager), modelURL)
  }

  func testCommonGGMLBasenameIsDiscoveredAndInvalidBinaryIsIgnored() throws {
    let layout = LocalMeetingFileLayout(baseDirectory: tempRoot)
    let modelDirectory = layout.modelsDirectory.appendingPathComponent(
      "ggml-large-v3-turbo",
      isDirectory: true
    )
    let modelURL = modelDirectory.appendingPathComponent("ggml-large-v3-turbo.bin")
    try writeGGMLModel(to: modelURL)

    let plan = layout.resolvedTranscriptionPlan(
      settings: .init(speedMode: .balanced, languagePreference: .mixed),
      fileManager: fileManager
    )
    XCTAssertEqual(plan.engine, .whisperCpp)
    XCTAssertEqual(plan.modelURL, modelURL)

    try Data("not a model".utf8).write(to: modelURL)
    let invalidPlan = layout.resolvedTranscriptionPlan(
      settings: .init(speedMode: .balanced, languagePreference: .mixed),
      fileManager: fileManager
    )
    XCTAssertNotEqual(invalidPlan.modelURL, modelURL)
  }

  func testWhisperKitValidationRequiresEveryNamedComponentToContainData() throws {
    let modelURL = tempRoot.appendingPathComponent("WhisperKit", isDirectory: true)
    let requiredComponents = [
      "AudioEncoder.mlmodelc",
      "TextDecoder.mlmodelc",
      "MelSpectrogram.mlmodelc",
    ]
    for component in requiredComponents {
      try fileManager.createDirectory(
        at: modelURL.appendingPathComponent(component, isDirectory: true),
        withIntermediateDirectories: true
      )
    }
    XCTAssertFalse(
      LocalSessionWhisperKitModelInspector.isWhisperKitModelDirectory(
        modelURL,
        fileManager: fileManager
      )
    )

    for component in requiredComponents {
      try Data([0x01]).write(
        to: modelURL.appendingPathComponent(component, isDirectory: true)
          .appendingPathComponent("model.espresso.net")
      )
    }
    XCTAssertTrue(
      LocalSessionWhisperKitModelInspector.isWhisperKitModelDirectory(
        modelURL,
        fileManager: fileManager
      )
    )
  }

  func testAudioImportReadFailureTerminatesProviderAndPreservesError() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    )
    let provider = LocalSessionAudioImportInputProvider(
      inputFormat: format,
      remainingFrames: { 4_096 },
      readFrames: { _, _ in throw TestReadError.failed }
    )
    var status = AVAudioConverterInputStatus.haveData
    let firstBuffer = withUnsafeMutablePointer(to: &status) {
      provider.provide(requestedPacketCount: 4_096, outStatus: $0)
    }

    XCTAssertNil(firstBuffer)
    XCTAssertEqual(status, .endOfStream)
    XCTAssertTrue(provider.reachedEndOfSource)
    XCTAssertNotNil(provider.failure)

    status = .haveData
    let secondBuffer = withUnsafeMutablePointer(to: &status) {
      provider.provide(requestedPacketCount: 4_096, outStatus: $0)
    }
    XCTAssertNil(secondBuffer)
    XCTAssertEqual(status, .endOfStream)
  }

  private func writeGGMLModel(to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data([0x6c, 0x6d, 0x67, 0x67, 0x01]).write(to: url)
  }

  private func writeWave(to url: URL) throws {
    let sampleData = Data(repeating: 0, count: 3_200)
    var data = Data()
    data.append("RIFF".data(using: .ascii)!)
    appendUInt32(UInt32(36 + sampleData.count), to: &data)
    data.append("WAVEfmt ".data(using: .ascii)!)
    appendUInt32(16, to: &data)
    appendUInt16(1, to: &data)
    appendUInt16(1, to: &data)
    appendUInt32(16_000, to: &data)
    appendUInt32(32_000, to: &data)
    appendUInt16(2, to: &data)
    appendUInt16(16, to: &data)
    data.append("data".data(using: .ascii)!)
    appendUInt32(UInt32(sampleData.count), to: &data)
    data.append(sampleData)
    try data.write(to: url)
  }

  private func appendUInt16(_ value: UInt16, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }

  private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }

  private enum TestReadError: Error {
    case failed
  }
}
