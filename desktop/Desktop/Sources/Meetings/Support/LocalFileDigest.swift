import CryptoKit
import Foundation

enum LocalFileDigest {
  /// SHA-256 of a file, streamed in 1 MB chunks. Each chunk is released before
  /// the next one is read: without the pool, hashing the 1.6 GB speech model
  /// kept every chunk alive and the app's footprint grew by the file's size.
  static func sha256(of url: URL, checkingCancellation: Bool = false) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var finished = false
    while !finished {
      if checkingCancellation { try Task.checkCancellation() }
      finished = try autoreleasepool {
        guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else {
          return true
        }
        hasher.update(data: chunk)
        return false
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
