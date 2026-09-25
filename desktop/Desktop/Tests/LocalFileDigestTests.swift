import CryptoKit
import Darwin
import XCTest

@testable import CepessaSessions

final class LocalFileDigestTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalFileDigestTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  func testDigestMatchesOneShotHash() throws {
    let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let url = directory.appendingPathComponent("sample.bin")
    try bytes.write(to: url)

    let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(try LocalFileDigest.sha256(of: url), expected)
  }

  func testDigestOfEmptyFile() throws {
    let url = directory.appendingPathComponent("empty.bin")
    try Data().write(to: url)
    XCTAssertEqual(
      try LocalFileDigest.sha256(of: url),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  }

  /// Hashing the 1.6 GB speech model once grew the installed app to 1.5 GB,
  /// because every chunk stayed alive until the loop returned. A 256 MB file
  /// must now hash with a footprint that does not follow the file's size.
  func testDigestFootprintDoesNotGrowWithFileSize() throws {
    let url = directory.appendingPathComponent("large.bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let writer = try FileHandle(forWritingTo: url)
    let block = Data(repeating: 0xA5, count: 1_048_576)
    for _ in 0..<256 { writer.write(block) }
    try writer.close()

    let before = try XCTUnwrap(physicalFootprint())
    _ = try LocalFileDigest.sha256(of: url)
    let after = try XCTUnwrap(physicalFootprint())

    let growth = after > before ? after - before : 0
    XCTAssertLessThan(growth, 64 * 1_048_576, "footprint grew \(growth / 1_048_576) MB")
  }

  func testCancellationStopsHashing() async throws {
    let url = directory.appendingPathComponent("cancel.bin")
    try Data(repeating: 1, count: 4 * 1_048_576).write(to: url)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try LocalFileDigest.sha256(of: url, checkingCancellation: true)
    }
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {}
  }

  private func physicalFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
  }
}
