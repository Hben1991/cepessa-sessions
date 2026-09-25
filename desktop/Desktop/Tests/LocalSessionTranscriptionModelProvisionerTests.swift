import Combine
import CryptoKit
import Foundation
import XCTest

@testable import CepessaSessions

@MainActor
final class LocalSessionTranscriptionModelProvisionerTests: XCTestCase {
  private var root: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    root = fileManager.temporaryDirectory.appendingPathComponent(
      "TranscriptionModelProvisionerTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root {
      try? fileManager.removeItem(at: root)
    }
  }

  func testContractPinsRevisionSizeAndChecksum() {
    XCTAssertEqual(
      LocalSessionTranscriptionModelContract.repository, "ivrit-ai/whisper-large-v3-turbo-ggml")
    XCTAssertEqual(
      LocalSessionTranscriptionModelContract.revision,
      "2130c78e4a9cb4914cc4df91a1c3031407789705"
    )
    XCTAssertEqual(LocalSessionTranscriptionModelContract.pinnedFile.size, 1_624_555_275)
    XCTAssertEqual(
      LocalSessionTranscriptionModelContract.pinnedFile.sha256,
      "c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1"
    )
    XCTAssertEqual(
      LocalSessionTranscriptionModelContract.downloadURL.absoluteString,
      "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/2130c78e4a9cb4914cc4df91a1c3031407789705/ggml-model.bin"
    )
    XCTAssertEqual(
      LocalSessionTranscriptionModelContract.modelID,
      LocalSessionFileLayout.defaultHebrewModelID
    )
  }

  func testMissingModelStartsNotInstalledWithoutDownloading() async {
    let downloader = TranscriptionModelDownloaderStub(outcomes: [])
    let provisioner = makeProvisioner(downloader: downloader)

    XCTAssertEqual(provisioner.state, .notInstalled)
    XCTAssertNil(provisioner.activeModel)
    XCTAssertFalse(provisioner.isHebrewModelInstalled)
    XCTAssertFalse(provisioner.isUsable(plan()))
    XCTAssertTrue(provisioner.unavailableModelMessage.contains("Settings"))
    let calls = await downloader.callCount()
    XCTAssertEqual(calls, 0)
  }

  func testDownloadReportsProgressVerifiesAndActivatesWithManifest() async throws {
    let downloader = TranscriptionModelDownloaderStub(outcomes: [.valid])
    let provisioner = makeProvisioner(downloader: downloader)
    var states: [LocalSessionTranscriptionModelProvisioningState] = []
    let subscription = provisioner.$state.sink { states.append($0) }
    defer { subscription.cancel() }

    provisioner.prepareIfNeeded()
    await waitUntilIdle(provisioner)

    XCTAssertEqual(provisioner.state, .ready)
    XCTAssertTrue(provisioner.isHebrewModelInstalled)
    XCTAssertEqual(provisioner.activeModel?.kind, .pinnedHebrew)
    XCTAssertTrue(provisioner.isUsable(plan()))
    XCTAssertTrue(states.contains(.downloading(progress: 0.25)))
    XCTAssertTrue(states.contains(.verifying))
    XCTAssertEqual(try Data(contentsOf: provisioner.modelURL), TranscriptionModelFixture.validData)
    XCTAssertTrue(fileManager.fileExists(atPath: provisioner.manifestURL.path))
    XCTAssertEqual(try stagingDirectories(), [])
    let calls = await downloader.callCount()
    XCTAssertEqual(calls, 1)
  }

  func testChecksumMismatchFailsAndLeavesExistingModelUntouched() async throws {
    let layout = makeLayout()
    let modelURL = layout.modelURL()
    let oldBytes = Data([0x6c, 0x6d, 0x67, 0x67]) + Data("previous partial model".utf8)
    try fileManager.createDirectory(
      at: modelURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try oldBytes.write(to: modelURL)
    let downloader = TranscriptionModelDownloaderStub(outcomes: [.corrupt])
    let provisioner = makeProvisioner(downloader: downloader)
    guard case .failed = provisioner.state else {
      return XCTFail("An incomplete model on disk must not be ready, got \(provisioner.state)")
    }

    provisioner.prepareIfNeeded()
    await waitUntilIdle(provisioner)

    guard case .failed(let message) = provisioner.state else {
      return XCTFail("A checksum mismatch must fail, got \(provisioner.state)")
    }
    XCTAssertTrue(message.contains("SHA-256"), message)
    XCTAssertEqual(try Data(contentsOf: modelURL), oldBytes)
    XCTAssertFalse(fileManager.fileExists(atPath: provisioner.manifestURL.path))
    XCTAssertFalse(provisioner.isHebrewModelInstalled)
    XCTAssertEqual(try stagingDirectories(), [])
  }

  func testFailedDownloadRemovesStagingAndRetryReachesReady() async throws {
    let downloader = TranscriptionModelDownloaderStub(outcomes: [.failure, .valid])
    let provisioner = makeProvisioner(downloader: downloader)

    provisioner.prepareIfNeeded()
    await waitUntilIdle(provisioner)
    guard case .failed = provisioner.state else {
      return XCTFail("First attempt should fail, got \(provisioner.state)")
    }
    XCTAssertEqual(try stagingDirectories(), [])
    XCTAssertTrue(provisioner.unavailableModelMessage.contains("Retry"))

    provisioner.retry()
    await waitUntilIdle(provisioner)

    XCTAssertEqual(provisioner.state, .ready)
    let calls = await downloader.callCount()
    XCTAssertEqual(calls, 2)
  }

  func testInterruptedStagingIsRemovedAtLaunch() throws {
    let layout = makeLayout()
    let interrupted = layout.modelsDirectory.appendingPathComponent(
      "\(LocalSessionTranscriptionModelContract.stagingDirectoryPrefix)interrupted",
      isDirectory: true
    )
    let unrelated = layout.modelsDirectory.appendingPathComponent(
      ".speakerkit-staging-other",
      isDirectory: true
    )
    try fileManager.createDirectory(at: interrupted, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: unrelated, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: interrupted.appendingPathComponent("ggml-model.bin"))

    _ = makeProvisioner(downloader: TranscriptionModelDownloaderStub(outcomes: []))

    XCTAssertFalse(fileManager.fileExists(atPath: interrupted.path))
    XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path))
  }

  func testRepeatedRequestsDuringDownloadStartOnlyOneDownload() async throws {
    let downloader = TranscriptionModelDownloaderStub(outcomes: [.valid], holds: true)
    let provisioner = makeProvisioner(downloader: downloader)

    provisioner.prepareIfNeeded()
    await eventually { await downloader.isHolding() }
    provisioner.prepareIfNeeded()
    provisioner.installHebrewModel()
    provisioner.retry()
    provisioner.refreshState()
    XCTAssertEqual(provisioner.state, .downloading(progress: 0.25))
    XCTAssertEqual(try stagingDirectories().count, 1, "refreshState must keep live staging")

    await downloader.release()
    await waitUntilIdle(provisioner)

    XCTAssertEqual(provisioner.state, .ready)
    let calls = await downloader.callCount()
    XCTAssertEqual(calls, 1)
  }

  func testExistingInstallIsVerifiedOnceThenTrustedFromManifest() async throws {
    let layout = makeLayout()
    try TranscriptionModelFixture.writeValid(to: layout.modelURL())
    let downloader = TranscriptionModelDownloaderStub(outcomes: [])

    let firstLaunch = makeProvisioner(downloader: downloader)
    XCTAssertEqual(firstLaunch.state, .verifying)
    firstLaunch.prepareIfNeeded()
    await waitUntilIdle(firstLaunch)

    XCTAssertEqual(firstLaunch.state, .ready)
    XCTAssertTrue(firstLaunch.isHebrewModelInstalled)
    XCTAssertTrue(fileManager.fileExists(atPath: firstLaunch.manifestURL.path))
    let manifestBefore = try Data(contentsOf: firstLaunch.manifestURL)

    // A relaunch trusts manifest + size + modification time: ready at once, no hashing.
    let relaunch = makeProvisioner(downloader: downloader)
    XCTAssertEqual(relaunch.state, .ready)
    XCTAssertFalse(relaunch.isWorking)
    relaunch.prepareIfNeeded()
    relaunch.installHebrewModel()
    XCTAssertFalse(relaunch.isWorking)
    XCTAssertEqual(try Data(contentsOf: relaunch.manifestURL), manifestBefore)

    // A changed modification time is no longer vouched for, so it is verified again.
    try fileManager.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
      ofItemAtPath: layout.modelURL().path
    )
    let afterTouch = makeProvisioner(downloader: downloader)
    XCTAssertEqual(afterTouch.state, .verifying)
    await waitUntilIdle(afterTouch)
    XCTAssertEqual(afterTouch.state, .ready)

    let calls = await downloader.callCount()
    XCTAssertEqual(calls, 0)
  }

  func testTamperedInstallFailsVerificationAndIsReplacedOnlyWhenInstallIsRequested() async throws {
    let layout = makeLayout()
    try TranscriptionModelFixture.writeValid(to: layout.modelURL())
    let downloader = TranscriptionModelDownloaderStub(outcomes: [.valid])
    let trusted = makeProvisioner(downloader: downloader)
    await waitUntilIdle(trusted)
    XCTAssertEqual(trusted.state, .ready)

    try TranscriptionModelFixture.corruptData.write(to: layout.modelURL())
    try fileManager.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
      ofItemAtPath: layout.modelURL().path
    )
    let relaunch = makeProvisioner(downloader: downloader)
    await waitUntilIdle(relaunch)

    guard case .failed(let message) = relaunch.state else {
      return XCTFail("Tampered bytes must fail verification, got \(relaunch.state)")
    }
    XCTAssertTrue(message.contains("verification"), message)
    XCTAssertFalse(relaunch.isHebrewModelInstalled)
    var calls = await downloader.callCount()
    XCTAssertEqual(calls, 0, "Verification alone never downloads")

    relaunch.prepareIfNeeded()
    await waitUntilIdle(relaunch)

    XCTAssertEqual(relaunch.state, .ready)
    XCTAssertEqual(try Data(contentsOf: layout.modelURL()), TranscriptionModelFixture.validData)
    calls = await downloader.callCount()
    XCTAssertEqual(calls, 1)
  }

  func testAnotherUsableModelMeansNoAutomaticDownload() async throws {
    let layout = makeLayout()
    let multilingualURL = layout.modelURL(for: "ggml-small")
    let multilingualBytes = Data([0x6c, 0x6d, 0x67, 0x67, 0x01])
    try fileManager.createDirectory(
      at: multilingualURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try multilingualBytes.write(to: multilingualURL)
    let downloader = TranscriptionModelDownloaderStub(outcomes: [.valid])

    let provisioner = makeProvisioner(downloader: downloader)
    XCTAssertEqual(provisioner.state, .ready)
    XCTAssertEqual(provisioner.activeModel?.kind, .other)
    XCTAssertEqual(provisioner.activeModel?.url, multilingualURL)
    XCTAssertTrue(provisioner.activeModel?.displayName.contains("ggml-small") == true)
    XCTAssertFalse(provisioner.isHebrewModelInstalled)
    XCTAssertTrue(provisioner.isUsable(plan()))

    provisioner.prepareIfNeeded()
    XCTAssertFalse(provisioner.isWorking)
    try? await Task.sleep(nanoseconds: 20_000_000)
    var calls = await downloader.callCount()
    XCTAssertEqual(calls, 0)

    // The owner can still install the Hebrew model by hand from Settings.
    provisioner.installHebrewModel()
    await waitUntilIdle(provisioner)
    XCTAssertEqual(provisioner.state, .ready)
    XCTAssertTrue(provisioner.isHebrewModelInstalled)
    XCTAssertEqual(try Data(contentsOf: multilingualURL), multilingualBytes)
    calls = await downloader.callCount()
    XCTAssertEqual(calls, 1)
  }

  func testTranscriptionWithoutModelStartsOneInstallAndExplainsTheFailure() async throws {
    let layout = makeLayout()
    let store = LocalSessionStore(fileLayout: layout)
    let session = LocalSession(
      id: UUID(),
      title: "Needs a model",
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      status: .failed,
      transcriptSegments: [],
      audioArtifacts: .init(
        micFileName: nil, systemFileName: nil, mixedFileName: "mixed.wav")
    )
    try store.save(session)
    let writer = try LocalMeetingWaveFileWriter(
      fileURL: layout.sessionDirectory(for: session.id).appendingPathComponent("mixed.wav"))
    try writer.append(samples: [Int16](repeating: 1_000, count: 16_000))
    try writer.close()

    let downloader = TranscriptionModelDownloaderStub(outcomes: [.valid], holds: true)
    let provisioner = makeProvisioner(downloader: downloader)
    let model = LocalMeetingAppModel(
      store: store,
      fileLayout: layout,
      transcriptionService: MissingModelTranscriber(),
      transcriptionModelProvisioner: provisioner,
      installsTranscriptionModelOnDemand: true
    )

    model.retranscribeSession(id: session.id)
    await eventually { await downloader.isHolding() }
    await eventually { !model.isTranscribing }

    let failed = try XCTUnwrap(model.sessions.first { $0.id == session.id })
    XCTAssertEqual(failed.status, .failed)
    XCTAssertTrue(
      failed.processingError?.contains("still being installed") == true,
      failed.processingError ?? "nil")
    XCTAssertTrue(failed.processingError?.contains("transcribe the session again") == true)
    XCTAssertEqual(model.recorderErrorMessage, failed.processingError)
    XCTAssertTrue(
      failed.transcriptionEvidence?.issues.contains { $0.contains("No whisper model is installed") }
        == true,
      "Evidence keeps the loader's own words")

    model.retranscribeSession(id: session.id)
    await eventually { !model.isTranscribing }
    var calls = await downloader.callCount()
    XCTAssertEqual(calls, 1, "A running download is never started twice")

    await downloader.release()
    await waitUntilIdle(provisioner)
    XCTAssertEqual(provisioner.state, .ready)
    calls = await downloader.callCount()
    XCTAssertEqual(calls, 1)
  }

  func testURLSessionDownloaderMovesTheFileIntoStaging() async throws {
    // Exercises the delegate plumbing with a local file URL; the network is never used.
    let source = root.appendingPathComponent("source-model.bin")
    try TranscriptionModelFixture.validData.write(to: source)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    let progressValues = ProgressRecorder()

    let downloaded = try await LocalSessionTranscriptionModelURLSessionDownloader(
      sourceURL: source
    ).download(
      into: staging,
      expectedSize: TranscriptionModelFixture.attestation.size,
      progress: { await progressValues.record($0) }
    )

    XCTAssertEqual(downloaded, staging.appendingPathComponent("ggml-model.bin"))
    XCTAssertEqual(try Data(contentsOf: downloaded), TranscriptionModelFixture.validData)
    let recorded = await progressValues.values
    XCTAssertTrue(recorded.allSatisfy { (0...1).contains($0) })
  }

  // MARK: - Helpers

  private func makeLayout() -> LocalSessionFileLayout {
    LocalSessionFileLayout(baseDirectory: root, compatibleModelSearchRoots: [])
  }

  private func plan() -> LocalSessionTranscriptionPlan {
    makeLayout().resolvedTranscriptionPlan(settings: Self.settings, fileManager: fileManager)
  }

  private static let settings = LocalSessionTranscriptionSettings(
    speedMode: .balanced,
    languagePreference: .mixed
  )

  private func makeProvisioner(
    downloader: any LocalSessionTranscriptionModelDownloading
  ) -> LocalSessionTranscriptionModelProvisioner {
    LocalSessionTranscriptionModelProvisioner(
      fileLayout: makeLayout(),
      downloader: downloader,
      validator: LocalSessionTranscriptionModelValidator(
        fileManager: fileManager,
        attestation: TranscriptionModelFixture.attestation
      ),
      fileManager: fileManager,
      transcriptionSettings: { Self.settings },
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
  }

  private func stagingDirectories() throws -> [String] {
    let modelsDirectory = makeLayout().modelsDirectory
    guard fileManager.fileExists(atPath: modelsDirectory.path) else { return [] }
    return try fileManager.contentsOfDirectory(atPath: modelsDirectory.path)
      .filter { $0.hasPrefix(LocalSessionTranscriptionModelContract.stagingDirectoryPrefix) }
  }

  private func waitUntilIdle(
    _ provisioner: LocalSessionTranscriptionModelProvisioner,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<400 {
      if !provisioner.isWorking { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Provisioning did not settle.", file: file, line: line)
  }

  private func eventually(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
  ) async {
    for _ in 0..<500 {
      if await condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for condition.", file: file, line: line)
  }
}

private actor TranscriptionModelDownloaderStub: LocalSessionTranscriptionModelDownloading {
  enum Outcome: Equatable, Sendable {
    case valid
    case corrupt
    case failure
  }

  private var outcomes: [Outcome]
  private let holds: Bool
  private var calls = 0
  private var gate: CheckedContinuation<Void, Never>?

  init(outcomes: [Outcome], holds: Bool = false) {
    self.outcomes = outcomes
    self.holds = holds
  }

  func download(
    into stagingDirectory: URL,
    expectedSize: Int64,
    progress: @escaping @Sendable (Double) async -> Void
  ) async throws -> URL {
    calls += 1
    await progress(0.25)
    if holds {
      await withCheckedContinuation { gate = $0 }
    }
    guard !outcomes.isEmpty else {
      throw CocoaError(.fileNoSuchFile)
    }
    let outcome = outcomes.removeFirst()
    let url = stagingDirectory.appendingPathComponent("ggml-model.bin")
    switch outcome {
    case .valid:
      try TranscriptionModelFixture.validData.write(to: url)
    case .corrupt:
      try TranscriptionModelFixture.corruptData.write(to: url)
    case .failure:
      throw URLError(.notConnectedToInternet)
    }
    await progress(1)
    return url
  }

  func isHolding() -> Bool {
    gate != nil
  }

  func release() {
    gate?.resume()
    gate = nil
  }

  func callCount() -> Int {
    calls
  }
}

private actor ProgressRecorder {
  private(set) var values: [Double] = []

  func record(_ value: Double) {
    values.append(value)
  }
}

private final class MissingModelTranscriber: @unchecked Sendable, LocalSessionTranscribing {
  func warmUp(modelURL: URL) async {}

  func transcribe(
    wavURL: URL,
    modelURL: URL,
    language: String,
    prompt: String?,
    translateToEnglish: Bool,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  ) async throws -> LocalSessionTranscriptionResult {
    throw LocalSessionTranscriptionServiceError.modelLoadFailed(
      "No whisper model is installed at \(modelURL.path).")
  }
}

private enum TranscriptionModelFixture {
  /// Starts with the GGML magic so the transcription plan treats it as a whisper.cpp model.
  static let validData: Data =
    Data([0x6c, 0x6d, 0x67, 0x67]) + Data((0..<8_192).map { UInt8($0 % 251) })

  /// Same size, different bytes.
  static let corruptData: Data = {
    var data = validData
    data[100] ^= 0xFF
    return data
  }()

  static let attestation = LocalSessionTranscriptionModelContract.FileAttestation(
    size: Int64(validData.count),
    sha256: SHA256.hash(data: validData).map { String(format: "%02x", $0) }.joined()
  )

  static func writeValid(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try validData.write(to: url)
  }
}
