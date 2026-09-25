import AppKit
import XCTest

@testable import CepessaSessions

/// End-to-end cover for the floating panel's window lifecycle.
///
/// These exist because of a regression pure geometry could not see: the
/// recorder changed shape correctly and then stopped being present at all —
/// alive process, preference still on, nothing on screen and nothing under an
/// accessibility hit test. Every invariant below is a property the panel has
/// to hold *after the animation has finished*.
@MainActor
final class CepessaSessionFloatingPanelLifecycleTests: XCTestCase {

  private var temporaryRoot: URL?

  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  override func tearDown() {
    if let temporaryRoot {
      try? FileManager.default.removeItem(at: temporaryRoot)
    }
    temporaryRoot = nil
    UserDefaults.standard.removeObject(forKey: "CepessaSessionsCapsuleAnchor")
    super.tearDown()
  }

  // MARK: - Helpers

  private func makeConnectedController() throws -> CepessaSessionFloatingBarController {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("floating-panel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    temporaryRoot = root

    let layout = LocalSessionFileLayout(baseDirectory: root)
    let model = LocalMeetingAppModel(
      store: LocalSessionStore(fileLayout: layout), fileLayout: layout)

    UserDefaults.standard.set(true, forKey: CepessaSessionFloatingBarPreferences.enabledKey)

    let controller = CepessaSessionFloatingBarController()
    controller.connect(model: model)
    pump(1.0)
    return controller
  }

  /// Runs the real run loop so SwiftUI animations and their completions
  /// actually progress.
  private func pump(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  private var restingSize: CGSize {
    CepessaSessionCapsuleMetrics.contentSize(for: .init(phase: .idle))
  }

  private var noticeSize: CGSize {
    CepessaSessionCapsuleMetrics.contentSize(for: .init(phase: .idle, hasNotice: true))
  }

  private func assertRestingAndPresent(
    _ controller: CepessaSessionFloatingBarController,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let panel = controller.currentPanel else {
      return XCTFail("\(message): the panel is gone entirely", file: file, line: line)
    }

    XCTAssertTrue(panel.isVisible, "\(message): panel is not on screen", file: file, line: line)
    XCTAssertEqual(panel.alphaValue, 1, "\(message): panel is transparent", file: file, line: line)
    XCTAssertEqual(
      panel.frame.size, CepessaSessionCapsuleMetrics.panelSize(for: restingSize),
      "\(message): panel was left on the wrong footprint", file: file, line: line)
    XCTAssertFalse(
      controller.state.isTransitioning, "\(message): the transition never ended",
      file: file, line: line)
    XCTAssertEqual(
      controller.state.barContentSize, restingSize,
      "\(message): the capsule is not back at rest", file: file, line: line)

    let container = panel.contentView as? CepessaFloatingPanelContainerView
    let rect = container?.interactiveRect ?? .zero
    XCTAssertEqual(
      rect.size, restingSize, "\(message): the live area does not match the capsule",
      file: file, line: line)
    XCTAssertTrue(
      rect.contains(CGPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)),
      "\(message): the centre of the panel is not live", file: file, line: line)
  }

  // MARK: - The regression

  func testRecorderSurvivesAnOpenCloseCycle() throws {
    let controller = try makeConnectedController()
    assertRestingAndPresent(controller, "before anything changed")

    controller.presentNotice("Screen pinned at 04:07", style: .success)
    pump(2.0)
    XCTAssertEqual(
      controller.currentPanel?.frame.size,
      CepessaSessionCapsuleMetrics.panelSize(for: noticeSize),
      "a notice should size the panel to the notice footprint")

    controller.dismissNotice()
    pump(2.0)
    assertRestingAndPresent(controller, "after the notice left")
  }

  func testRepeatedCyclesAlwaysLandAtRest() throws {
    let controller = try makeConnectedController()

    for cycle in 1...3 {
      controller.presentNotice("File pinned at 00:1\(cycle)", style: .success)
      pump(0.9)
      controller.dismissNotice()
      pump(2.0)
      assertRestingAndPresent(controller, "after cycle \(cycle)")
    }
  }

  /// Reopening while the capsule is closing must not leave the superseded
  /// settle to shrink the panel underneath the open shape.
  func testReopeningDuringACollapseIsNotUndoneByTheOldTransition() throws {
    let controller = try makeConnectedController()

    controller.presentNotice("First", style: .neutral)
    pump(0.9)
    controller.dismissNotice()
    pump(0.1)
    controller.presentNotice("Second", style: .neutral)
    pump(2.0)

    XCTAssertTrue(controller.state.hasNotice)
    XCTAssertFalse(controller.state.isTransitioning)
    XCTAssertEqual(
      controller.currentPanel?.frame.size,
      CepessaSessionCapsuleMetrics.panelSize(for: noticeSize),
      "a stale settle shrank the panel under an open capsule")
  }

  func testTheRecorderKeepsItsPlaceWhileItChangesShape() throws {
    let controller = try makeConnectedController()
    let panel = try XCTUnwrap(controller.currentPanel)
    let anchor = CepessaSessionCapsuleMetrics.anchor(ofPanelFrame: panel.frame)

    controller.presentNotice("Region pinned at 01:00", style: .success)
    pump(2.0)
    XCTAssertEqual(
      CepessaSessionCapsuleMetrics.anchor(ofPanelFrame: panel.frame).x, anchor.x, accuracy: 1)
    XCTAssertEqual(
      CepessaSessionCapsuleMetrics.anchor(ofPanelFrame: panel.frame).y, anchor.y, accuracy: 1)
  }

  /// Parked flush against the right edge, the capsule grows into a wider shape
  /// that has to be pushed left to fit; when it shrinks back it returns to where
  /// it was parked instead of resting where the wide shape was pushed.
  func testAShapeClampedAtTheScreenEdgeDoesNotMoveTheRestingPlace() throws {
    let visible = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first).visibleFrame
    // Low enough that the panel's shadow margin stays clear of the menu bar.
    let parked = CGPoint(x: visible.maxX - restingSize.width / 2, y: visible.maxY - 200)
    UserDefaults.standard.set(
      NSStringFromPoint(parked), forKey: "CepessaSessionsCapsuleAnchor")

    let controller = try makeConnectedController()
    let panel = try XCTUnwrap(controller.currentPanel)
    XCTAssertEqual(CepessaSessionCapsuleMetrics.anchor(ofPanelFrame: panel.frame).x, parked.x, accuracy: 1)

    controller.presentNotice("A notice wide enough to be pushed off the edge", style: .neutral)
    pump(1.2)
    XCTAssertLessThan(
      CepessaSessionCapsuleMetrics.anchor(ofPanelFrame: panel.frame).x, parked.x - 1,
      "the wide shape should have been pushed left to fit")
    controller.dismissNotice()
    pump(2.0)

    XCTAssertEqual(CepessaSessionCapsuleMetrics.anchor(ofPanelFrame: panel.frame).x, parked.x, accuracy: 1)
    XCTAssertEqual(CepessaSessionCapsuleMetrics.anchor(ofPanelFrame: panel.frame).y, parked.y, accuracy: 1)
  }

  // MARK: - Hit testing

  /// The container filters points; it must never answer *as* the content.
  func testContainerNeverImpersonatesTheRecorder() {
    let container = CepessaFloatingPanelContainerView(
      frame: NSRect(x: 0, y: 0, width: 66, height: 66))
    container.interactiveRect = CGRect(x: 22, y: 22, width: 22, height: 22)

    let content = NSView(frame: container.bounds)
    container.addSubview(content)

    XCTAssertTrue(
      container.hitTest(NSPoint(x: 33, y: 33)) === content,
      "the container answered instead of its content")
    XCTAssertNil(container.hitTest(NSPoint(x: 2, y: 2)))
    XCTAssertNil(container.hitTest(NSPoint(x: 64, y: 64)))
  }

  /// The orb's own hit target has to be reachable at its centre — decoration
  /// drawn over it (the glass rim) must never absorb the click.
  func testTheOrbIsReachableByAHitTestAtItsOwnCentre() throws {
    let controller = try makeConnectedController()
    let panel = try XCTUnwrap(controller.currentPanel)
    let container = try XCTUnwrap(panel.contentView as? CepessaFloatingPanelContainerView)

    let targets = hitTargets(in: panel)
    // The orb, and the capsule body behind it.
    let orb = try XCTUnwrap(targets.min { $0.frame.width < $1.frame.width })
    XCTAssertTrue(container.interactiveRect.contains(orb.frame))
    XCTAssertLessThan(
      orb.frame.minX - container.interactiveRect.minX, CepessaSessionCapsuleMetrics.orb,
      "the orb is not on the leading edge of the capsule")

    let centre = CGPoint(x: orb.frame.midX, y: orb.frame.midY)
    XCTAssertTrue(
      container.hitTest(centre) === orb.view,
      "a hit test at the orb's centre resolved to "
        + "\(container.hitTest(centre).map { String(describing: type(of: $0)) } ?? "nothing")")
  }

  private func hitTargets(in panel: NSWindow) -> [(view: NSView, frame: NSRect)] {
    guard let container = panel.contentView else { return [] }
    var found: [(NSView, NSRect)] = []
    func walk(_ view: NSView) {
      if view is SessionIndicatorHitNSView {
        found.append((view, view.convert(view.bounds, to: container)))
      }
      view.subviews.forEach(walk)
    }
    walk(container)
    return found
  }
}
