import AVFoundation
import Foundation
import XCTest

@testable import CepessaSessions

final class LocalClipArtifactValidatorTests: XCTestCase {
  func testAudioValidatorRejectsMissingAndHeaderOnlyWAV() throws {
    let fixture = try ClipArtifactFixture()
    defer { fixture.remove() }

    XCTAssertNotNil(LocalClipAudioValidator.failureReason(for: fixture.audioURL))

    let writer = try LocalMeetingWaveFileWriter(fileURL: fixture.audioURL)
    XCTAssertTrue(
      LocalClipAudioValidator.failureReason(for: fixture.audioURL)?.contains("no samples") == true
    )
    try writer.close()
  }

  func testAudioValidatorAcceptsLiveFinalizedHeaderWithSamples() throws {
    let fixture = try ClipArtifactFixture()
    defer { fixture.remove() }
    let writer = try LocalMeetingWaveFileWriter(fileURL: fixture.audioURL)

    try writer.append(samples: [1, -2, 3, -4])

    XCTAssertNil(LocalClipAudioValidator.failureReason(for: fixture.audioURL))
  }

  func testAudioValidatorRejectsTruncatedDataChunk() throws {
    let fixture = try ClipArtifactFixture()
    defer { fixture.remove() }
    let writer = try LocalMeetingWaveFileWriter(fileURL: fixture.audioURL)
    try writer.append(samples: [1, 2, 3])
    try writer.close()
    var bytes = try Data(contentsOf: fixture.audioURL)
    bytes.removeLast()
    try bytes.write(to: fixture.audioURL)

    XCTAssertTrue(
      LocalClipAudioValidator.failureReason(for: fixture.audioURL)?.contains("truncated") == true
    )
  }

  func testTranscriptValidatorRejectsBlankNonFiniteAndBackwardsSegments() {
    let input = [
      LocalSessionTranscriptionSegment(startTime: 0, endTime: 1, text: "  "),
      LocalSessionTranscriptionSegment(startTime: .nan, endTime: 1, text: "nan"),
      LocalSessionTranscriptionSegment(startTime: -1, endTime: 1, text: "negative"),
      LocalSessionTranscriptionSegment(startTime: 1, endTime: 1, text: "zero duration"),
      LocalSessionTranscriptionSegment(startTime: 2, endTime: 1, text: "backwards"),
      LocalSessionTranscriptionSegment(startTime: 1, endTime: 2.3, text: "past audio"),
      LocalSessionTranscriptionSegment(startTime: 1, endTime: 2, text: " usable "),
    ]

    let result = LocalClipTranscriptValidator.usableSegments(from: input, audioDuration: 2)

    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.text, "usable")
    XCTAssertTrue(LocalClipTranscriptValidator.hasUsableSegments(result, audioDuration: 2))
  }

  func testVideoValidatorRejectsPlayableAudioOnlyMOV() async throws {
    let fixture = try ClipArtifactFixture()
    defer { fixture.remove() }
    try await fixture.writeAudioOnlyMovie()

    let failure = await LocalClipVideoValidator.failureReason(for: fixture.videoURL)

    XCTAssertTrue(failure?.contains("without a usable video track") == true)
  }

  @MainActor
  func testFailedAncillaryWriteCannotPublishReadyOrCommitReadyManifest() throws {
    let fixture = try ClipArtifactFixture()
    defer { fixture.remove() }
    let layout = LocalClipFileLayout(baseDirectory: fixture.directoryURL)
    let store = LocalClipStore(fileLayout: layout)
    var clip = fixture.manifest(status: .processing)
    try store.save(clip)
    let transcriptURL = layout.transcriptURL(for: clip.id)
    try FileManager.default.removeItem(at: transcriptURL)
    try FileManager.default.createDirectory(at: transcriptURL, withIntermediateDirectories: false)

    clip.status = .ready
    XCTAssertThrowsError(try store.save(clip))
    XCTAssertEqual(store.loadClips().first?.status, .processing)

    let emptyLayout = LocalClipFileLayout(
      baseDirectory: fixture.directoryURL.appendingPathComponent("ui", isDirectory: true)
    )
    try emptyLayout.ensureDirectories(for: clip.id)
    try FileManager.default.createDirectory(
      at: emptyLayout.transcriptURL(for: clip.id),
      withIntermediateDirectories: false
    )
    let model = LocalClipViewModel(
      store: LocalClipStore(fileLayout: emptyLayout),
      clipFileLayout: emptyLayout
    )

    XCTAssertFalse(model.persistAndPublish(clip))
    XCTAssertEqual(model.clips.first?.status, .failed)
    XCTAssertFalse(model.canCopyAgentPrompt(for: clip.id))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: emptyLayout.manifestURL(for: clip.id).path))
  }
}

private final class ClipArtifactFixture {
  let directoryURL: URL
  let audioURL: URL
  let videoURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    audioURL = directoryURL.appendingPathComponent("clip.wav")
    videoURL = directoryURL.appendingPathComponent("audio-only.mov")
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  }

  func writeAudioOnlyMovie() async throws {
    let writer = try LocalMeetingWaveFileWriter(fileURL: audioURL)
    try writer.append(samples: [Int16](repeating: 64, count: 16_000))
    try writer.close()

    let audioAsset = AVURLAsset(url: audioURL)
    let duration = try await audioAsset.load(.duration)
    guard let sourceTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
      throw FixtureError.missingAudioTrack
    }
    let composition = AVMutableComposition()
    guard
      let destinationTrack = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      throw FixtureError.compositionTrackCreationFailed
    }
    try destinationTrack.insertTimeRange(
      CMTimeRange(start: .zero, duration: duration),
      of: sourceTrack,
      at: .zero
    )
    guard
      let exporter = AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetPassthrough
      )
    else {
      throw FixtureError.exporterCreationFailed
    }
    exporter.outputURL = videoURL
    exporter.outputFileType = .mov
    await withCheckedContinuation { continuation in
      exporter.exportAsynchronously { continuation.resume() }
    }
    guard exporter.status == .completed else {
      throw exporter.error ?? FixtureError.exportFailed
    }
  }

  func manifest(status: LocalClipStatus) -> LocalClipManifest {
    LocalClipManifest(
      id: UUID(),
      title: "Persistence fixture",
      startedAt: Date(),
      endedAt: Date(),
      status: status,
      intent: nil,
      videoFileName: "clip-video.mov",
      audioFileName: "clip-audio.wav",
      transcriptFileName: "transcript.json",
      notesFileName: "notes.md",
      transcriptSegments: [],
      postNotes: "",
      errorMessage: nil
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

private enum FixtureError: Error {
  case missingAudioTrack
  case compositionTrackCreationFailed
  case exporterCreationFailed
  case exportFailed
}
