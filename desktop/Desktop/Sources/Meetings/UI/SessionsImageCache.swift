import AppKit

/// Pinned screenshots, read from disk once per file version.
///
/// The reader and the attachments strip ask for an image every time their
/// body runs; without this each redraw re-read and re-decoded every pinned
/// screenshot. The key includes the file's modification date and size, so a
/// replaced file is read again.
enum SessionsImageCache {
  nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 64
    return cache
  }()

  static func image(at url: URL) -> NSImage? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let modified = attributes[.modificationDate] as? Date
    else { return nil }
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
    let key = "\(url.path)|\(modified.timeIntervalSinceReferenceDate)|\(size)" as NSString
    if let image = cache.object(forKey: key) { return image }
    guard let image = NSImage(contentsOf: url) else { return nil }
    cache.setObject(image, forKey: key)
    return image
  }
}
