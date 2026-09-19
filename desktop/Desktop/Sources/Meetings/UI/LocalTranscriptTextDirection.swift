import Foundation

/// A foreign name at the start of a transcript must not reverse the sentence.
/// Isolates affect presentation only; stored text and exports retain source bytes.
enum LocalTranscriptTextDirection {
  static func isRightToLeft(_ text: String) -> Bool {
    var rtlLetters = 0
    var otherLetters = 0
    for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
      switch scalar.value {
      case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
        rtlLetters += 1
      default:
        otherLetters += 1
      }
    }
    return rtlLetters > otherLetters
  }

  static func displayText(_ text: String) -> String {
    text.components(separatedBy: "\n").map { paragraph in
      guard !paragraph.isEmpty else { return paragraph }
      return "\(isRightToLeft(paragraph) ? "\u{2067}" : "\u{2066}")\(paragraph)\u{2069}"
    }.joined(separator: "\n")
  }
}
