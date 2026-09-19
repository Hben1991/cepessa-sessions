import Darwin
import Foundation

enum LocalSessionInsightStoreError: LocalizedError, Equatable {
  case unsafeLock(URL)
  case lockTimeout(URL)
  case unsafeFile(URL)
  case malformed(URL)

  var errorDescription: String? {
    switch self {
    case .unsafeLock:
      return "The insight lock is unavailable or unsafe."
    case .lockTimeout:
      return "Another process is saving this analysis. Try again."
    case .unsafeFile:
      return "The insight file is unavailable or unsafe."
    case .malformed:
      return "The saved analysis file is malformed."
    }
  }
}

struct LocalSessionInsightStore {
  private let fileLayout: LocalSessionFileLayout
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(fileLayout: LocalSessionFileLayout, fileManager: FileManager = .default) {
    self.fileLayout = fileLayout
    self.fileManager = fileManager
    self.encoder = LocalSessionInsightJSON.encoder
    self.decoder = LocalSessionInsightJSON.decoder
  }

  func load(sessionID: UUID) throws -> LocalSessionInsightRecord? {
    let url = fileLayout.insightsURL(for: sessionID)
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
      if errno == ENOENT { return nil }
      throw LocalSessionInsightStoreError.unsafeFile(url)
    }
    guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
      throw LocalSessionInsightStoreError.unsafeFile(url)
    }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw LocalSessionInsightStoreError.unsafeFile(url) }
    defer { close(descriptor) }
    let data = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readDataToEndOfFile()
    do {
      var record = try decoder.decode(LocalSessionInsightRecord.self, from: data)
      if record.status == .running {
        record.status = .failed
        record.failureCategory = .interrupted
        record.failureMessage = "Analysis was interrupted before it finished."
      }
      return record
    } catch {
      throw LocalSessionInsightStoreError.malformed(url)
    }
  }

  func loadLenient(sessionID: UUID) -> (
    record: LocalSessionInsightRecord?, malformed: Bool
  ) {
    do {
      return (try load(sessionID: sessionID), false)
    } catch LocalSessionInsightStoreError.malformed {
      return (nil, true)
    } catch {
      return (nil, false)
    }
  }

  @discardableResult
  func save(_ record: LocalSessionInsightRecord) throws -> LocalSessionInsightRecord {
    try fileLayout.ensureDirectories(fileManager: fileManager, for: record.sessionID)
    let url = fileLayout.insightsURL(for: record.sessionID)
    return try withLock(sessionID: record.sessionID) {
      let data = try encoder.encode(record)
      try data.write(to: url, options: .atomic)
      return record
    }
  }

  private func withLock<T>(sessionID: UUID, _ body: () throws -> T) throws -> T {
    let directory = fileLayout.sessionDirectory(for: sessionID)
    let lockURL = directory.appendingPathComponent(".insights.lock", isDirectory: false)
    let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
    let descriptor = open(lockURL.path, flags, mode_t(0o600))
    guard descriptor >= 0 else { throw LocalSessionInsightStoreError.unsafeLock(lockURL) }
    defer { close(descriptor) }

    var lockStatus = stat()
    guard fstat(descriptor, &lockStatus) == 0,
      (lockStatus.st_mode & S_IFMT) == S_IFREG,
      lockStatus.st_nlink == 1
    else {
      throw LocalSessionInsightStoreError.unsafeLock(lockURL)
    }

    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let errorNumber = errno
      guard errorNumber == EAGAIN || errorNumber == EWOULDBLOCK else {
        throw LocalSessionInsightStoreError.unsafeLock(lockURL)
      }
      guard DispatchTime.now().uptimeNanoseconds < deadline else {
        throw LocalSessionInsightStoreError.lockTimeout(lockURL)
      }
      usleep(10_000)
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
  }
}
