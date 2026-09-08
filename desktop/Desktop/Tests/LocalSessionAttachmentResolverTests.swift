import Darwin
import Foundation
import XCTest

@testable import CepessaSessions

final class LocalSessionAttachmentResolverTests: XCTestCase {
  private var testRoot: URL!

  override func setUpWithError() throws {
    testRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent(
        "LocalSessionAttachmentResolverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let testRoot {
      try? FileManager.default.removeItem(at: testRoot)
    }
    testRoot = nil
  }

  func testResolvesRegularFileFromUppercaseAttachmentsDirectory() throws {
    let sessionFolder = try makeSessionFolder()
    let file = try write("upper", named: "frame.png", in: sessionFolder, directory: "Attachments")
    let attachment = makeAttachment(fileName: "frame.png", urlString: "/old/package/frame.png")

    let resolved = try XCTUnwrap(
      LocalSessionAttachmentResolver.localURL(for: attachment, in: sessionFolder))
    XCTAssertEqual(try Data(contentsOf: resolved), try Data(contentsOf: file))
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: resolved.path)[.systemFileNumber]
        as? NSNumber,
      try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)
  }

  func testResolvesHistoricalLowercaseAttachmentsDirectory() throws {
    let sessionFolder = try makeSessionFolder()
    let file = try write("lower", named: "notes.txt", in: sessionFolder, directory: "attachments")
    let attachment = makeAttachment(fileName: "notes.txt", urlString: nil)

    let resolved = try XCTUnwrap(
      LocalSessionAttachmentResolver.localURL(for: attachment, in: sessionFolder))
    XCTAssertEqual(try Data(contentsOf: resolved), try Data(contentsOf: file))
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: resolved.path)[.systemFileNumber]
        as? NSNumber,
      try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)
  }

  func testRelocatedPackageUsesSafeBasenameFromHistoricalURL() throws {
    let sessionFolder = try makeSessionFolder()
    let file = try write("relocated", named: "capture.png", in: sessionFolder)
    let attachment = makeAttachment(
      fileName: nil,
      urlString: "/previous/library/session/Attachments/capture.png"
    )

    XCTAssertEqual(
      LocalSessionAttachmentResolver.localURL(for: attachment, in: sessionFolder),
      file
    )
  }

  func testRejectsAttachmentDirectorySymlinkWithoutReadingOutsideFile() throws {
    let sessionFolder = try makeSessionFolder(createAttachments: false)
    let outsideDirectory = testRoot.appendingPathComponent("outside-parent", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    let outsideFile = outsideDirectory.appendingPathComponent("secret.txt")
    let original = Data("outside-parent".utf8)
    try original.write(to: outsideFile)
    try FileManager.default.createSymbolicLink(
      at: sessionFolder.appendingPathComponent("Attachments", isDirectory: true),
      withDestinationURL: outsideDirectory
    )

    XCTAssertNil(
      LocalSessionAttachmentResolver.localURL(
        for: makeAttachment(fileName: "secret.txt", urlString: outsideFile.path),
        in: sessionFolder
      )
    )
    XCTAssertEqual(try Data(contentsOf: outsideFile), original)
  }

  func testRejectsSessionFolderSymlinkWithoutReadingOutsideFile() throws {
    let realSessionFolder = try makeSessionFolder()
    let outsideFile = try write("linked-session", named: "secret.txt", in: realSessionFolder)
    let original = try Data(contentsOf: outsideFile)
    let linkedSessionFolder = testRoot.appendingPathComponent("linked-session", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: linkedSessionFolder,
      withDestinationURL: realSessionFolder
    )

    XCTAssertNil(
      LocalSessionAttachmentResolver.localURL(
        for: makeAttachment(fileName: "secret.txt", urlString: outsideFile.path),
        in: linkedSessionFolder
      )
    )
    XCTAssertEqual(try Data(contentsOf: outsideFile), original)
  }

  func testRejectsLeafSymlinkWithoutReadingOutsideFile() throws {
    let sessionFolder = try makeSessionFolder()
    let outsideFile = testRoot.appendingPathComponent("outside-leaf.txt")
    let original = Data("outside-leaf".utf8)
    try original.write(to: outsideFile)
    let linkedFile = sessionFolder.appendingPathComponent("Attachments/secret.txt")
    try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: outsideFile)

    XCTAssertNil(
      LocalSessionAttachmentResolver.localURL(
        for: makeAttachment(fileName: "secret.txt", urlString: outsideFile.path),
        in: sessionFolder
      )
    )
    XCTAssertEqual(try Data(contentsOf: outsideFile), original)
  }

  func testRejectsHardLinkedLeafWithoutChangingOutsideFile() throws {
    let sessionFolder = try makeSessionFolder()
    let outsideFile = testRoot.appendingPathComponent("outside-hardlink.txt")
    let original = Data("outside-hardlink".utf8)
    try original.write(to: outsideFile)
    let linkedFile = sessionFolder.appendingPathComponent("Attachments/secret.txt")
    XCTAssertEqual(link(outsideFile.path, linkedFile.path), 0)

    XCTAssertNil(
      LocalSessionAttachmentResolver.localURL(
        for: makeAttachment(fileName: "secret.txt", urlString: outsideFile.path),
        in: sessionFolder
      )
    )
    XCTAssertEqual(try Data(contentsOf: outsideFile), original)
  }

  func testRejectsOutsideAbsolutePathWithoutChangingOutsideFile() throws {
    let sessionFolder = try makeSessionFolder()
    let outsideFile = testRoot.appendingPathComponent("outside-only.txt")
    let original = Data("outside-only".utf8)
    try original.write(to: outsideFile)
    let attachment = makeAttachment(fileName: nil, urlString: outsideFile.path)

    XCTAssertNil(LocalSessionAttachmentResolver.localURL(for: attachment, in: sessionFolder))
    XCTAssertEqual(try Data(contentsOf: outsideFile), original)
  }

  func testRejectsParentTraversalFileNameAndURLWithoutChangingOutsideFile() throws {
    let sessionFolder = try makeSessionFolder()
    let outsideFile = sessionFolder.appendingPathComponent("outside.txt")
    let original = Data("dotdot".utf8)
    try original.write(to: outsideFile)

    XCTAssertNil(
      LocalSessionAttachmentResolver.localURL(
        for: makeAttachment(fileName: "../outside.txt", urlString: outsideFile.path),
        in: sessionFolder
      )
    )
    XCTAssertNil(
      LocalSessionAttachmentResolver.localURL(
        for: makeAttachment(fileName: nil, urlString: "file:///old/../outside.txt"),
        in: sessionFolder
      )
    )
    XCTAssertEqual(try Data(contentsOf: outsideFile), original)
  }

  private func makeSessionFolder(createAttachments: Bool = true) throws -> URL {
    let sessionFolder = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
    if createAttachments {
      try FileManager.default.createDirectory(
        at: sessionFolder.appendingPathComponent("Attachments", isDirectory: true),
        withIntermediateDirectories: false
      )
    }
    return sessionFolder
  }

  private func write(
    _ text: String,
    named fileName: String,
    in sessionFolder: URL,
    directory: String = "Attachments"
  ) throws -> URL {
    let directoryURL = sessionFolder.appendingPathComponent(directory, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let fileURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
    try Data(text.utf8).write(to: fileURL)
    return fileURL
  }

  private func makeAttachment(fileName: String?, urlString: String?) -> LocalSessionAttachment {
    LocalSessionAttachment(
      id: UUID(),
      kind: .file,
      source: .imported,
      title: "Attachment",
      timestamp: Date(timeIntervalSince1970: 1_700_100_000),
      sessionOffset: 0,
      fileName: fileName,
      mimeType: "application/octet-stream",
      urlString: urlString,
      note: nil
    )
  }
}
