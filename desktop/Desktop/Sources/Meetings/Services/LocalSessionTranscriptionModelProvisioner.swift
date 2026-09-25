import Combine
import CryptoKit
import Darwin
import Foundation

/// The pinned Hebrew whisper.cpp model that `LocalSessionFileLayout.resolvedTranscriptionPlan`
/// falls back to when no other local speech model is installed.
enum LocalSessionTranscriptionModelContract {
  static let modelID = LocalSessionFileLayout.defaultHebrewModelID
  static let repository = "ivrit-ai/whisper-large-v3-turbo-ggml"
  static let revision = "2130c78e4a9cb4914cc4df91a1c3031407789705"
  static let fileName = "ggml-model.bin"
  static let manifestFileName = "cepessa-transcription-model-manifest.json"
  static let stagingDirectoryPrefix = ".transcription-model-staging-"

  static let pinnedFile = FileAttestation(
    size: 1_624_555_275,
    sha256: "c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1"
  )

  static var downloadURL: URL {
    URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")!
  }

  struct FileAttestation: Codable, Equatable, Sendable {
    let size: Int64
    let sha256: String
  }
}

/// Written next to the model after its size and SHA-256 were verified. On later launches the
/// file is trusted when the manifest, its size and its modification time still agree, so the
/// 1.6 GB file is not hashed again on every launch.
struct LocalSessionTranscriptionModelManifest: Codable, Equatable, Sendable {
  let repository: String
  let revision: String
  let fileName: String
  let attestation: LocalSessionTranscriptionModelContract.FileAttestation
  let verifiedAt: Date
  let fileModificationTimeNanoseconds: Int64
}

enum LocalSessionTranscriptionModelProvisioningState: Equatable, Sendable {
  case notInstalled
  case downloading(progress: Double)
  case verifying
  case ready
  case failed(message: String)
}

/// The model a transcription started now would use.
struct LocalSessionTranscriptionActiveModel: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    /// The pinned Hebrew model this provisioner installs.
    case pinnedHebrew
    /// Another usable model the transcription plan prefers or found elsewhere.
    case other
  }

  let kind: Kind
  let url: URL
  let displayName: String
}

enum LocalSessionTranscriptionModelValidationError: LocalizedError, Equatable {
  case missingFile
  case sizeMismatch(expected: Int64, actual: Int64)
  case checksumMismatch
  case unreadable(String)
  case insufficientSpace(required: Int64, available: Int64)
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
    case .missingFile:
      return "The downloaded speech model file is missing."
    case .sizeMismatch(let expected, let actual):
      return
        "The speech model file is \(Self.bytes(actual)) instead of the expected \(Self.bytes(expected))."
    case .checksumMismatch:
      return "The speech model file failed its SHA-256 check."
    case .unreadable(let reason):
      return "The speech model file could not be read. \(reason)"
    case .insufficientSpace(let required, let available):
      return
        "Not enough free disk space: the speech model needs \(Self.bytes(required)), \(Self.bytes(available)) is free."
    case .httpStatus(let code):
      return "The model server answered with HTTP \(code)."
    }
  }

  private static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }
}

struct LocalSessionTranscriptionModelValidator: @unchecked Sendable {
  enum InstalledStatus: Equatable, Sendable {
    case missing
    /// Right size, but no manifest vouches for these exact bytes yet.
    case needsVerification
    case incomplete(actualSize: Int64)
    case trusted
  }

  let fileManager: FileManager
  let attestation: LocalSessionTranscriptionModelContract.FileAttestation

  init(
    fileManager: FileManager = .default,
    attestation: LocalSessionTranscriptionModelContract.FileAttestation =
      LocalSessionTranscriptionModelContract.pinnedFile
  ) {
    self.fileManager = fileManager
    self.attestation = attestation
  }

  func installedStatus(modelURL: URL, manifestURL: URL) -> InstalledStatus {
    guard let info = Self.fileInfo(modelURL) else { return .missing }
    guard info.size == attestation.size else { return .incomplete(actualSize: info.size) }
    guard
      let manifest = readManifest(manifestURL),
      manifest.repository == LocalSessionTranscriptionModelContract.repository,
      manifest.revision == LocalSessionTranscriptionModelContract.revision,
      manifest.fileName == LocalSessionTranscriptionModelContract.fileName,
      manifest.attestation == attestation,
      manifest.fileModificationTimeNanoseconds == info.modificationTimeNanoseconds
    else {
      return .needsVerification
    }
    return .trusted
  }

  /// Streams the file in 1 MB chunks. Call it off the main actor.
  func verifyContents(of url: URL) throws {
    guard let info = Self.fileInfo(url) else {
      throw LocalSessionTranscriptionModelValidationError.missingFile
    }
    guard info.size == attestation.size else {
      throw LocalSessionTranscriptionModelValidationError.sizeMismatch(
        expected: attestation.size,
        actual: info.size
      )
    }
    guard try sha256(of: url) == attestation.sha256 else {
      throw LocalSessionTranscriptionModelValidationError.checksumMismatch
    }
  }

  func makeManifest(for modelURL: URL, verifiedAt: Date) throws
    -> LocalSessionTranscriptionModelManifest
  {
    guard let info = Self.fileInfo(modelURL) else {
      throw LocalSessionTranscriptionModelValidationError.missingFile
    }
    return LocalSessionTranscriptionModelManifest(
      repository: LocalSessionTranscriptionModelContract.repository,
      revision: LocalSessionTranscriptionModelContract.revision,
      fileName: LocalSessionTranscriptionModelContract.fileName,
      attestation: attestation,
      verifiedAt: verifiedAt,
      fileModificationTimeNanoseconds: info.modificationTimeNanoseconds
    )
  }

  func sha256(of url: URL) throws -> String {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw LocalSessionTranscriptionModelValidationError.unreadable(error.localizedDescription)
    }
    defer { try? handle.close() }
    var hasher = SHA256()
    do {
      while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        try Task.checkCancellation()
        hasher.update(data: chunk)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw LocalSessionTranscriptionModelValidationError.unreadable(error.localizedDescription)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func readManifest(_ url: URL) -> LocalSessionTranscriptionModelManifest? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(LocalSessionTranscriptionModelManifest.self, from: data)
  }

  private struct FileInfo {
    let size: Int64
    let modificationTimeNanoseconds: Int64
  }

  private static func fileInfo(_ url: URL) -> FileInfo? {
    var status = stat()
    guard stat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
    let modified = status.st_mtimespec
    return FileInfo(
      size: Int64(status.st_size),
      modificationTimeNanoseconds: Int64(modified.tv_sec) * 1_000_000_000 + Int64(modified.tv_nsec)
    )
  }
}

protocol LocalSessionTranscriptionModelDownloading: Sendable {
  /// Downloads the model file into `stagingDirectory` and returns the downloaded file.
  func download(
    into stagingDirectory: URL,
    expectedSize: Int64,
    progress: @escaping @Sendable (Double) async -> Void
  ) async throws -> URL
}

struct LocalSessionTranscriptionModelURLSessionDownloader: LocalSessionTranscriptionModelDownloading
{
  let sourceURL: URL

  init(sourceURL: URL = LocalSessionTranscriptionModelContract.downloadURL) {
    self.sourceURL = sourceURL
  }

  func download(
    into stagingDirectory: URL,
    expectedSize: Int64,
    progress: @escaping @Sendable (Double) async -> Void
  ) async throws -> URL {
    let destination = stagingDirectory.appendingPathComponent(
      LocalSessionTranscriptionModelContract.fileName,
      isDirectory: false
    )
    let delegate = LocalSessionTranscriptionModelDownloadDelegate(
      destination: destination,
      expectedSize: expectedSize,
      progress: progress
    )
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    defer { session.finishTasksAndInvalidate() }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        delegate.start(session.downloadTask(with: sourceURL), continuation: continuation)
      }
    } onCancel: {
      delegate.cancel()
    }
  }
}

private final class LocalSessionTranscriptionModelDownloadDelegate: NSObject,
  URLSessionDownloadDelegate, @unchecked Sendable
{
  private let destination: URL
  private let expectedSize: Int64
  private let progress: @Sendable (Double) async -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URL, Error>?
  private var task: URLSessionDownloadTask?
  private var isCancelled = false
  private var finishError: Error?
  private var downloadedURL: URL?
  private var lastReportedStep = -1

  init(
    destination: URL,
    expectedSize: Int64,
    progress: @escaping @Sendable (Double) async -> Void
  ) {
    self.destination = destination
    self.expectedSize = expectedSize
    self.progress = progress
  }

  func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<URL, Error>) {
    lock.lock()
    guard !isCancelled else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.task = task
    self.continuation = continuation
    lock.unlock()
    task.resume()
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let task = self.task
    lock.unlock()
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
    guard total > 0 else { return }
    let fraction = min(1, max(0, Double(totalBytesWritten) / Double(total)))
    // Half-percent steps: enough for a progress bar without flooding the main actor.
    let step = Int(fraction * 200)
    lock.lock()
    guard step > lastReportedStep else {
      lock.unlock()
      return
    }
    lastReportedStep = step
    lock.unlock()
    let progress = self.progress
    Task { await progress(fraction) }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    // The temporary file is deleted when this method returns, so move it synchronously.
    if let response = downloadTask.response as? HTTPURLResponse,
      !(200..<300).contains(response.statusCode)
    {
      finishError = LocalSessionTranscriptionModelValidationError.httpStatus(response.statusCode)
      return
    }
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: location, to: destination)
      downloadedURL = destination
    } catch {
      finishError = error
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    let isCancelled = self.isCancelled
    lock.unlock()

    if isCancelled {
      continuation?.resume(throwing: CancellationError())
    } else if let error {
      continuation?.resume(throwing: error)
    } else if let finishError {
      continuation?.resume(throwing: finishError)
    } else if let downloadedURL {
      continuation?.resume(returning: downloadedURL)
    } else {
      continuation?.resume(throwing: LocalSessionTranscriptionModelValidationError.missingFile)
    }
  }
}

/// Installs, recognises and verifies the pinned Hebrew speech model, and reports whether any
/// usable local transcription model exists.
@MainActor
final class LocalSessionTranscriptionModelProvisioner: ObservableObject {
  /// `.ready` whenever a transcription could run now, with the pinned Hebrew model or with
  /// another usable model (`activeModel` says which). `downloading`/`verifying`/`failed`
  /// describe work on the pinned Hebrew model.
  @Published private(set) var state: LocalSessionTranscriptionModelProvisioningState =
    .notInstalled
  @Published private(set) var activeModel: LocalSessionTranscriptionActiveModel?
  @Published private(set) var isHebrewModelInstalled = false

  let modelURL: URL
  let manifestURL: URL

  private let fileLayout: LocalSessionFileLayout
  private let modelsDirectory: URL
  private let modelDirectory: URL
  private let downloader: any LocalSessionTranscriptionModelDownloading
  private let validator: LocalSessionTranscriptionModelValidator
  private let fileManager: FileManager
  private let transcriptionSettings: () -> LocalSessionTranscriptionSettings
  private let now: @Sendable () -> Date
  private var task: Task<Void, Never>?
  private var isInstallRequested = false

  init(
    fileLayout: LocalSessionFileLayout,
    downloader: any LocalSessionTranscriptionModelDownloading =
      LocalSessionTranscriptionModelURLSessionDownloader(),
    validator: LocalSessionTranscriptionModelValidator? = nil,
    fileManager: FileManager = .default,
    transcriptionSettings: @escaping () -> LocalSessionTranscriptionSettings = { .current() },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.fileLayout = fileLayout
    modelsDirectory = fileLayout.modelsDirectory
    modelDirectory = fileLayout.modelDirectory(for: LocalSessionTranscriptionModelContract.modelID)
    modelURL = modelDirectory.appendingPathComponent(
      LocalSessionTranscriptionModelContract.fileName,
      isDirectory: false
    )
    manifestURL = modelDirectory.appendingPathComponent(
      LocalSessionTranscriptionModelContract.manifestFileName,
      isDirectory: false
    )
    self.downloader = downloader
    self.validator = validator ?? LocalSessionTranscriptionModelValidator(fileManager: fileManager)
    self.fileManager = fileManager
    self.transcriptionSettings = transcriptionSettings
    self.now = now
    refreshState()
  }

  var hasUsableModel: Bool { activeModel != nil }

  var isWorking: Bool { task != nil }

  /// Automatic install: downloads the pinned Hebrew model only when no usable model exists.
  /// Never starts a second download.
  func prepareIfNeeded() {
    if task == nil { refreshState() }
    guard activeModel == nil else { return }
    if task != nil {
      // A running verification continues into a download if the file on disk fails it.
      isInstallRequested = true
      return
    }
    startProvisioning(install: true)
  }

  /// Explicit install from Settings, also when another model is usable.
  func installHebrewModel() {
    if task == nil { refreshState() }
    if task != nil {
      isInstallRequested = true
      return
    }
    guard !isHebrewModelInstalled else { return }
    startProvisioning(install: true)
  }

  func retry() {
    guard task == nil else { return }
    installHebrewModel()
  }

  func refreshState() {
    guard task == nil else { return }
    cleanupInterruptedStaging()
    let status = hebrewStatus()
    apply(status)
    if status == .needsVerification {
      startProvisioning(install: false)
    }
  }

  /// Whether `plan` points at a model that can load now. Checked fresh, without side effects.
  func isUsable(_ plan: LocalSessionTranscriptionPlan) -> Bool {
    usableModel(for: plan, hebrewStatus: hebrewStatus()) != nil
  }

  /// What a transcription that failed for lack of a model should tell the owner.
  var unavailableModelMessage: String {
    switch state {
    case .downloading, .verifying:
      return
        "This session wasn’t transcribed because the Hebrew speech model is still being installed on this Mac (about 1.6 GB, once). When it’s ready, transcribe the session again."
    case .failed(let message):
      return
        "This session wasn’t transcribed because no speech model is installed on this Mac, and installing the Hebrew speech model failed: \(message) Retry it in Settings, then transcribe the session again."
    case .notInstalled, .ready:
      return
        "This session wasn’t transcribed because no speech model is installed on this Mac. Install the Hebrew speech model in Settings, then transcribe the session again."
    }
  }

  // MARK: - Provisioning

  private func startProvisioning(install: Bool) {
    isInstallRequested = install
    state = hebrewStatus() == .needsVerification ? .verifying : .downloading(progress: 0)
    task = Task { [weak self] in
      await self?.provision()
    }
  }

  private func provision() async {
    // 1. Recognise a file already on disk: verify it once and vouch for it with a manifest.
    var adoptionError: Error?
    if hebrewStatus() == .needsVerification {
      state = .verifying
      do {
        try await verifyInBackground(modelURL)
        try writeManifest()
        finish()
        return
      } catch {
        adoptionError = error
      }
    }

    guard isInstallRequested else {
      finish(failure: adoptionError.map(adoptionFailureMessage(_:)))
      return
    }

    // 2. Download into a private staging directory, verify, then activate atomically.
    let stagingDirectory = modelsDirectory.appendingPathComponent(
      "\(LocalSessionTranscriptionModelContract.stagingDirectoryPrefix)\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
      try ensureFreeSpace(at: stagingDirectory)
      state = .downloading(progress: 0)
      let downloadedURL = try await downloader.download(
        into: stagingDirectory,
        expectedSize: validator.attestation.size,
        progress: { [weak self] progress in
          await self?.updateProgress(progress)
        }
      )
      state = .verifying
      try await verifyInBackground(downloadedURL)
      guard hebrewStatus() != .trusted else {
        // A verified model appeared meanwhile; never replace it.
        try? fileManager.removeItem(at: stagingDirectory)
        finish()
        return
      }
      try activate(downloadedURL)
      try writeManifest()
      try? fileManager.removeItem(at: stagingDirectory)
      finish()
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      finish(failure: error.localizedDescription)
    }
  }

  private func finish(failure: String? = nil) {
    task = nil
    isInstallRequested = false
    let status = hebrewStatus()
    guard let failure else {
      apply(status)
      return
    }
    isHebrewModelInstalled = status == .trusted
    activeModel = resolveActiveModel(hebrewStatus: status)
    state = .failed(message: failure)
  }

  private func apply(_ status: LocalSessionTranscriptionModelValidator.InstalledStatus) {
    isHebrewModelInstalled = status == .trusted
    activeModel = resolveActiveModel(hebrewStatus: status)
    switch status {
    case .trusted:
      state = .ready
    case .missing, .needsVerification:
      state = activeModel == nil ? .notInstalled : .ready
    case .incomplete(let actualSize):
      state =
        activeModel == nil
        ? .failed(
          message: LocalSessionTranscriptionModelValidationError.sizeMismatch(
            expected: validator.attestation.size,
            actual: actualSize
          ).errorDescription ?? "The speech model file is incomplete.")
        : .ready
    }
  }

  private func adoptionFailureMessage(_ error: Error) -> String {
    "The Hebrew speech model on this Mac didn’t pass verification. \(error.localizedDescription)"
  }

  private func updateProgress(_ progress: Double) {
    guard case .downloading(let current) = state else { return }
    state = .downloading(progress: max(current, max(0, min(progress, 1))))
  }

  private func verifyInBackground(_ url: URL) async throws {
    let validator = self.validator
    try await Task.detached(priority: .utility) {
      try validator.verifyContents(of: url)
    }.value
  }

  private func activate(_ downloadedURL: URL) throws {
    try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    // The old manifest describes the bytes being replaced.
    if fileManager.fileExists(atPath: manifestURL.path) {
      try fileManager.removeItem(at: manifestURL)
    }
    // rename(2) swaps the file in atomically on the same volume.
    guard rename(downloadedURL.path, modelURL.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func writeManifest() throws {
    let manifest = try validator.makeManifest(for: modelURL, verifiedAt: now())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
  }

  private func ensureFreeSpace(at directory: URL) throws {
    guard
      let values = try? directory.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey
      ]),
      let available = values.volumeAvailableCapacityForImportantUsage
    else {
      return
    }
    let required = validator.attestation.size
    if available < required {
      throw LocalSessionTranscriptionModelValidationError.insufficientSpace(
        required: required,
        available: available
      )
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
    for url in contents
    where url.lastPathComponent.hasPrefix(
      LocalSessionTranscriptionModelContract.stagingDirectoryPrefix)
    {
      try? fileManager.removeItem(at: url)
    }
  }

  // MARK: - Model resolution

  private func hebrewStatus() -> LocalSessionTranscriptionModelValidator.InstalledStatus {
    validator.installedStatus(modelURL: modelURL, manifestURL: manifestURL)
  }

  private func resolveActiveModel(
    hebrewStatus: LocalSessionTranscriptionModelValidator.InstalledStatus
  ) -> LocalSessionTranscriptionActiveModel? {
    let plan = fileLayout.resolvedTranscriptionPlan(
      settings: transcriptionSettings(),
      fileManager: fileManager
    )
    return usableModel(for: plan, hebrewStatus: hebrewStatus)
  }

  private func usableModel(
    for plan: LocalSessionTranscriptionPlan,
    hebrewStatus: LocalSessionTranscriptionModelValidator.InstalledStatus
  ) -> LocalSessionTranscriptionActiveModel? {
    let url = plan.modelURL
    if url.standardizedFileURL.path == modelURL.standardizedFileURL.path {
      guard hebrewStatus == .trusted else { return nil }
      return .init(kind: .pinnedHebrew, url: url, displayName: "Hebrew speech model")
    }

    switch plan.engine {
    case .whisperKit:
      guard
        LocalSessionWhisperKitModelInspector.isWhisperKitModelDirectory(
          url,
          fileManager: fileManager)
      else { return nil }
      return .init(kind: .other, url: url, displayName: "WhisperKit · \(url.lastPathComponent)")
    case .whisperCpp:
      guard fileLayout.isValidGGMLModelFile(url, fileManager: fileManager) else { return nil }
      let name = url.deletingLastPathComponent().lastPathComponent
      return .init(kind: .other, url: url, displayName: "whisper.cpp · \(name)")
    }
  }
}
