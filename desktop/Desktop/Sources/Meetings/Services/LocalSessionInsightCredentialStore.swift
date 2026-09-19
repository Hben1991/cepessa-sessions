import Foundation
import Security

struct LocalSessionInsightCredentialStore: Sendable {
  var service: String
  var account: String

  init(
    service: String? = nil,
    account: String = "api-key"
  ) {
    self.service =
      service
      ?? "\((Bundle.main.bundleIdentifier ?? "me.cepessa.sessions")).typesafe"
    self.account = account
  }

  func load() throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
      throw CocoaError(.fileReadNoPermission)
    }
    guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
      return nil
    }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func save(_ key: String) throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    try delete()
    guard !trimmed.isEmpty else { return }
    guard let data = trimmed.data(using: .utf8) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw CocoaError(.fileWriteNoPermission)
    }
  }

  func delete() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CocoaError(.fileWriteNoPermission)
    }
  }
}

struct LocalSessionInsightEnvironmentCredentialStore: Sendable {
  static func load(
    processInfo: ProcessInfo = .processInfo
  ) -> String? {
    let key =
      processInfo.environment["TYPESAFE_API_KEY"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let key, !key.isEmpty else { return nil }
    return key
  }
}

struct LocalSessionInsightMemoryCredentialStore: Sendable {
  private let box: Box

  init(key: String? = nil) {
    box = Box(key: key)
  }

  func load() -> String? { box.key }

  func save(_ key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    box.key = trimmed.isEmpty ? nil : trimmed
  }

  func delete() { box.key = nil }

  private final class Box: @unchecked Sendable {
    var key: String?
    init(key: String?) { self.key = key }
  }
}
