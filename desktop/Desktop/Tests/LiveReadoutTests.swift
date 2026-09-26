import Combine
import XCTest

@testable import CepessaSessions

final class LiveReadoutTests: XCTestCase {
  private final class Owner: ObservableObject {
    @LiveReadout var level: Double = 0
    @Published var title = ""
  }

  func testATickReachesSubscribersWithoutInvalidatingObservers() {
    let owner = Owner()
    var invalidations = 0
    var delivered: [Double] = []
    let observing = owner.objectWillChange.sink { invalidations += 1 }
    let listening = owner.$level.sink { delivered.append($0) }

    owner.level = 0.4
    owner.level = 0.7

    XCTAssertEqual(invalidations, 0)
    XCTAssertEqual(delivered, [0, 0.4, 0.7])
    XCTAssertEqual(owner.level, 0.7)

    owner.title = "changed"
    XCTAssertEqual(invalidations, 1, "ordinary published state still invalidates")
    _ = (observing, listening)
  }
}
