import Combine
import CryptoKit
import Foundation
import SpeakerKit

enum LocalSessionSpeakerModelContract {
  static let repository = "argmaxinc/speakerkit-coreml"
  static let modelRevision = "86ec9c929b52208b6656eb6a6361ed0d822a1f78"
  static let speakerKitRevision = "e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef"
  static let manifestFileName = "cepessa-speakerkit-manifest.json"

  static let expectedModels = [
    ExpectedModel(
      relativeDirectory: "speaker_segmenter/pyannote-v3/W8A16",
      bundleName: "SpeakerSegmenter"
    ),
    ExpectedModel(
      relativeDirectory: "speaker_embedder/pyannote-v3/W8A16",
      bundleName: "SpeakerEmbedderPreprocessor"
    ),
    ExpectedModel(
      relativeDirectory: "speaker_embedder/pyannote-v3/W8A16",
      bundleName: "SpeakerEmbedder"
    ),
    ExpectedModel(
      relativeDirectory: "speaker_clusterer/pyannote-v4/W32A32",
      bundleName: "PldaProjector"
    ),
  ]

  struct ExpectedModel: Codable, Equatable, Sendable {
    let relativeDirectory: String
    let bundleName: String
  }

  struct FileAttestation: Codable, Equatable, Sendable {
    let path: String
    let size: Int
    let sha256: String
  }

  static let attestedFiles: [FileAttestation] = [
    .init(path: "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "3e13c8f4df77ea27cbbcdd6d083c63f5e7b3f32566cc5bf223fab92d40b81b8b"),
    .init(path: "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/coremldata.bin", size: 327, sha256: "6f6820ccf221d4cc7c107101d0ae4d716eb224e4fdffaf8f7ca36af70ae64c40"),
    .init(path: "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/metadata.json", size: 1766, sha256: "acc86b4a4f542d8e7eaf84fc290fe72bd8629b0ffcc16e5b1a9e13d777abd9d8"),
    .init(path: "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/model.mil", size: 8128, sha256: "209e641bf4d9c3868c9dc43ab8705094997917eb2df5f5d8c8fda09fed54b1d4"),
    .init(path: "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/weights/weight.bin", size: 199040, sha256: "a1dbbb651a0a67fcfe5334672f459df090fa960917a6ee3a5423245a7ab92ced"),
    .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "ba8405dfc9b9348ade705e052888b4bdc7fb8d079ef3ff71108a5f692d0209f2"),
    .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/coremldata.bin", size: 370, sha256: "1597d6c037ac52436b5c2e1abc47e6c68483c19eeac75267dfb8795a78ec07c5"),
    .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/metadata.json", size: 2367, sha256: "29ea3421161c8344f6ea95db9b472217638a869f686f2494d10e5d11f11f4cda"),
    .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/model.mil", size: 451487, sha256: "5eee9f6aa380aef88fee604d75c5deaa23adc83c9480cb8f6dedc72803973e77"),
    .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/weights/weight.bin", size: 6661888, sha256: "a02861969f47cf3a67e3b0d276e54b3c8bc3a6e43d40d77d1cccbd57da0e5795"),
    .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "ce9bef9fb3125a5401300b5c5998c5d8f211094692cae780645d3e2757410f2c"),
    .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/coremldata.bin", size: 330, sha256: "b4ebd0b9ce5a84768672663aff426eb19f9648d4b9f74286f0e19fc753ad76ba"),
    .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/metadata.json", size: 1979, sha256: "789f81c17dc04d469611d253684e534565fb4a008e54c722b925f1608bf87fce"),
    .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/model.mil", size: 14224, sha256: "42e552ebd7efb12ea813eceb474018dd0f46168e84ad3a1c54945bfc47be7a82"),
    .init(path: "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/weights/weight.bin", size: 2181696, sha256: "5f2c284bd22f1f7ab76901c1c6e57f82d4ebbf057fa0b924aad057f124f77a89"),
    .init(path: "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "40637aa0cb2a073bc303c7ca9ee79da35fa81d2cad1ead180e93b134005b95de"),
    .init(path: "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/coremldata.bin", size: 497, sha256: "6c356ed983b2a3332ce51299ca0f9747a35cb6c2a67b0ac24c69dbef3f989634"),
    .init(path: "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/metadata.json", size: 3757, sha256: "2fd6aaf6beb17b3758f5d0c5b2cf5feeacb0cc0c9267dbcd7536b247b1a5860e"),
    .init(path: "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/model.mil", size: 193092, sha256: "423c358915acab0d440c99f5162c17456936c2c02f7394b05ab226b9a34c122a"),
    .init(path: "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/weights/weight.bin", size: 1520986, sha256: "75ff1725ef4e58dacf9176466ec274a8a13a6132c296d6b571fb78ddad5455c4"),
  ]
}

struct LocalSessionSpeakerModelManifest: Codable, Equatable, Sendable {
  let repository: String
  let modelRevision: String
  let speakerKitRevision: String
  let installedAt: Date
  let expectedModels: [LocalSessionSpeakerModelContract.ExpectedModel]
  let attestedFiles: [LocalSessionSpeakerModelContract.FileAttestation]
}

enum LocalSessionSpeakerModelProvisioningState: Equatable, Sendable {
  case notInstalled
  case downloading(progress: Double)
  case verifying
  case ready
  case failed(message: String)
}

enum LocalSessionSpeakerModelValidationError: LocalizedError {
  case missingModel(String)
  case emptyModel(String)
  case missingManifest
  case mismatchedManifest
  case contentMismatch(String)

  var errorDescription: String? {
    switch self {
    case .missingModel(let name):
      return "Required SpeakerKit model \(name) is missing."
    case .emptyModel(let name):
      return "Required SpeakerKit model \(name) is empty."
    case .missingManifest:
      return "The SpeakerKit installation manifest is missing."
    case .mismatchedManifest:
      return "The SpeakerKit installation does not match Cepessa's pinned model revision."
    case .contentMismatch(let path):
      return "SpeakerKit model content failed attestation: \(path)."
    }
  }
}

struct LocalSessionSpeakerModelValidator: @unchecked Sendable {
  let fileManager: FileManager
  let attestations: [LocalSessionSpeakerModelContract.FileAttestation]

  init(
    fileManager: FileManager = .default,
    attestations: [LocalSessionSpeakerModelContract.FileAttestation] =
      LocalSessionSpeakerModelContract.attestedFiles
  ) {
    self.fileManager = fileManager
    self.attestations = attestations
  }

  func validateDownloadedRoot(_ root: URL) throws {
    for expected in LocalSessionSpeakerModelContract.expectedModels {
      let directory = root.appendingPathComponent(expected.relativeDirectory, isDirectory: true)
      guard let modelURL = modelBundle(in: directory, named: expected.bundleName) else {
        throw LocalSessionSpeakerModelValidationError.missingModel(expected.bundleName)
      }
      guard containsRegularFile(modelURL) else {
        throw LocalSessionSpeakerModelValidationError.emptyModel(expected.bundleName)
      }
    }
    for attestation in attestations {
      let url = root.appendingPathComponent(attestation.path, isDirectory: false)
      guard
        let attributes = try? fileManager.attributesOfItem(atPath: url.path),
        (attributes[.size] as? NSNumber)?.intValue == attestation.size,
        sha256(url) == attestation.sha256
      else {
        throw LocalSessionSpeakerModelValidationError.contentMismatch(attestation.path)
      }
    }
  }

  func validateActiveRoot(_ root: URL) throws {
    try validateDownloadedRoot(root)
    let manifestURL = root.appendingPathComponent(
      LocalSessionSpeakerModelContract.manifestFileName,
      isDirectory: false
    )
    guard let data = try? Data(contentsOf: manifestURL) else {
      throw LocalSessionSpeakerModelValidationError.missingManifest
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let manifest = try? decoder.decode(LocalSessionSpeakerModelManifest.self, from: data)
    else {
      throw LocalSessionSpeakerModelValidationError.mismatchedManifest
    }
    guard
      manifest.repository == LocalSessionSpeakerModelContract.repository,
      manifest.modelRevision == LocalSessionSpeakerModelContract.modelRevision,
      manifest.speakerKitRevision == LocalSessionSpeakerModelContract.speakerKitRevision,
      manifest.expectedModels == LocalSessionSpeakerModelContract.expectedModels,
      manifest.attestedFiles == attestations
    else {
      throw LocalSessionSpeakerModelValidationError.mismatchedManifest
    }
  }

  private func sha256(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    do {
      while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        hasher.update(data: data)
      }
    } catch {
      return nil
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func modelBundle(in directory: URL, named name: String) -> URL? {
    ["mlmodelc", "mlpackage"].lazy
      .map { directory.appendingPathComponent("\(name).\($0)", isDirectory: true) }
      .first { fileManager.fileExists(atPath: $0.path) }
  }

  private func containsRegularFile(_ root: URL) -> Bool {
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return false
    }
    for case let url as URL in enumerator {
      if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        return true
      }
    }
    return false
  }
}

protocol LocalSessionSpeakerModelDownloading: Sendable {
  func download(
    into stagingDirectory: URL,
    progress: @escaping @Sendable (Double) async -> Void
  ) async throws -> URL
}

struct LocalSessionSpeakerKitModelDownloader: LocalSessionSpeakerModelDownloading {
  func download(
    into stagingDirectory: URL,
    progress: @escaping @Sendable (Double) async -> Void
  ) async throws -> URL {
    let config = PyannoteConfig(
      downloadBase: stagingDirectory.path,
      modelRepo: LocalSessionSpeakerModelContract.repository,
      download: true,
      useBackgroundDownloadSession: true,
      downloadRevision: LocalSessionSpeakerModelContract.modelRevision,
      load: false,
      verbose: false
    )
    await progress(0.05)
    _ = try await SpeakerKit(config)
    await progress(1)
    return try locateSnapshotRoot(in: stagingDirectory)
  }

  private func locateSnapshotRoot(in stagingDirectory: URL) throws -> URL {
    let fileManager = FileManager.default
    guard
      let enumerator = fileManager.enumerator(
        at: stagingDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      throw LocalSessionSpeakerModelValidationError.missingModel("snapshot root")
    }
    for case let candidate as URL in enumerator where candidate.lastPathComponent == "speaker_segmenter"
    {
      let root = candidate.deletingLastPathComponent()
      if (try? LocalSessionSpeakerModelValidator().validateDownloadedRoot(root)) != nil {
        return root
      }
    }
    throw LocalSessionSpeakerModelValidationError.missingModel("snapshot root")
  }
}

@MainActor
final class LocalSessionSpeakerModelProvisioner: ObservableObject {
  @Published private(set) var state: LocalSessionSpeakerModelProvisioningState = .notInstalled

  let activeRoot: URL

  private let modelsDirectory: URL
  private let downloader: any LocalSessionSpeakerModelDownloading
  private let validator: LocalSessionSpeakerModelValidator
  private let fileManager: FileManager
  private let now: @Sendable () -> Date
  private var task: Task<Void, Never>?

  init(
    fileLayout: LocalSessionFileLayout,
    downloader: any LocalSessionSpeakerModelDownloading = LocalSessionSpeakerKitModelDownloader(),
    validator: LocalSessionSpeakerModelValidator? = nil,
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    modelsDirectory = fileLayout.modelsDirectory
    activeRoot = fileLayout.modelsDirectory.appendingPathComponent(
      "speakerkit-coreml",
      isDirectory: true
    )
    self.downloader = downloader
    self.validator = validator ?? LocalSessionSpeakerModelValidator(fileManager: fileManager)
    self.fileManager = fileManager
    self.now = now
    refreshState()
  }

  func prepareIfNeeded() {
    guard task == nil, state != .ready else { return }
    state = .downloading(progress: 0)
    task = Task { [weak self] in
      await self?.provision()
    }
  }

  func retry() {
    guard task == nil else { return }
    prepareIfNeeded()
  }

  func refreshState() {
    cleanupInterruptedStaging()
    do {
      try validator.validateActiveRoot(activeRoot)
      state = .ready
    } catch {
      state = fileManager.fileExists(atPath: activeRoot.path)
        ? .failed(message: error.localizedDescription)
        : .notInstalled
    }
  }

  private func provision() async {
    let stagingDirectory = modelsDirectory.appendingPathComponent(
      ".speakerkit-staging-\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
      state = .downloading(progress: 0)
      let downloadedRoot = try await downloader.download(
        into: stagingDirectory,
        progress: { progress in
          await self.updateProgress(progress)
        }
      )
      state = .verifying
      try validator.validateDownloadedRoot(downloadedRoot)
      try writeManifest(to: downloadedRoot)
      try validator.validateActiveRoot(downloadedRoot)
      try activate(downloadedRoot)
      try validator.validateActiveRoot(activeRoot)
      task = nil
      state = .ready
      try? fileManager.removeItem(at: stagingDirectory)
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      task = nil
      state = .failed(message: error.localizedDescription)
    }
  }

  private func updateProgress(_ progress: Double) {
    state = .downloading(progress: max(0, min(progress, 1)))
  }

  private func writeManifest(to root: URL) throws {
    let manifest = LocalSessionSpeakerModelManifest(
      repository: LocalSessionSpeakerModelContract.repository,
      modelRevision: LocalSessionSpeakerModelContract.modelRevision,
      speakerKitRevision: LocalSessionSpeakerModelContract.speakerKitRevision,
      installedAt: now(),
      expectedModels: LocalSessionSpeakerModelContract.expectedModels,
      attestedFiles: validator.attestations
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(
      to: root.appendingPathComponent(LocalSessionSpeakerModelContract.manifestFileName),
      options: .withoutOverwriting
    )
  }

  private func activate(_ downloadedRoot: URL) throws {
    try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: activeRoot.path) {
      _ = try fileManager.replaceItemAt(
        activeRoot,
        withItemAt: downloadedRoot,
        backupItemName: nil,
        options: []
      )
    } else {
      try fileManager.moveItem(at: downloadedRoot, to: activeRoot)
    }
  }

  private func cleanupInterruptedStaging() {
    guard
      let contents = try? fileManager.contentsOfDirectory(
        at: modelsDirectory,
        includingPropertiesForKeys: nil,
        options: []
      )
    else {
      return
    }
    for url in contents where url.lastPathComponent.hasPrefix(".speakerkit-staging-") {
      try? fileManager.removeItem(at: url)
    }
  }
}
