import XCTest

@testable import CepessaSessions

final class CepessaSessionFloatingBarPreferencesTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suiteName = "CepessaSessionFloatingBarPreferencesTests"

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func testFreshInstallsShowTheFloatingRecordingBarByDefault() {
    CepessaSessionFloatingBarPreferences.installDefaults(in: defaults)

    XCTAssertTrue(defaults.bool(forKey: CepessaSessionFloatingBarPreferences.enabledKey))
    XCTAssertTrue(
      defaults.bool(forKey: CepessaSessionFloatingBarPreferences.defaultOnMigrationKey))
  }

  func testExistingDefaultOffInstallsAreMovedBackToRecordingBarOn() {
    defaults.set(false, forKey: CepessaSessionFloatingBarPreferences.enabledKey)
    defaults.set(true, forKey: CepessaSessionFloatingBarPreferences.legacyDefaultOffMigrationKey)

    CepessaSessionFloatingBarPreferences.installDefaults(in: defaults)

    XCTAssertTrue(defaults.bool(forKey: CepessaSessionFloatingBarPreferences.enabledKey))
    XCTAssertTrue(
      defaults.bool(forKey: CepessaSessionFloatingBarPreferences.defaultOnMigrationKey))
  }

  func testManualDisableSurvivesAfterTheDefaultOnMigrationHasRun() {
    CepessaSessionFloatingBarPreferences.installDefaults(in: defaults)
    defaults.set(false, forKey: CepessaSessionFloatingBarPreferences.enabledKey)

    CepessaSessionFloatingBarPreferences.installDefaults(in: defaults)

    XCTAssertFalse(defaults.bool(forKey: CepessaSessionFloatingBarPreferences.enabledKey))
  }
}
