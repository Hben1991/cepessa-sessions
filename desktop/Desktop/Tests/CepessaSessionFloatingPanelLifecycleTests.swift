import AppKit
import XCTest

@testable import CepessaSessions

/// End-to-end cover for the floating panel's window lifecycle.
///
/// These exist because of a regression the pure-geometry tests could not see:
/// the indicator collapsed correctly and then stopped being present at all —
/// alive process, `floatingBarEnabled` still true, but nothing on screen and
/// nothing under an accessibility hit test. Every invariant below is a
/// property the panel has to hold *after the animation has finished*, which is
/// exactly where that failure lived.
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
    UserDefaults.standard.removeObject(forKey: "CepessaSessionsFloatingBarContentOrigin")
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
    // Let the model's start-up publishes land before touching the indicator.
    pump(1.0)
    return controller
  }

  /// Runs the real run loop so SwiftUI animations and their completions
  /// actually progress. A sleeping test would never see the settle at all.
  private func pump(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  private func restingPanelSize() -> CGSize {
    CepessaSessionFloatingBarGeometry.panelSize(
      for: CepessaSessionFloatingBarGeometry.idleSize)
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
      panel.frame.size, restingPanelSize(),
      "\(message): panel was left on the wrong footprint", file: file, line: line)
    XCTAssertFalse(
      controller.state.isTransitioning,
      "\(message): the transition never ended", file: file, line: line)
    XCTAssertEqual(
      controller.state.barContentSize, CepessaSessionFloatingBarGeometry.idleSize,
      "\(message): the lozenge is not back at rest", file: file, line: line)

    // The lozenge has to remain reachable by an accessibility hit test at its
    // own centre — this is what "absent from Accessibility" actually meant.
    let container = panel.contentView as? CepessaFloatingPanelContainerView
    let rect = container?.interactiveRect ?? .zero
    XCTAssertEqual(
      rect.size, CepessaSessionFloatingBarGeometry.idleSize,
      "\(message): the live area does not match the lozenge", file: file, line: line)
    XCTAssertTrue(
      rect.contains(CGPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)),
      "\(message): the centre of the panel is not live", file: file, line: line)
  }

  // MARK: - The regression

  /// Open the tray, close it, and let everything settle. The indicator has to
  /// come back — visible, resting-sized and clickable.
  func testIndicatorSurvivesAnOpenCloseCycle() throws {
    let controller = try makeConnectedController()
    assertRestingAndPresent(controller, "before the tray was ever opened")

    controller.toggleControlTray()
    pump(2.0)
    XCTAssertTrue(controller.state.interaction.isTrayOpen)
    XCTAssertEqual(
      controller.currentPanel?.frame.size,
      CepessaSessionFloatingBarGeometry.panelSize(
        for: CepessaSessionFloatingBarGeometry.traySize),
      "the open tray should size the panel to the tray footprint"
    )

    controller.closeControlTray()
    pump(2.0)
    assertRestingAndPresent(controller, "after closing the tray")
  }

  /// Repeated cycles must not accumulate state — the panel has to land on the
  /// resting footprint every time, not creep or stay stranded on the union.
  func testRepeatedOpenCloseCyclesAlwaysLandAtRest() throws {
    let controller = try makeConnectedController()

    for cycle in 1...3 {
      controller.toggleControlTray()
      pump(0.9)
      controller.closeControlTray()
      pump(2.0)
      assertRestingAndPresent(controller, "after cycle \(cycle)")
    }
  }

  /// Interrupting a collapse by reopening must not leave a superseded settle
  /// to shrink the panel underneath the tray that is now open.
  func testReopeningDuringACollapseIsNotUndoneByTheOldTransition() throws {
    let controller = try makeConnectedController()

    controller.toggleControlTray()
    pump(0.9)
    controller.closeControlTray()
    pump(0.1)
    controller.toggleControlTray()
    pump(2.0)

    XCTAssertTrue(controller.state.interaction.isTrayOpen)
    XCTAssertFalse(controller.state.isTransitioning)
    XCTAssertEqual(
      controller.currentPanel?.frame.size,
      CepessaSessionFloatingBarGeometry.panelSize(
        for: CepessaSessionFloatingBarGeometry.traySize),
      "a stale settle shrank the panel under an open tray"
    )
  }

  // MARK: - Hit testing

  /// The container filters points; it must never answer *as* the content.
  /// Returning `self` for a point on the lozenge substitutes an anonymous
  /// `NSView` for the real element, which is what made the indicator vanish
  /// from accessibility hit tests while it was still on screen.
  func testContainerNeverImpersonatesTheIndicator() {
    let container = CepessaFloatingPanelContainerView(
      frame: NSRect(x: 0, y: 0, width: 66, height: 66))
    container.interactiveRect = CGRect(x: 22, y: 22, width: 22, height: 22)

    // Stand in for the hosting view that carries the real element.
    let content = NSView(frame: container.bounds)
    container.addSubview(content)

    // A point on the lozenge resolves to the content, never to the container.
    // Short-circuiting to `self` here substitutes an anonymous `NSView` for the
    // accessibility element and makes the indicator unreachable by hit test.
    XCTAssertTrue(
      container.hitTest(NSPoint(x: 33, y: 33)) === content,
      "the container answered instead of its content"
    )

    // Outside the lozenge the click belongs to whatever is behind the panel,
    // even though the content view spans the whole bleed.
    XCTAssertNil(container.hitTest(NSPoint(x: 2, y: 2)))
    XCTAssertNil(container.hitTest(NSPoint(x: 64, y: 64)))
  }

  /// Every `SessionIndicatorHitNSView` currently in the panel, with its frame
  /// in container coordinates.
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

  private func mouseEvent(
    _ type: NSEvent.EventType, at point: CGPoint, in panel: NSWindow
  ) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: panel.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: type == .leftMouseDown ? 1 : 0
      ))
  }

  /// The open tray's close handle has to be reachable by a hit test at the
  /// centre accessibility reports for it.
  ///
  /// This is the regression the geometry tests could not see. The handle was
  /// laid out correctly, published a correct 22×22 accessibility frame and
  /// reported `AXButton` — but the glass rim was drawn *over* it as a live
  /// overlay, so a hit test at its own centre resolved to the hosting view and
  /// the click was absorbed by decoration. The resting indicator was immune
  /// because its hit target is stacked above the glass; every control that
  /// lives *inside* the tray was not.
  func testTrayHandleIsReachableByAHitTestAtItsOwnCentre() throws {
    let controller = try makeConnectedController()
    controller.toggleControlTray()
    pump(2.0)

    let panel = try XCTUnwrap(controller.currentPanel)
    let container = try XCTUnwrap(panel.contentView as? CepessaFloatingPanelContainerView)

    let targets = hitTargets(in: panel)
    XCTAssertEqual(
      targets.count, 1, "the open tray should expose exactly one indicator hit target")
    let handle = try XCTUnwrap(targets.first)

    // It rides the leading edge of the tray, not the middle of it.
    XCTAssertTrue(
      container.interactiveRect.contains(handle.frame),
      "the tray handle is outside the panel's live area")
    XCTAssertLessThan(
      handle.frame.minX - container.interactiveRect.minX,
      CepessaChrome.Control.micro,
      "the tray handle is not on the leading edge of the tray")

    let centre = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
    XCTAssertTrue(
      container.hitTest(centre) === handle.view,
      "a hit test at the tray handle's centre resolved to "
        + "\(container.hitTest(centre).map { String(describing: type(of: $0)) } ?? "nothing") "
        + "instead of the handle — decoration is absorbing the click"
    )
  }

  /// The same thing end to end: a press/release pair delivered at that centre
  /// has to actually close the tray and land the panel back at rest.
  ///
  /// `closeControlTray()` being correct is not enough — the failure was that
  /// the click never reached it.
  func testClickingTheTrayHandleClosesTheTray() throws {
    let controller = try makeConnectedController()
    controller.toggleControlTray()
    pump(2.0)
    XCTAssertTrue(controller.state.interaction.isTrayOpen, "the tray never opened")

    let panel = try XCTUnwrap(controller.currentPanel)
    let handle = try XCTUnwrap(hitTargets(in: panel).first)
    let centre = CGPoint(x: handle.frame.midX, y: handle.frame.midY)

    // The hit target resolves click-versus-drag in a nested tracking loop, so
    // the release has to be in the application's queue before the press is
    // delivered — exactly the order a real click arrives in.
    NSApp.postEvent(try mouseEvent(.leftMouseUp, at: centre, in: panel), atStart: false)
    panel.sendEvent(try mouseEvent(.leftMouseDown, at: centre, in: panel))
    pump(2.0)

    XCTAssertFalse(
      controller.state.interaction.isTrayOpen,
      "clicking the tray handle did not close the tray")
    XCTAssertFalse(
      controller.state.isRecording, "closing the tray must never start capture")
    assertRestingAndPresent(controller, "after clicking the tray handle")
  }

  /// The settle backstop has to sit well clear of the spring's own settling
  /// time, or it fires while the shape is still travelling and resizes the
  /// window out from under a running animation.
  func testSettleBackstopIsClearOfTheSpring() {
    XCTAssertGreaterThan(
      CepessaChrome.Motion.settleTimeout,
      CepessaChrome.Motion.expandDuration * 3
    )
  }
}
