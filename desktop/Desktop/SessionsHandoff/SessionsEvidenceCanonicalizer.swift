import CryptoKit
import Foundation

/// The one definition of how meeting evidence is hashed.
///
/// Sessions writes evidence with this canonicalizer and every consumer
/// (Cepessa, through `SessionsOutboxReader`) verifies with the same rules, so
/// a hash means the same bytes on both sides of the handoff.
///
/// Canonical form: the envelope's JSON object without `contentHash`, keys
/// sorted, slashes unescaped, and every number rewritten as a decimal string
/// in bounded micro-units (see `canonicalNumberString`).
public enum SessionsEvidenceCanonicalizer {
  /// JSON numbers in meeting evidence are deliberately bounded so quantization
  /// remains exactly representable as an Int64 in every supported consumer.
  public static let numericScale: Int64 = 1_000_000
  public static let maximumCanonicalNumber = 1_000_000_000.0

  /// Canonical bytes of an already-decoded JSON value.
  public static func canonicalData(jsonValue: Any) throws -> Data {
    let normalized = try normalizedJSONValue(jsonValue)
    return try JSONSerialization.data(
      withJSONObject: normalized,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  /// Canonical bytes of a stored envelope: the object minus its own hash.
  public static func canonicalData(envelopeData: Data) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any] else {
      throw CocoaError(.coderReadCorrupt)
    }
    guard object.removeValue(forKey: "contentHash") != nil else {
      throw CocoaError(.coderValueNotFound)
    }
    return try canonicalData(jsonValue: object)
  }

  public static func contentHash(envelopeData: Data) throws -> String {
    try contentHash(canonicalData: canonicalData(envelopeData: envelopeData))
  }

  public static func contentHash(canonicalData: Data) -> String {
    SHA256.hash(data: canonicalData).map { String(format: "%02x", $0) }.joined()
  }

  /// Canonicalizes every evidence number using integer micro-units:
  /// `q = floor(value * 1_000_000 + 0.5)`.
  ///
  /// This intentionally avoids language- and libc-dependent decimal formatter
  /// rounding. Evidence numbers are nonnegative and bounded before hashing.
  public static func canonicalNumberString(_ value: Double) throws -> String {
    guard value.isFinite, value >= 0, value <= maximumCanonicalNumber else {
      throw CocoaError(.coderInvalidValue)
    }

    let quantized = Int64(floor(value * Double(numericScale) + 0.5))
    let whole = quantized / numericScale
    let remainder = quantized % numericScale
    guard remainder != 0 else {
      return String(whole)
    }

    var fraction = String(remainder)
    fraction = String(repeating: "0", count: 6 - fraction.count) + fraction
    while fraction.last == "0" {
      fraction.removeLast()
    }
    return "\(whole).\(fraction)"
  }

  private static func normalizedJSONValue(_ value: Any) throws -> Any {
    if value is NSNull || value is String {
      return value
    }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue
      }
      return try canonicalNumberString(number.doubleValue)
    }
    if let boolean = value as? Bool {
      return boolean
    }
    if let array = value as? [Any] {
      return try array.map(normalizedJSONValue)
    }
    if let dictionary = value as? [String: Any] {
      return try dictionary.mapValues(normalizedJSONValue)
    }
    throw CocoaError(.coderInvalidValue)
  }
}
