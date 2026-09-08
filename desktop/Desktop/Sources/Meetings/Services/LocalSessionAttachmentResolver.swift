import Darwin
import Foundation

enum LocalSessionAttachmentResolver {
  static func localURL(
    for attachment: LocalSessionAttachment,
    in sessionFolderURL: URL?
  ) -> URL? {
    guard let sessionFolderURL,
      let fileName = safeFileName(for: attachment)
    else {
      return nil
    }

    let sessionFolder = sessionFolderURL
    guard sessionFolder.isFileURL,
      isUnlinkedDirectoryTree(sessionFolder)
    else {
      return nil
    }

    for directoryName in ["Attachments", "attachments"] {
      let directory = sessionFolder.appendingPathComponent(directoryName, isDirectory: true)
      guard isDirectory(directory) else { continue }

      let candidate = directory.appendingPathComponent(fileName, isDirectory: false)
      if isUnlinkedRegularFile(candidate) {
        return candidate
      }
    }

    return nil
  }

  private static func safeFileName(for attachment: LocalSessionAttachment) -> String? {
    if let fileName = attachment.fileName {
      return isSafeFileName(fileName) ? fileName : nil
    }

    guard let urlString = attachment.urlString,
      !containsParentTraversal(urlString)
    else {
      return nil
    }

    let sourceURL: URL?
    if urlString.hasPrefix("/") {
      sourceURL = URL(fileURLWithPath: urlString, isDirectory: false)
    } else if let parsedURL = URL(string: urlString), parsedURL.isFileURL {
      sourceURL = parsedURL
    } else {
      sourceURL = nil
    }

    guard let sourceURL,
      !sourceURL.pathComponents.contains("..")
    else {
      return nil
    }

    let fileName = sourceURL.lastPathComponent
    return isSafeFileName(fileName) ? fileName : nil
  }

  private static func isSafeFileName(_ fileName: String) -> Bool {
    guard !fileName.isEmpty,
      fileName != ".",
      fileName != "..",
      !fileName.contains("/"),
      !fileName.contains("\0")
    else {
      return false
    }
    return URL(fileURLWithPath: fileName).lastPathComponent == fileName
  }

  private static func containsParentTraversal(_ path: String) -> Bool {
    path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }

  private static func isUnlinkedDirectoryTree(_ url: URL) -> Bool {
    guard let checkedURL = LocalStoragePath.checkedFileURL(url) else { return false }
    let components = checkedURL.pathComponents
    guard components.first == "/" else { return false }

    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in components.dropFirst() {
      current.appendPathComponent(component, isDirectory: true)
      guard isDirectory(current) else { return false }
    }
    return true
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0
      && (status.st_mode & S_IFMT) == S_IFDIR
  }

  private static func isUnlinkedRegularFile(_ url: URL) -> Bool {
    var pathStatus = stat()
    guard lstat(url.path, &pathStatus) == 0,
      (pathStatus.st_mode & S_IFMT) == S_IFREG,
      pathStatus.st_nlink == 1
    else {
      return false
    }

    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }

    var openedStatus = stat()
    guard fstat(descriptor, &openedStatus) == 0,
      (openedStatus.st_mode & S_IFMT) == S_IFREG,
      openedStatus.st_nlink == 1,
      sameFile(pathStatus, openedStatus)
    else {
      return false
    }

    var finalStatus = stat()
    return lstat(url.path, &finalStatus) == 0
      && (finalStatus.st_mode & S_IFMT) == S_IFREG
      && finalStatus.st_nlink == 1
      && sameFile(openedStatus, finalStatus)
  }

  private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }
}
