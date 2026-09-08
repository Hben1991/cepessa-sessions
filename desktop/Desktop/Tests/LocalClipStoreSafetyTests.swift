import Darwin
import Foundation
import XCTest

@testable import CepessaSessions

final class LocalClipStoreSafetyTests: XCTestCase {
  private let fileManager = FileManager.default
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = fileManager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
      "LocalClipStoreSafety-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL {
      try? fileManager.removeItem(at: rootURL)
    }
    rootURL = nil
  }

  func testBulkLoadSkipsUnsafeAndMismatchedEntriesWithoutTouchingHealthySibling() throws {
    let layout = makeLayout()
    let store = LocalClipStore(fileLayout: layout)
    let healthy = makeClip(
      id: UUID(uuidString: "A11CE001-0001-4000-8000-000000000001")!,
      title: "Healthy sibling"
    )
    try store.save(healthy)

    let symlinkEntryID = UUID(uuidString: "A11CE002-0002-4000-8000-000000000002")!
    let symlinkTargetDirectory = rootURL.appendingPathComponent(
      "outside-symlink",
      isDirectory: true
    )
    try fileManager.createDirectory(at: symlinkTargetDirectory, withIntermediateDirectories: true)
    let symlinkTargetManifest = symlinkTargetDirectory.appendingPathComponent("clip.json")
    try encodedClipData(makeClip(id: symlinkEntryID, title: "Outside symlink target"))
      .write(to: symlinkTargetManifest)
    try fileManager.createSymbolicLink(
      at: layout.clipDirectory(for: symlinkEntryID),
      withDestinationURL: symlinkTargetDirectory
    )

    let hardlinkEntryID = UUID(uuidString: "A11CE003-0003-4000-8000-000000000003")!
    let hardlinkTargetManifest = rootURL.appendingPathComponent("outside-hardlink.json")
    try encodedClipData(makeClip(id: hardlinkEntryID, title: "Outside hardlink target"))
      .write(to: hardlinkTargetManifest)
    try fileManager.createDirectory(
      at: layout.clipDirectory(for: hardlinkEntryID),
      withIntermediateDirectories: true
    )
    XCTAssertEqual(
      Darwin.link(
        hardlinkTargetManifest.path,
        layout.manifestURL(for: hardlinkEntryID).path
      ),
      0
    )

    let mismatchedEntryID = UUID(uuidString: "A11CE004-0004-4000-8000-000000000004")!
    let mismatchedPayloadID = UUID(uuidString: "A11CE005-0005-4000-8000-000000000005")!
    try fileManager.createDirectory(
      at: layout.clipDirectory(for: mismatchedEntryID),
      withIntermediateDirectories: true
    )
    let mismatchedManifest = layout.manifestURL(for: mismatchedEntryID)
    try encodedClipData(makeClip(id: mismatchedPayloadID, title: "Wrong manifest identity"))
      .write(to: mismatchedManifest)

    let noncanonicalID = UUID(uuidString: "A11CE009-0009-4000-8000-000000000009")!
    let noncanonicalDirectory = layout.baseDirectory.appendingPathComponent(
      noncanonicalID.uuidString.lowercased(),
      isDirectory: true
    )
    try fileManager.createDirectory(at: noncanonicalDirectory, withIntermediateDirectories: true)
    let noncanonicalManifest = noncanonicalDirectory.appendingPathComponent("clip.json")
    try encodedClipData(makeClip(id: noncanonicalID, title: "Noncanonical directory"))
      .write(to: noncanonicalManifest)

    let symlinkVideoID = UUID(uuidString: "A11CE011-0011-4000-8000-000000000011")!
    try fileManager.createDirectory(
      at: layout.clipDirectory(for: symlinkVideoID),
      withIntermediateDirectories: true
    )
    try encodedClipData(makeClip(id: symlinkVideoID, title: "Linked outside video"))
      .write(to: layout.manifestURL(for: symlinkVideoID))
    let symlinkVideoTarget = rootURL.appendingPathComponent("outside-video.mov")
    try Data("outside video".utf8).write(to: symlinkVideoTarget)
    try fileManager.createSymbolicLink(
      at: layout.videoURL(for: symlinkVideoID),
      withDestinationURL: symlinkVideoTarget
    )

    let hardlinkAudioID = UUID(uuidString: "A11CE012-0012-4000-8000-000000000012")!
    try fileManager.createDirectory(
      at: layout.clipDirectory(for: hardlinkAudioID),
      withIntermediateDirectories: true
    )
    try encodedClipData(makeClip(id: hardlinkAudioID, title: "Linked outside audio"))
      .write(to: layout.manifestURL(for: hardlinkAudioID))
    let hardlinkAudioTarget = rootURL.appendingPathComponent("outside-audio.wav")
    try Data("outside audio".utf8).write(to: hardlinkAudioTarget)
    XCTAssertEqual(
      Darwin.link(hardlinkAudioTarget.path, layout.audioURL(for: hardlinkAudioID).path),
      0
    )

    let healthyBefore = try Data(contentsOf: layout.manifestURL(for: healthy.id))
    let symlinkTargetBefore = try Data(contentsOf: symlinkTargetManifest)
    let hardlinkTargetBefore = try Data(contentsOf: hardlinkTargetManifest)
    let mismatchedBefore = try Data(contentsOf: mismatchedManifest)
    let noncanonicalBefore = try Data(contentsOf: noncanonicalManifest)
    let symlinkVideoBefore = try Data(contentsOf: symlinkVideoTarget)
    let hardlinkAudioBefore = try Data(contentsOf: hardlinkAudioTarget)

    let loaded = store.loadClips()

    XCTAssertEqual(loaded.map(\.id), [healthy.id])
    XCTAssertEqual(try Data(contentsOf: layout.manifestURL(for: healthy.id)), healthyBefore)
    XCTAssertEqual(try Data(contentsOf: symlinkTargetManifest), symlinkTargetBefore)
    XCTAssertEqual(try Data(contentsOf: hardlinkTargetManifest), hardlinkTargetBefore)
    XCTAssertEqual(try Data(contentsOf: mismatchedManifest), mismatchedBefore)
    XCTAssertEqual(try Data(contentsOf: noncanonicalManifest), noncanonicalBefore)
    XCTAssertEqual(try Data(contentsOf: symlinkVideoTarget), symlinkVideoBefore)
    XCTAssertEqual(try Data(contentsOf: hardlinkAudioTarget), hardlinkAudioBefore)
    XCTAssertEqual(store.loadWarnings.count, 6)
    XCTAssertTrue(store.loadWarnings.allSatisfy { $0.contains("could not be opened") })
  }

  @MainActor
  func testViewModelPublishesWarningWhenUnsafeStoredClipIsSkipped() throws {
    let layout = makeLayout()
    try layout.ensureDirectories(fileManager: fileManager)
    let unsafeID = UUID(uuidString: "A11CE010-0010-4000-8000-000000000010")!
    let outsideDirectory = rootURL.appendingPathComponent("outside-model-load", isDirectory: true)
    try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(
      at: layout.clipDirectory(for: unsafeID),
      withDestinationURL: outsideDirectory
    )

    let model = LocalClipViewModel(
      store: LocalClipStore(fileLayout: layout),
      clipFileLayout: layout,
      sessionFileLayout: LocalSessionFileLayout(
        baseDirectory: rootURL.appendingPathComponent("Sessions", isDirectory: true)
      ),
      transcriptionService: ClipStoreSafetyTranscriber()
    )

    XCTAssertTrue(model.clips.isEmpty)
    XCTAssertTrue(model.statusMessage?.contains("could not be opened") == true)
  }

  @MainActor
  func testPlaybackRetryAndValidatorsRejectMediaLinkedAfterLoad() async throws {
    let layout = makeLayout()
    let store = LocalClipStore(fileLayout: layout)
    let clip = makeClip(
      id: UUID(uuidString: "A11CE013-0013-4000-8000-000000000013")!,
      title: "Post-load media swap"
    )
    try store.save(clip)
    let model = LocalClipViewModel(
      store: store,
      clipFileLayout: layout,
      sessionFileLayout: LocalSessionFileLayout(
        baseDirectory: rootURL.appendingPathComponent("Sessions", isDirectory: true)
      ),
      transcriptionService: ClipStoreSafetyTranscriber()
    )
    let videoTarget = rootURL.appendingPathComponent("post-load-video.mov")
    let videoBytes = Data("outside post-load video".utf8)
    try videoBytes.write(to: videoTarget)
    try fileManager.createSymbolicLink(
      at: layout.videoURL(for: clip.id),
      withDestinationURL: videoTarget
    )
    try Data("local audio placeholder".utf8).write(to: layout.audioURL(for: clip.id))

    XCTAssertNil(model.videoPlaybackURL(for: clip.id))
    XCTAssertFalse(model.canRetryTranscription(for: clip.id))
    let videoFailure = await LocalClipVideoValidator.failureReason(
      for: layout.videoURL(for: clip.id)
    )
    XCTAssertTrue(videoFailure?.contains("unsafe video file") == true)
    XCTAssertEqual(try Data(contentsOf: videoTarget), videoBytes)

    try fileManager.removeItem(at: layout.videoURL(for: clip.id))
    try Data("local video placeholder".utf8).write(to: layout.videoURL(for: clip.id))
    try fileManager.removeItem(at: layout.audioURL(for: clip.id))
    let audioTarget = rootURL.appendingPathComponent("post-load-audio.wav")
    let audioBytes = Data("outside post-load audio".utf8)
    try audioBytes.write(to: audioTarget)
    XCTAssertEqual(Darwin.link(audioTarget.path, layout.audioURL(for: clip.id).path), 0)

    XCTAssertNil(model.audioPlaybackURL(for: clip.id))
    XCTAssertFalse(model.canRetryTranscription(for: clip.id))
    XCTAssertNotNil(LocalClipAudioValidator.failureReason(for: layout.audioURL(for: clip.id)))
    XCTAssertEqual(try Data(contentsOf: audioTarget), audioBytes)
  }

  @MainActor
  func testPostLoadClipDirectorySymlinkDisablesMediaAccessWithoutReadingOutside() async throws {
    let layout = makeLayout()
    let store = LocalClipStore(fileLayout: layout)
    let clip = makeClip(
      id: UUID(uuidString: "A11CE014-0014-4000-8000-000000000014")!,
      title: "Post-load directory swap"
    )
    try store.save(clip)
    let videoBytes = Data("outside directory video".utf8)
    let audioBytes = Data("outside directory audio".utf8)
    try videoBytes.write(to: layout.videoURL(for: clip.id))
    try audioBytes.write(to: layout.audioURL(for: clip.id))
    let model = LocalClipViewModel(
      store: store,
      clipFileLayout: layout,
      sessionFileLayout: LocalSessionFileLayout(
        baseDirectory: rootURL.appendingPathComponent("Sessions", isDirectory: true)
      ),
      transcriptionService: ClipStoreSafetyTranscriber()
    )
    let outsideDirectory = rootURL.appendingPathComponent(
      "outside-post-load-directory",
      isDirectory: true
    )
    try fileManager.moveItem(at: layout.clipDirectory(for: clip.id), to: outsideDirectory)
    try fileManager.createSymbolicLink(
      at: layout.clipDirectory(for: clip.id),
      withDestinationURL: outsideDirectory
    )

    XCTAssertNil(model.videoPlaybackURL(for: clip.id))
    XCTAssertNil(model.audioPlaybackURL(for: clip.id))
    XCTAssertFalse(model.canRetryTranscription(for: clip.id))
    let videoFailure = await LocalClipVideoValidator.failureReason(
      for: layout.videoURL(for: clip.id)
    )
    XCTAssertTrue(videoFailure?.contains("unsafe video file") == true)
    XCTAssertNotNil(LocalClipAudioValidator.failureReason(for: layout.audioURL(for: clip.id)))
    XCTAssertEqual(
      try Data(contentsOf: outsideDirectory.appendingPathComponent("clip-video.mov")),
      videoBytes
    )
    XCTAssertEqual(
      try Data(contentsOf: outsideDirectory.appendingPathComponent("clip-audio.wav")),
      audioBytes
    )
  }

  func testSaveRejectsSymlinkClipDirectoryWithoutMutatingOutsideTarget() throws {
    let layout = makeLayout()
    try layout.ensureDirectories(fileManager: fileManager)
    let clip = makeClip(
      id: UUID(uuidString: "A11CE006-0006-4000-8000-000000000006")!,
      title: "Unsafe directory"
    )
    let outsideDirectory = rootURL.appendingPathComponent("outside-save", isDirectory: true)
    try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    let sentinelURL = outsideDirectory.appendingPathComponent("sentinel.txt")
    let sentinel = Data("do not change".utf8)
    try sentinel.write(to: sentinelURL)
    try fileManager.createSymbolicLink(
      at: layout.clipDirectory(for: clip.id),
      withDestinationURL: outsideDirectory
    )

    let rejectedDirectory = try XCTUnwrap(
      LocalStoragePath.checkedFileURL(layout.clipDirectory(for: clip.id)))
    XCTAssertThrowsError(try LocalClipStore(fileLayout: layout).save(clip)) { error in
      XCTAssertEqual(
        error as? LocalClipStorageError,
        .unsafeDirectory(rejectedDirectory)
      )
    }
    XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
    XCTAssertFalse(
      fileManager.fileExists(atPath: outsideDirectory.appendingPathComponent("clip.json").path))
    XCTAssertFalse(
      fileManager.fileExists(
        atPath: outsideDirectory.appendingPathComponent("transcript.json").path)
    )
    XCTAssertFalse(
      fileManager.fileExists(atPath: outsideDirectory.appendingPathComponent("notes.md").path))
  }

  func testSaveRejectsSymlinkedClipsRootAncestorWithoutCreatingOutsideFiles() throws {
    let containerURL = rootURL.appendingPathComponent("linked-container", isDirectory: true)
    let layout = LocalClipFileLayout(
      baseDirectory: containerURL.appendingPathComponent("Clips", isDirectory: true)
    )
    let outsideContainer = rootURL.appendingPathComponent("outside-container", isDirectory: true)
    let outsideClips = outsideContainer.appendingPathComponent("Clips", isDirectory: true)
    try fileManager.createDirectory(at: outsideClips, withIntermediateDirectories: true)
    let sentinelURL = outsideContainer.appendingPathComponent("sentinel.txt")
    let sentinel = Data("outside ancestor remains unchanged".utf8)
    try sentinel.write(to: sentinelURL)
    try fileManager.createSymbolicLink(at: containerURL, withDestinationURL: outsideContainer)
    let clip = makeClip(
      id: UUID(uuidString: "A11CE015-0015-4000-8000-000000000015")!,
      title: "Unsafe root ancestor"
    )

    let rejectedContainer = try XCTUnwrap(LocalStoragePath.checkedFileURL(containerURL))
    XCTAssertThrowsError(try LocalClipStore(fileLayout: layout).save(clip)) { error in
      XCTAssertEqual(error as? LocalClipStorageError, .unsafeDirectory(rejectedContainer))
    }
    XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
    XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: outsideClips.path).isEmpty)
  }

  func testSaveRejectsLinkedCanonicalArtifactsBeforeWritingAnything() throws {
    let layout = makeLayout()
    let store = LocalClipStore(fileLayout: layout)
    let symlinkClip = makeClip(
      id: UUID(uuidString: "A11CE007-0007-4000-8000-000000000007")!,
      title: "Unsafe transcript"
    )
    try layout.ensureDirectories(fileManager: fileManager, for: symlinkClip.id)
    let symlinkTarget = rootURL.appendingPathComponent("outside-transcript.json")
    let symlinkSentinel = Data("keep transcript target".utf8)
    try symlinkSentinel.write(to: symlinkTarget)
    try fileManager.createSymbolicLink(
      at: layout.transcriptURL(for: symlinkClip.id),
      withDestinationURL: symlinkTarget
    )

    XCTAssertThrowsError(try store.save(symlinkClip)) { error in
      XCTAssertEqual(
        error as? LocalClipStorageError,
        .unsafeArtifact(layout.transcriptURL(for: symlinkClip.id))
      )
    }
    XCTAssertEqual(try Data(contentsOf: symlinkTarget), symlinkSentinel)
    XCTAssertFalse(fileManager.fileExists(atPath: layout.manifestURL(for: symlinkClip.id).path))
    XCTAssertFalse(fileManager.fileExists(atPath: layout.notesURL(for: symlinkClip.id).path))

    let hardlinkClip = makeClip(
      id: UUID(uuidString: "A11CE008-0008-4000-8000-000000000008")!,
      title: "Unsafe manifest"
    )
    try layout.ensureDirectories(fileManager: fileManager, for: hardlinkClip.id)
    let hardlinkTarget = rootURL.appendingPathComponent("outside-manifest.json")
    let hardlinkSentinel = Data("keep manifest target".utf8)
    try hardlinkSentinel.write(to: hardlinkTarget)
    XCTAssertEqual(
      Darwin.link(hardlinkTarget.path, layout.manifestURL(for: hardlinkClip.id).path),
      0
    )

    XCTAssertThrowsError(try store.save(hardlinkClip)) { error in
      XCTAssertEqual(
        error as? LocalClipStorageError,
        .unsafeArtifact(layout.manifestURL(for: hardlinkClip.id))
      )
    }
    XCTAssertEqual(try Data(contentsOf: hardlinkTarget), hardlinkSentinel)
    XCTAssertFalse(fileManager.fileExists(atPath: layout.transcriptURL(for: hardlinkClip.id).path))
    XCTAssertFalse(fileManager.fileExists(atPath: layout.notesURL(for: hardlinkClip.id).path))
  }

  private func makeLayout() -> LocalClipFileLayout {
    LocalClipFileLayout(baseDirectory: rootURL.appendingPathComponent("Clips", isDirectory: true))
  }

  private func makeClip(id: UUID, title: String) -> LocalClipManifest {
    LocalClipManifest(
      id: id,
      title: title,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      endedAt: Date(timeIntervalSince1970: 1_700_000_001),
      status: .failed,
      intent: nil,
      videoFileName: "clip-video.mov",
      audioFileName: "clip-audio.wav",
      transcriptFileName: "transcript.json",
      notesFileName: "notes.md",
      transcriptSegments: [],
      postNotes: "",
      errorMessage: "Fixture"
    )
  }

  private func encodedClipData(_ clip: LocalClipManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(clip)
  }
}

private struct ClipStoreSafetyTranscriber: LocalSessionTranscribing {
  func warmUp(modelURL: URL) async {}

  func transcribe(
    wavURL: URL,
    modelURL: URL,
    language: String,
    prompt: String?,
    translateToEnglish: Bool,
    onProgress: (@Sendable (LocalSessionTranscriptionProgress) async -> Void)?
  ) async throws -> LocalSessionTranscriptionResult {
    throw CancellationError()
  }
}
