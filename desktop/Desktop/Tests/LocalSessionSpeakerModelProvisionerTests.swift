import CryptoKit
import Foundation
import XCTest

@testable import CepessaSessions

@MainActor
final class LocalSessionSpeakerModelProvisionerTests: XCTestCase {
  private var root: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    root = fileManager.temporaryDirectory.appendingPathComponent(
      "SpeakerModelProvisionerTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root {
      try? fileManager.removeItem(at: root)
    }
  }

  func testContractPinsExactSDKAndModelRevisions() {
    XCTAssertEqual(
      LocalSessionSpeakerModelContract.speakerKitRevision,
      "e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef"
    )
    XCTAssertEqual(
      LocalSessionSpeakerModelContract.modelRevision,
      "86ec9c929b52208b6656eb6a6361ed0d822a1f78"
    )
    XCTAssertEqual(LocalSessionSpeakerModelContract.expectedModels.count, 4)
    XCTAssertEqual(LocalSessionSpeakerModelContract.attestedFiles.count, 20)
  }

  func testMissingInstallationStartsNotInstalledWithoutDownloading() async {
    let downloader = SpeakerModelDownloaderStub(outcomes: [])
    let provisioner = makeProvisioner(downloader: downloader)
    XCTAssertEqual(provisioner.state, .notInstalled)
    let calls = await downloader.callCount()
    XCTAssertEqual(calls, 0)
  }

  func testPartialDownloadFailsWithoutActivating() async {
    let downloader = SpeakerModelDownloaderStub(outcomes: [.partial])
    let provisioner = makeProvisioner(downloader: downloader)
    provisioner.prepareIfNeeded()
    await waitUntilSettled(provisioner)

    guard case .failed(let message) = provisioner.state else {
      return XCTFail("Expected failed state, got \(provisioner.state)")
    }
    XCTAssertTrue(message.contains("PldaProjector"))
    XCTAssertFalse(fileManager.fileExists(atPath: provisioner.activeRoot.path))
  }

  func testCorruptDownloadFailsWithoutActivating() async {
    let downloader = SpeakerModelDownloaderStub(outcomes: [.corrupt])
    let provisioner = makeProvisioner(downloader: downloader)
    provisioner.prepareIfNeeded()
    await waitUntilSettled(provisioner)

    guard case .failed(let message) = provisioner.state else {
      return XCTFail("Expected failed state, got \(provisioner.state)")
    }
    XCTAssertTrue(message.contains("attestation"))
    XCTAssertFalse(fileManager.fileExists(atPath: provisioner.activeRoot.path))
  }

  func testInterruptedStagingIsRemovedAtStartup() throws {
    let layout = makeLayout()
    let interrupted = layout.modelsDirectory.appendingPathComponent(
      ".speakerkit-staging-interrupted",
      isDirectory: true
    )
    try fileManager.createDirectory(at: interrupted, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: interrupted.appendingPathComponent("partial.bin"))

    _ = makeProvisioner(downloader: SpeakerModelDownloaderStub(outcomes: []))

    XCTAssertFalse(fileManager.fileExists(atPath: interrupted.path))
  }

  func testSuccessfulDownloadWritesManifestAndActivatesAtomically() async throws {
    let downloader = SpeakerModelDownloaderStub(outcomes: [.valid])
    let provisioner = makeProvisioner(downloader: downloader)
    provisioner.prepareIfNeeded()
    await waitUntilSettled(provisioner)

    XCTAssertEqual(provisioner.state, .ready)
    XCTAssertNoThrow(
      try LocalSessionSpeakerModelValidator(
        fileManager: fileManager,
        attestations: SpeakerModelFixture.attestations
      )
        .validateActiveRoot(provisioner.activeRoot)
    )
    let manifestURL = provisioner.activeRoot.appendingPathComponent(
      LocalSessionSpeakerModelContract.manifestFileName
    )
    XCTAssertTrue(fileManager.fileExists(atPath: manifestURL.path))
    let calls = await downloader.callCount()
    XCTAssertEqual(calls, 1)
  }

  func testRetryAfterFailureCanReachReady() async {
    let downloader = SpeakerModelDownloaderStub(outcomes: [.failure, .valid])
    let provisioner = makeProvisioner(downloader: downloader)
    provisioner.prepareIfNeeded()
    await waitUntilSettled(provisioner)
    guard case .failed = provisioner.state else {
      return XCTFail("First attempt should fail.")
    }

    provisioner.retry()
    await waitUntilSettled(provisioner)

    XCTAssertEqual(provisioner.state, .ready)
    let calls = await downloader.callCount()
    XCTAssertEqual(calls, 2)
  }

  func testRetryReplacesCorruptActiveInstallation() async throws {
    let layout = makeLayout()
    let activeRoot = layout.modelsDirectory.appendingPathComponent(
      "speakerkit-coreml",
      isDirectory: true
    )
    try SpeakerModelFixture.writeValidModels(
      to: activeRoot,
      omitting: "SpeakerSegmenter",
      fileManager: fileManager
    )
    let downloader = SpeakerModelDownloaderStub(outcomes: [.valid])
    let provisioner = makeProvisioner(downloader: downloader)
    guard case .failed = provisioner.state else {
      return XCTFail("Corrupt active installation must not be ready.")
    }

    provisioner.retry()
    await waitUntilSettled(provisioner)

    XCTAssertEqual(provisioner.state, .ready)
    XCTAssertNoThrow(
      try LocalSessionSpeakerModelValidator(
        fileManager: fileManager,
        attestations: SpeakerModelFixture.attestations
      )
        .validateActiveRoot(activeRoot)
    )
  }

  func testVerifiedOfflineInstallationNeverCallsDownloader() async throws {
    let layout = makeLayout()
    let activeRoot = layout.modelsDirectory.appendingPathComponent(
      "speakerkit-coreml",
      isDirectory: true
    )
    try SpeakerModelFixture.writeValidModels(to: activeRoot, fileManager: fileManager)
    try SpeakerModelFixture.writeManifest(
      to: activeRoot,
      attestations: SpeakerModelFixture.attestations
    )
    let downloader = SpeakerModelDownloaderStub(outcomes: [.failure])

    let provisioner = makeProvisioner(downloader: downloader)
    XCTAssertEqual(provisioner.state, .ready)
    provisioner.prepareIfNeeded()
    try? await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(provisioner.state, .ready)
    let calls = await downloader.callCount()
    XCTAssertEqual(calls, 0)
  }

  func testSameSizeModelTamperFailsActiveAttestation() throws {
    let layout = makeLayout()
    let activeRoot = layout.modelsDirectory.appendingPathComponent(
      "speakerkit-coreml",
      isDirectory: true
    )
    try SpeakerModelFixture.writeValidModels(to: activeRoot, fileManager: fileManager)
    try SpeakerModelFixture.writeManifest(
      to: activeRoot,
      attestations: SpeakerModelFixture.attestations
    )
    let target = try XCTUnwrap(SpeakerModelFixture.attestations.first)
    let targetURL = activeRoot.appendingPathComponent(target.path)
    try Data(repeating: 0xA5, count: target.size).write(to: targetURL)

    let provisioner = makeProvisioner(downloader: SpeakerModelDownloaderStub(outcomes: []))

    guard case .failed(let message) = provisioner.state else {
      return XCTFail("Tampered active bytes must fail.")
    }
    XCTAssertTrue(message.contains("attestation"))
  }

  func testSelfWrittenManifestCannotBlessUntrustedAttestationSet() throws {
    let layout = makeLayout()
    let activeRoot = layout.modelsDirectory.appendingPathComponent(
      "speakerkit-coreml",
      isDirectory: true
    )
    try SpeakerModelFixture.writeValidModels(to: activeRoot, fileManager: fileManager)
    try SpeakerModelFixture.writeManifest(to: activeRoot, attestations: [])

    let provisioner = makeProvisioner(downloader: SpeakerModelDownloaderStub(outcomes: []))

    guard case .failed(let message) = provisioner.state else {
      return XCTFail("A forged manifest must fail.")
    }
    XCTAssertTrue(message.contains("pinned model revision"))
  }

  private func makeLayout() -> LocalSessionFileLayout {
    LocalSessionFileLayout(baseDirectory: root)
  }

  private func makeProvisioner(
    downloader: any LocalSessionSpeakerModelDownloading
  ) -> LocalSessionSpeakerModelProvisioner {
    LocalSessionSpeakerModelProvisioner(
      fileLayout: makeLayout(),
      downloader: downloader,
      validator: LocalSessionSpeakerModelValidator(
        fileManager: fileManager,
        attestations: SpeakerModelFixture.attestations
      ),
      fileManager: fileManager,
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
  }

  private func waitUntilSettled(
    _ provisioner: LocalSessionSpeakerModelProvisioner
  ) async {
    for _ in 0..<200 {
      switch provisioner.state {
      case .ready, .failed:
        return
      case .notInstalled, .downloading, .verifying:
        try? await Task.sleep(nanoseconds: 5_000_000)
      }
    }
    XCTFail("Provisioning did not settle.")
  }
}

private actor SpeakerModelDownloaderStub: LocalSessionSpeakerModelDownloading {
  enum Outcome: Equatable, Sendable {
    case valid
    case partial
    case corrupt
    case failure
  }

  private var outcomes: [Outcome]
  private var calls = 0

  init(outcomes: [Outcome]) {
    self.outcomes = outcomes
  }

  func download(
    into stagingDirectory: URL,
    progress: @escaping @Sendable (Double) async -> Void
  ) async throws -> URL {
    calls += 1
    await progress(0.5)
    guard !outcomes.isEmpty else {
      throw CocoaError(.fileNoSuchFile)
    }
    let outcome = outcomes.removeFirst()
    if outcome == .failure {
      throw URLError(.notConnectedToInternet)
    }
    let snapshot = stagingDirectory.appendingPathComponent("snapshot", isDirectory: true)
    switch outcome {
    case .valid:
      try SpeakerModelFixture.writeValidModels(to: snapshot)
    case .partial:
      try SpeakerModelFixture.writeValidModels(to: snapshot, omitting: "PldaProjector")
    case .corrupt:
      try SpeakerModelFixture.writeValidModels(to: snapshot, empty: "SpeakerEmbedder")
    case .failure:
      break
    }
    await progress(1)
    return snapshot
  }

  func callCount() -> Int {
    calls
  }
}

private enum SpeakerModelFixture {
  static let attestations: [LocalSessionSpeakerModelContract.FileAttestation] =
    LocalSessionSpeakerModelContract.attestedFiles.map { pinned in
      let data = fixtureData(for: pinned.path)
      return .init(
        path: pinned.path,
        size: data.count,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      )
    }

  static func writeValidModels(
    to root: URL,
    omitting omittedName: String? = nil,
    empty emptyName: String? = nil,
    fileManager: FileManager = .default
  ) throws {
    for attestation in attestations
    where omittedName.map({ !attestation.path.contains($0) }) ?? true {
      let url = root.appendingPathComponent(attestation.path, isDirectory: false)
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data =
        emptyName.map { attestation.path.contains($0) } == true
        ? Data() : fixtureData(for: attestation.path)
      try data.write(to: url)
    }
  }

  static func writeManifest(
    to root: URL,
    attestations: [LocalSessionSpeakerModelContract.FileAttestation]
  ) throws {
    let manifest = LocalSessionSpeakerModelManifest(
      repository: LocalSessionSpeakerModelContract.repository,
      modelRevision: LocalSessionSpeakerModelContract.modelRevision,
      speakerKitRevision: LocalSessionSpeakerModelContract.speakerKitRevision,
      installedAt: Date(timeIntervalSince1970: 1_800_000_000),
      expectedModels: LocalSessionSpeakerModelContract.expectedModels,
      attestedFiles: attestations
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(
      to: root.appendingPathComponent(LocalSessionSpeakerModelContract.manifestFileName)
    )
  }

  private static func fixtureData(for path: String) -> Data {
    Data((String(repeating: "fixture-byte-contract:", count: 4) + path).utf8)
  }
}
