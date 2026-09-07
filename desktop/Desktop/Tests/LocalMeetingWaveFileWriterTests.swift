import Foundation
import XCTest

@testable import CepessaSessions

final class LocalMeetingWaveFileWriterTests: XCTestCase {
  func testHeaderIsValidBeforeCloseAndTracksEveryCompletedAppend() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let writer = try LocalMeetingWaveFileWriter(fileURL: fixture.fileURL)

    XCTAssertEqual(try waveSizes(at: fixture.fileURL), WaveSizes(riff: 36, data: 0))

    try writer.append(pcm16Data: Data([0x01, 0x00, 0x02, 0x00]))
    XCTAssertEqual(try waveSizes(at: fixture.fileURL), WaveSizes(riff: 40, data: 4))

    try writer.append(pcm16Data: Data([0x03, 0x00]))
    XCTAssertEqual(try waveSizes(at: fixture.fileURL), WaveSizes(riff: 42, data: 6))
  }

  func testCloseFinalizesAndIsIdempotent() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let writer = try LocalMeetingWaveFileWriter(fileURL: fixture.fileURL)
    try writer.append(samples: [1, -1, 2])

    try writer.close()
    try writer.close()

    XCTAssertEqual(try waveSizes(at: fixture.fileURL), WaveSizes(riff: 42, data: 6))
    XCTAssertEqual(try Data(contentsOf: fixture.fileURL).count, 50)
  }

  private func waveSizes(at url: URL) throws -> WaveSizes {
    let data = try Data(contentsOf: url)
    XCTAssertGreaterThanOrEqual(data.count, 44)
    XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
    XCTAssertEqual(data[8..<12], Data("WAVE".utf8))
    XCTAssertEqual(data[36..<40], Data("data".utf8))
    return WaveSizes(
      riff: data[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian },
      data: data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    )
  }
}

private struct WaveSizes: Equatable {
  let riff: UInt32
  let data: UInt32
}

private final class Fixture {
  let directoryURL: URL
  let fileURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    fileURL = directoryURL.appendingPathComponent("capture.wav")
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
