import Foundation
import XCTest

@testable import CepessaSessions

final class LocalStoragePathTests: XCTestCase {
  func testMacOSTemporaryAliasesAllowRealSessionAndAttachmentFiles() throws {
    for parent in [
      URL(fileURLWithPath: "/tmp", isDirectory: true), FileManager.default.temporaryDirectory,
    ] {
      let root = parent.appendingPathComponent(
        "StorageAlias-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let layout = LocalSessionFileLayout(baseDirectory: root)
      let sessionID = UUID()
      try layout.ensureDirectories(for: sessionID)
      try LocalClipFileSafety.validateDirectoryChain(to: root, allowMissingTail: false)

      let audio = layout.importedAudioURL(for: sessionID)
      let writer = try LocalMeetingWaveFileWriter(fileURL: audio)
      try writer.append(samples: [1, 2, 3])
      try writer.close()
      XCTAssertEqual(layout.validatedAudioURL(for: audio), audio)

      let attachmentURL = layout.attachmentsDirectory(for: sessionID).appendingPathComponent(
        "note.txt")
      try Data("Saved local context".utf8).write(to: attachmentURL)
      let attachment = LocalSessionAttachment(
        id: UUID(), kind: .file, source: .imported, title: "Local note", timestamp: Date(),
        sessionOffset: nil, fileName: "note.txt", mimeType: "text/plain",
        urlString: attachmentURL.path, note: nil)
      XCTAssertEqual(
        LocalSessionAttachmentResolver.localURL(
          for: attachment, in: layout.sessionDirectory(for: sessionID)),
        attachmentURL)
    }
  }

  func testTraversalCannotBecomeAnAcceptedAudioPathAfterNormalization() throws {
    let url = try XCTUnwrap(URL(string: "file:///private/tmp/storage/redirect/../imported.wav"))
    XCTAssertNil(LocalStoragePath.checkedFileURL(url))
  }
}
