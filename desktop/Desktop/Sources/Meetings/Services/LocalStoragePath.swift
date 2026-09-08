import Foundation

/// Preserve real path components during no-follow validation. Foundation's
/// standardization can rewrite /private/var and /private/tmp back to their aliases.
enum LocalStoragePath {
  static func checkedFileURL(_ url: URL) -> URL? {
    guard url.isFileURL else { return nil }
    var components = url.pathComponents
    guard components.first == "/",
      !components.contains(where: { $0 == "." || $0 == ".." || $0.contains("\0") })
    else { return nil }

    // Only the three root-level macOS aliases are recognized. Never resolve a
    // link inside user data, a package, or a caller-selected storage directory.
    if components.count > 1, ["var", "tmp", "etc"].contains(components[1]) {
      let alias = components[1]
      let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: "/\(alias)")
      if destination == "private/\(alias)" || destination == "/private/\(alias)" {
        components.insert("private", at: 1)
      }
    }
    return URL(
      fileURLWithPath: "/" + components.dropFirst().joined(separator: "/"),
      isDirectory: url.hasDirectoryPath)
  }
}
