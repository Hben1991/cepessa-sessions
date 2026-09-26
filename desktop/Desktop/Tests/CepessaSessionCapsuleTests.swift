import XCTest

@testable import CepessaSessions

final class CepessaSessionCapsuleTests: XCTestCase {
  private typealias M = CepessaSessionCapsuleMetrics

  private func size(
    _ phase: CepessaSessionCapsulePhase,
    compact: Bool = false,
    hours: Bool = false,
    notice: Bool = false,
    screen: CGFloat? = nil
  ) -> CGSize {
    M.contentSize(
      for: .init(phase: phase, isCompact: compact, showsHours: hours, hasNotice: notice),
      availableScreenWidth: screen)
  }

  // MARK: - Geometry

  func testEveryStateSharesOneHeightSoOnlyTheWidthEverMoves() {
    let heights = Set(
      [
        size(.idle), size(.preparing), size(.processing), size(.attention),
        size(.recording), size(.recording, compact: true), size(.recording, notice: true),
      ].map(\.height))
    XCTAssertEqual(heights, [M.height])
  }

  /// At rest the capsule carries the orb and the menu, nothing else — it is
  /// the quietest state and the narrowest.
  func testRestingCapsuleIsTheOrbAndTheMenu() {
    XCTAssertEqual(size(.idle).width, M.inset * 2 + M.orb + M.gap / 2 + M.control, accuracy: 1)
    for phase: CepessaSessionCapsulePhase in [.preparing, .processing, .attention, .recording] {
      XCTAssertLessThan(size(.idle).width, size(phase).width, "\(phase)")
    }
  }

  func testFoldedRecordingKeepsTheTimerAndLevelsButDropsTheControls() {
    let expanded = size(.recording)
    let folded = size(.recording, compact: true)
    XCTAssertLessThan(folded.width, expanded.width)
    XCTAssertGreaterThanOrEqual(
      folded.width, M.inset * 2 + M.orb + M.gap + M.timer + M.levels,
      "the folded capsule still has to fit the timer and both levels")
    // Folding only means something while recording.
    XCTAssertEqual(size(.idle, compact: true), size(.idle))
    XCTAssertEqual(size(.processing, compact: true), size(.processing))
  }

  func testTheTimerWidensOnceWhenItGainsAnHourField() {
    XCTAssertEqual(
      size(.recording, hours: true).width - size(.recording).width,
      M.timerWithHours - M.timer)
  }

  func testANoticeIsGivenRoomToBeReadInFull() {
    XCTAssertGreaterThan(size(.idle, notice: true).width, size(.idle).width + M.notice / 2)
    XCTAssertGreaterThanOrEqual(size(.recording, notice: true).width, size(.recording).width)
  }

  func testNarrowScreensClampTheCapsuleButNeverBelowTheOrb() {
    let wide = size(.recording, notice: true)
    let narrow = size(.recording, notice: true, screen: 360)
    XCTAssertEqual(narrow.width, 360 - M.panelBleed * 2 - 16, accuracy: 1)
    XCTAssertLessThan(narrow.width, wide.width)
    XCTAssertEqual(size(.recording, screen: 40).width, M.inset * 2 + M.orb)
  }

  func testPanelKeepsEnoughRoomForTheWidestShadowItCasts() {
    XCTAssertGreaterThanOrEqual(M.panelBleed, M.shadowRadius * 3 + M.shadowOffset)
    let content = size(.recording)
    let panel = M.panelSize(for: content)
    XCTAssertEqual(panel.width, content.width + M.panelBleed * 2)
    XCTAssertEqual(panel.height, content.height + M.panelBleed * 2)
  }

  /// Growing or shrinking hangs the capsule from the same top-centre point,
  /// so the orb never jumps when the controls open.
  func testEveryFootprintHangsFromTheSameAnchor() {
    let anchor = CGPoint(x: 720, y: 880)
    for content in [size(.idle), size(.recording), size(.processing, notice: true)] {
      let frame = M.panelFrame(anchor: anchor, contentSize: content)
      XCTAssertEqual(M.anchor(ofPanelFrame: frame), anchor)
      let rect = M.contentRect(contentSize: content, inPanelOfSize: frame.size)
      XCTAssertEqual(rect.midX, frame.width / 2, accuracy: 0.5)
    }
  }

  func testChangingShapeAllDayNeverWalksTheCapsuleAcrossTheScreen() {
    var anchor = CGPoint(x: 700.5, y: 880)
    let shapes = [size(.idle), size(.recording), size(.recording, compact: true), size(.processing)]
    for _ in 0..<50 {
      for shape in shapes {
        anchor = M.anchor(ofPanelFrame: M.panelFrame(anchor: anchor, contentSize: shape))
      }
    }
    XCTAssertEqual(anchor, CGPoint(x: 700.5, y: 880))
    for shape in shapes {
      XCTAssertEqual(shape.width.truncatingRemainder(dividingBy: 2), 0, "\(shape)")
    }
  }

  func testAPositionSavedByTheFormerIndicatorBecomesItsTopCentre() {
    // The 22pt indicator stored its bottom-left content origin.
    let migrated = M.migratedAnchor(fromLegacyContentOrigin: CGPoint(x: 100, y: 800))
    XCTAssertEqual(migrated, CGPoint(x: 111, y: 822))
  }

  // MARK: - Morph

  func testPanelTakesTheUnionOfBothFootprintsWhileTheShapeIsMoving() {
    let idle = size(.idle)
    let recording = size(.recording)
    XCTAssertEqual(
      CepessaSessionCapsuleTransition.panelContentSize(from: idle, to: recording), recording)
    XCTAssertEqual(
      CepessaSessionCapsuleTransition.panelContentSize(from: recording, to: idle), recording)
  }

  /// Nothing about capture may be decided by an animation: a collapsing
  /// capsule cannot deliver a click to Stop sliding under the pointer.
  func testControlsIgnoreClicksWhileTheShapeIsMoving() {
    XCTAssertFalse(CepessaSessionCapsuleTransition.acceptsClicks(isTransitioning: true))
    XCTAssertTrue(CepessaSessionCapsuleTransition.acceptsClicks(isTransitioning: false))
  }

  func testOnlyTheSettledCapsuleIsInteractive() {
    let idle = size(.idle)
    let recording = size(.recording)
    let panel = M.panelSize(for: recording)

    let moving = CepessaSessionCapsuleTransition.interactiveRect(
      contentSize: idle, panelContentSize: recording, panelSize: panel, isTransitioning: true)
    let settled = CepessaSessionCapsuleTransition.interactiveRect(
      contentSize: recording, panelContentSize: recording, panelSize: panel,
      isTransitioning: false)

    XCTAssertEqual(moving.size, recording)
    XCTAssertEqual(settled.size, recording)
    XCTAssertFalse(settled.contains(CGPoint(x: 2, y: 2)), "the bleed is never interactive")
  }

  func testTheSettleBackstopIsClearOfTheSpring() {
    XCTAssertGreaterThan(SessionsMotion.capsuleSettleTimeout, 0.46 * 3)
  }

  // MARK: - Phase

  @MainActor
  func testThePhaseFollowsWhatTheRecorderIsActuallyDoing() throws {
    let state = CepessaSessionFloatingBarState()
    XCTAssertEqual(state.phase, .idle)

    let lifecycle = LocalCaptureLifecycle()
    let lease = try lifecycle.beginCapture(.session)
    state.capturePhase = lifecycle.phase
    XCTAssertEqual(state.phase, .preparing)

    lifecycle.markRecording(lease)
    state.capturePhase = lifecycle.phase
    state.isRecording = true
    XCTAssertEqual(state.phase, .recording)

    lifecycle.beginStopping(lease)
    state.capturePhase = lifecycle.phase
    XCTAssertEqual(state.phase, .preparing)
    XCTAssertTrue(state.isStopping)

    lifecycle.finishCapture(lease)
    state.capturePhase = lifecycle.phase
    state.isRecording = false
    state.isTranscribing = true
    XCTAssertEqual(state.phase, .processing)

    state.isTranscribing = false
    state.errorMessage = "Microphone unavailable"
    XCTAssertEqual(state.phase, .attention)

    state.errorMessage = "   "
    XCTAssertEqual(state.phase, .idle, "whitespace is not a fault")
  }

  @MainActor
  func testHoverAndVisibilityNeverReachTheLayout() {
    let state = CepessaSessionFloatingBarState()
    let before = state.layout
    state.interaction.hoverChanged(true)
    state.interaction.hideForCurrentRecording()
    XCTAssertEqual(state.layout, before)
  }

  @MainActor
  func testCaptureControlPolicyFollowsTheLease() throws {
    let lifecycle = LocalCaptureLifecycle()
    XCTAssertEqual(CepessaSessionCaptureControlPolicy.resolve(lifecycle.phase), .startSession)

    let lease = try lifecycle.beginCapture(.session)
    XCTAssertEqual(
      CepessaSessionCaptureControlPolicy.resolve(lifecycle.phase), .cancelSessionStart)
    XCTAssertTrue(CepessaSessionCaptureControlPolicy.resolve(lifecycle.phase).allowsStoppingSession)

    lifecycle.markRecording(lease)
    XCTAssertEqual(CepessaSessionCaptureControlPolicy.resolve(lifecycle.phase), .stopSession)

    lifecycle.beginStopping(lease)
    XCTAssertEqual(CepessaSessionCaptureControlPolicy.resolve(lifecycle.phase), .unavailable)
    XCTAssertFalse(
      CepessaSessionCaptureControlPolicy.resolve(lifecycle.phase).allowsStoppingSession)
  }

  func testStatusItemKeepsRecordingPrimaryWhenCaptureNeedsAttention() {
    XCTAssertEqual(
      CepessaSessionStatusBarMode.resolve(isRecording: true, hasFault: true, isTranscribing: false),
      .recording)
    XCTAssertEqual(
      CepessaSessionStatusBarMode.resolve(isRecording: false, hasFault: true, isTranscribing: false),
      .failed)
  }

  // MARK: - Interaction

  func testHideAppliesOnlyToTheCurrentRecording() {
    var interaction = CepessaSessionCapsuleInteraction()
    interaction.hideForCurrentRecording()
    XCTAssertTrue(interaction.isHiddenForCurrentRecording)

    interaction.recordingDidStart()
    XCTAssertFalse(interaction.isHiddenForCurrentRecording)

    interaction.hideForCurrentRecording()
    interaction.show()
    XCTAssertFalse(interaction.isHiddenForCurrentRecording)
  }

  // MARK: - Orb

  func testHealthyRecordingIsNeverPaintedWithASuccessState() {
    XCTAssertEqual(
      SessionsOrb.Mood.resolve(phase: .recording, health: .healthy, progress: nil), .recording)
    XCTAssertEqual(
      SessionsOrb.Mood.resolve(phase: .recording, health: .muted, progress: nil), .muted)
    XCTAssertEqual(
      SessionsOrb.Mood.resolve(phase: .recording, health: .partial, progress: nil), .degraded)
    XCTAssertEqual(
      SessionsOrb.Mood.resolve(phase: .recording, health: .unavailable, progress: nil), .attention)
  }

  func testTheOrbCarriesRealProgressOrNone() {
    XCTAssertEqual(
      SessionsOrb.Mood.resolve(phase: .processing, health: .unavailable, progress: 0.4),
      .processing(0.4))
    XCTAssertEqual(
      SessionsOrb.Mood.resolve(phase: .processing, health: .unavailable, progress: nil),
      .processing(nil))
    // Capture health is meaningless when nothing is captured.
    XCTAssertEqual(
      SessionsOrb.Mood.resolve(phase: .idle, health: .unavailable, progress: nil), .idle)
  }

  // MARK: - Capture health

  func testCaptureHealthDoesNotTreatIntentionalMuteAsFailure() {
    XCTAssertEqual(
      CepessaSessionCaptureHealth.resolve(
        microphoneActive: false, microphoneMuted: true, systemAudioActive: true, hasError: false),
      .muted)
  }

  func testCaptureHealthDistinguishesHealthyPartialAndUnavailableCapture() {
    XCTAssertEqual(
      CepessaSessionCaptureHealth.resolve(
        microphoneActive: true, microphoneMuted: false, systemAudioActive: true, hasError: false),
      .healthy)
    XCTAssertEqual(
      CepessaSessionCaptureHealth.resolve(
        microphoneActive: true, microphoneMuted: false, systemAudioActive: false, hasError: false),
      .partial)
    XCTAssertEqual(
      CepessaSessionCaptureHealth.resolve(
        microphoneActive: true, microphoneMuted: false, systemAudioActive: true, hasError: true),
      .unavailable)
    XCTAssertEqual(
      CepessaSessionCaptureHealth.resolve(
        microphoneActive: false, microphoneMuted: true, systemAudioActive: false, hasError: false),
      .unavailable)
  }

  // MARK: - Timer

  func testTimerDropsTheHourFieldUnderOneHourAndUnpadsItAfter() {
    XCTAssertEqual(CepessaSessionIndicatorTimer.compactText(from: "00:04:07"), "04:07")
    XCTAssertEqual(CepessaSessionIndicatorTimer.compactText(from: "01:04:07"), "1:04:07")
    XCTAssertEqual(CepessaSessionIndicatorTimer.compactText(from: "garbled"), "garbled")
    XCTAssertFalse(CepessaSessionIndicatorTimer.showsHours("00:59:59"))
    XCTAssertTrue(CepessaSessionIndicatorTimer.showsHours("01:00:00"))
  }

  // MARK: - Status copy

  func testTheStatusColumnReportsOnlyWhatTheAppKnows() {
    XCTAssertEqual(
      CepessaSessionCapsuleStatus.detail(phase: .processing, progress: 0.42, stage: "Separating speakers"),
      "42% · Separating speakers")
    XCTAssertEqual(
      CepessaSessionCapsuleStatus.detail(phase: .processing, progress: nil, stage: "  "),
      "On this Mac")
    XCTAssertEqual(
      CepessaSessionCapsuleStatus.detail(phase: .processing, progress: 1, stage: nil), "100%")
    XCTAssertNil(CepessaSessionCapsuleStatus.detail(phase: .idle, progress: nil, stage: nil))
    XCTAssertEqual(
      CepessaSessionCapsuleStatus.title(phase: .preparing, isStopping: true), "Saving recording")
    XCTAssertEqual(
      CepessaSessionCapsuleStatus.title(phase: .preparing, isStopping: false), "Starting")
  }

  // MARK: - Accessibility

  func testTheOrbSaysWhatItsOneClickWillDo() {
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.orbLabel(phase: .idle, isCompact: false),
      "Start recording")
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.orbLabel(phase: .recording, isCompact: false),
      "Collapse recording controls")
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.orbLabel(phase: .recording, isCompact: true),
      "Show recording controls")
    // A transcription in progress or a problem on show never blocks the next
    // recording: the orb still records, and the status text opens the session.
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.orbLabel(phase: .processing, isCompact: false),
      "Start another recording")
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.orbLabel(phase: .attention, isCompact: false),
      "Start recording")
  }

  func testTheCapsuleValueDescribesCaptureHealthWhileRecording() {
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.capsuleValue(
        phase: .recording, health: .partial, timerText: "00:04:07", progress: nil),
      "Recording 4 minutes 7 seconds. Only one audio source is recording.")
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.capsuleValue(
        phase: .processing, health: .healthy, timerText: "00:00:00", progress: 0.5),
      "Transcribing, 50 percent complete.")
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.capsuleValue(
        phase: .idle, health: .unavailable, timerText: "00:00:00", progress: nil),
      "Not recording.")
  }

  func testStatusItemIsMeaningfulInEveryState() {
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemLabel(
        isRecording: false, isTranscribing: false, hasFault: false),
      "Cepessa Sessions, idle")
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemLabel(
        isRecording: true, isTranscribing: false, hasFault: false),
      "Cepessa Sessions, recording")
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemLabel(
        isRecording: false, isTranscribing: true, hasFault: false),
      "Cepessa Sessions, transcribing")
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemLabel(
        isRecording: true, isTranscribing: false, hasFault: true),
      "Cepessa Sessions, recording, needs attention")
  }

  func testAHiddenRecorderAlwaysAnnouncesTheWayBack() {
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemValue(
        isRecording: true, isTranscribing: false, hasFault: false,
        timerText: "00:02:00", progress: nil, indicatorHidden: true),
      "Recording 2 minutes 0 seconds. Floating recorder hidden; choose Show Recorder to bring it back"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemValue(
        isRecording: false, isTranscribing: true, hasFault: false,
        timerText: "00:00:00", progress: 0.25, indicatorHidden: false),
      "Transcribing 25 percent")
  }
}
