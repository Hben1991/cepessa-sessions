import XCTest

@testable import CepessaSessions

final class CepessaSessionFloatingBarInteractionTests: XCTestCase {

  // MARK: - Geometry

  func testRestingIndicatorIsAMicroLozengeThatOnlyGrowsForTheTimer() {
    XCTAssertEqual(
      CepessaSessionFloatingBarGeometry.contentSize(for: .idle),
      CepessaSessionFloatingBarGeometry.idleSize
    )
    XCTAssertEqual(
      CepessaSessionFloatingBarGeometry.contentSize(for: .processing),
      CepessaSessionFloatingBarGeometry.idleSize
    )
    XCTAssertEqual(
      CepessaSessionFloatingBarGeometry.contentSize(for: .recording),
      CepessaSessionFloatingBarGeometry.recordingSize
    )
    XCTAssertEqual(CepessaSessionFloatingBarGeometry.idleSize, CGSize(width: 22, height: 22))
    XCTAssertEqual(CepessaSessionFloatingBarGeometry.recordingSize.height, 22)
  }

  func testRecordingLozengeGrowsOnceWhenTheTimerGainsAnHoursField() {
    XCTAssertEqual(
      CepessaSessionFloatingBarGeometry.contentSize(for: .recording, showsHours: true),
      CepessaSessionFloatingBarGeometry.longRecordingSize
    )
    XCTAssertGreaterThan(
      CepessaSessionFloatingBarGeometry.longRecordingSize.width,
      CepessaSessionFloatingBarGeometry.recordingSize.width
    )
  }

  /// Live capture adds mute, capture and stop to the same row. The tray widens
  /// once for them rather than truncating the status text.
  func testTrayWidensForLiveCaptureAndForANoticeWorthReading() {
    let idleTray = CepessaSessionFloatingBarGeometry.contentSize(for: .tray)
    let recordingTray = CepessaSessionFloatingBarGeometry.contentSize(
      for: .tray, isRecording: true)
    let noticeTray = CepessaSessionFloatingBarGeometry.contentSize(
      for: .tray, isRecording: true, hasNotice: true)

    XCTAssertEqual(idleTray, CepessaSessionFloatingBarGeometry.traySize)
    XCTAssertEqual(recordingTray, CepessaSessionFloatingBarGeometry.recordingTraySize)
    XCTAssertEqual(noticeTray, CepessaSessionFloatingBarGeometry.noticeTraySize)

    XCTAssertLessThan(idleTray.width, recordingTray.width)
    XCTAssertLessThan(recordingTray.width, noticeTray.width)
    // One height for every tray state: only the width is ever allowed to move.
    XCTAssertEqual(idleTray.height, recordingTray.height)
    XCTAssertEqual(recordingTray.height, noticeTray.height)
  }

  func testOnlyTheTrayClampsToNarrowScreens() {
    let bleed = CepessaSessionFloatingBarGeometry.panelBleed
    let narrow = CepessaSessionFloatingBarGeometry.contentSize(
      for: .tray, availableScreenWidth: 280)

    // The bleed is part of the panel, so a narrow screen has to pay for it too.
    XCTAssertEqual(narrow.width, 280 - bleed * 2 - 16)
    XCTAssertLessThan(narrow.width, CepessaSessionFloatingBarGeometry.traySize.width)

    // Never narrower than the recording lozenge, however little room there is.
    XCTAssertEqual(
      CepessaSessionFloatingBarGeometry.contentSize(for: .tray, availableScreenWidth: 80).width,
      CepessaSessionFloatingBarGeometry.recordingSize.width
    )

    // The resting states never clamp — they already fit anywhere.
    XCTAssertEqual(
      CepessaSessionFloatingBarGeometry.contentSize(for: .recording, availableScreenWidth: 80),
      CepessaSessionFloatingBarGeometry.recordingSize
    )
    XCTAssertEqual(
      CepessaSessionFloatingBarGeometry.contentSize(for: .idle, availableScreenWidth: 80),
      CepessaSessionFloatingBarGeometry.idleSize
    )
  }

  // MARK: - Panel bleed

  /// The square halo around the resting indicator was the panel edge clipping
  /// the glass rim and both shadow layers. The panel has to be bigger than the
  /// shape by at least the reach of the widest shadow it casts.
  func testPanelKeepsEnoughRoomForTheWidestShadowItCasts() {
    let lifted = CepessaChrome.Elevation.lifted
    // A blur remains visible beyond one nominal radius. Reserve the full
    // three-radius Gaussian tail plus its vertical offset, otherwise the
    // transparent NSPanel still cuts a horizontal edge through the shadow.
    let reach = lifted.ambient.radius * 3 + abs(lifted.ambient.y)

    XCTAssertGreaterThan(CepessaSessionFloatingBarGeometry.panelBleed, reach)

    let panel = CepessaSessionFloatingBarGeometry.panelSize(
      for: CepessaSessionFloatingBarGeometry.idleSize)
    XCTAssertEqual(
      panel,
      CGSize(
        width: 22 + CepessaSessionFloatingBarGeometry.panelBleed * 2,
        height: 22 + CepessaSessionFloatingBarGeometry.panelBleed * 2
      )
    )
  }

  func testLozengeIsCentredInItsPanelSoGrowingItNeverMovesTheObject() {
    let panel = CepessaSessionFloatingBarGeometry.panelSize(
      for: CepessaSessionFloatingBarGeometry.traySize, bleed: 20)
    let restingRect = CepessaSessionFloatingBarGeometry.contentRect(
      contentSize: CepessaSessionFloatingBarGeometry.idleSize, inPanelOfSize: panel)
    let trayRect = CepessaSessionFloatingBarGeometry.contentRect(
      contentSize: CepessaSessionFloatingBarGeometry.traySize, inPanelOfSize: panel)

    XCTAssertEqual(restingRect.midX, trayRect.midX)
    XCTAssertEqual(restingRect.midY, trayRect.midY)
  }

  func testDraggedTrayPersistsTheRestingLozengeCenterAndTopEdge() {
    let draggedTrayFrame = CGRect(x: 780, y: 640, width: 264, height: 72)

    let origin = CepessaSessionFloatingBarGeometry.restingContentOrigin(
      afterDragging: draggedTrayFrame,
      restingContentSize: CGSize(width: 22, height: 22),
      bleed: 20
    )

    // Horizontal centre of the dragged panel, and the top edge of its content.
    XCTAssertEqual(origin.x, 780 + 132 - 11)
    XCTAssertEqual(origin.y, 640 + 72 - 20 - 22)
  }

  /// A position saved before the panel carried any bleed described the panel,
  /// not the lozenge. Reading it back unmigrated would shift every existing
  /// install by half the old padding.
  func testLegacyPositionsMigrateToAContentOriginWithoutMovingTheIndicator() {
    let migrated = CepessaSessionFloatingBarGeometry.migratedContentOrigin(
      fromLegacyPanelOrigin: CGPoint(x: 400, y: 900), legacyPadding: 10)

    XCTAssertEqual(migrated, CGPoint(x: 405, y: 905))

    let panelOrigin = CepessaSessionFloatingBarGeometry.panelOrigin(
      forContentOrigin: migrated, bleed: 20)
    XCTAssertEqual(panelOrigin, CGPoint(x: 385, y: 885))
  }

  // MARK: - Expand / collapse

  /// The panel takes the union of both footprints for the length of the morph,
  /// so the glass is never clipped while the shape is in flight.
  func testPanelTakesTheUnionOfBothFootprintsWhileTheShapeIsMoving() {
    let resting = CepessaSessionFloatingBarGeometry.idleSize
    let tray = CepessaSessionFloatingBarGeometry.traySize

    XCTAssertEqual(
      CepessaSessionIndicatorTransition.panelContentSize(from: resting, to: tray),
      CGSize(width: tray.width, height: tray.height)
    )
    // Collapsing takes the same union — the panel shrinks only once it lands.
    XCTAssertEqual(
      CepessaSessionIndicatorTransition.panelContentSize(from: tray, to: resting),
      CGSize(width: tray.width, height: tray.height)
    )
    // A recording lozenge is wider but shorter than the tray; the union has to
    // take the larger of each axis independently.
    XCTAssertEqual(
      CepessaSessionIndicatorTransition.panelContentSize(
        from: CGSize(width: 82, height: 22), to: CGSize(width: 40, height: 32)),
      CGSize(width: 82, height: 32)
    )
  }

  func testAClosingTrayCannotDeliverAClickThroughToRecordOrStop() {
    XCTAssertFalse(CepessaSessionIndicatorTransition.acceptsClicks(isTransitioning: true))
    XCTAssertTrue(CepessaSessionIndicatorTransition.acceptsClicks(isTransitioning: false))
  }

  /// While the shape moves the whole union is inert, so a click can neither
  /// hit a control that is still sliding nor fall through the transparent
  /// bleed to whatever is behind the panel. Once settled, only the lozenge is
  /// live and everything around it passes clicks through.
  func testOnlyTheSettledLozengeIsInteractive() {
    let tray = CepessaSessionFloatingBarGeometry.traySize
    let resting = CepessaSessionFloatingBarGeometry.idleSize
    let panel = CepessaSessionFloatingBarGeometry.panelSize(for: tray, bleed: 20)

    let moving = CepessaSessionIndicatorTransition.interactiveRect(
      contentSize: resting,
      panelContentSize: tray,
      panelSize: panel,
      isTransitioning: true
    )
    let settled = CepessaSessionIndicatorTransition.interactiveRect(
      contentSize: resting,
      panelContentSize: tray,
      panelSize: panel,
      isTransitioning: false
    )

    XCTAssertEqual(moving.size, tray)
    XCTAssertEqual(settled.size, resting)
    XCTAssertTrue(moving.contains(CGPoint(x: panel.width / 2, y: panel.height / 2)))
    // The bleed itself is never interactive once the shape has settled.
    XCTAssertFalse(settled.contains(CGPoint(x: 2, y: 2)))
  }

  func testReduceMotionRemovesTheAnimationAndTheSettleDelay() {
    XCTAssertNil(CepessaChrome.Motion.expand(reduceMotion: true))
    XCTAssertNotNil(CepessaChrome.Motion.expand(reduceMotion: false))
    XCTAssertEqual(CepessaChrome.Motion.settleDelay(reduceMotion: true), 0)
    XCTAssertEqual(
      CepessaChrome.Motion.settleDelay(reduceMotion: false), CepessaChrome.Motion.expandDuration)
  }

  func testStatusItemKeepsRecordingPrimaryWhenCaptureNeedsAttention() {
    XCTAssertEqual(
      CepessaSessionStatusBarMode.resolve(
        isRecording: true,
        hasFault: true,
        isTranscribing: false
      ),
      .recording
    )
    XCTAssertEqual(
      CepessaSessionStatusBarMode.resolve(
        isRecording: false,
        hasFault: true,
        isTranscribing: false
      ),
      .failed
    )
  }

  // MARK: - Interaction reducer

  func testHoverNeverChangesGeometry() {
    var interaction = CepessaSessionFloatingBarInteractionState()

    interaction.hoverChanged(true)
    XCTAssertTrue(interaction.isHovered)
    XCTAssertFalse(interaction.isExpanded)

    interaction.hoverChanged(false)
    XCTAssertFalse(interaction.isHovered)
    XCTAssertFalse(interaction.isExpanded)
  }

  func testDeliberateClickOpensAndClosesTheControlTray() {
    var interaction = CepessaSessionFloatingBarInteractionState()

    interaction.toggleTray()
    XCTAssertTrue(interaction.isTrayOpen)
    XCTAssertTrue(interaction.isExpanded)

    interaction.toggleTray()
    XCTAssertFalse(interaction.isTrayOpen)
    XCTAssertFalse(interaction.isExpanded)
  }

  func testTrayStaysOpenWhileThePointerMovesInAndOut() {
    var interaction = CepessaSessionFloatingBarInteractionState()
    interaction.openTray()

    interaction.hoverChanged(false)
    XCTAssertTrue(interaction.isExpanded)

    interaction.closeTray()
    XCTAssertFalse(interaction.isExpanded)
  }

  func testHideAppliesOnlyToCurrentRecordingAndNextRecordingRestoresRestingState() {
    var interaction = CepessaSessionFloatingBarInteractionState()
    interaction.openTray()
    interaction.hideForCurrentRecording()

    XCTAssertTrue(interaction.isHiddenForCurrentRecording)
    XCTAssertFalse(interaction.isExpanded)

    interaction.recordingDidStart()

    XCTAssertFalse(interaction.isHiddenForCurrentRecording)
    XCTAssertFalse(interaction.isExpanded)
  }

  func testShowRestoresAHiddenIndicatorWithoutOpeningTheTray() {
    var interaction = CepessaSessionFloatingBarInteractionState()
    interaction.hideForCurrentRecording()

    interaction.show()

    XCTAssertFalse(interaction.isHiddenForCurrentRecording)
    XCTAssertFalse(interaction.isExpanded)
  }

  func testOpeningTheTrayRevealsAHiddenIndicator() {
    var interaction = CepessaSessionFloatingBarInteractionState()
    interaction.hideForCurrentRecording()

    interaction.toggleTray()

    XCTAssertFalse(interaction.isHiddenForCurrentRecording)
    XCTAssertTrue(interaction.isExpanded)
  }

  // MARK: - Stop reachability

  func testStopIsReachableFromTheRestingIndicatorAndTheTrayWhileRecording() {
    XCTAssertTrue(
      CepessaSessionFloatingBarCapabilities.stopAvailable(in: .recording, isRecording: true))
    XCTAssertTrue(
      CepessaSessionFloatingBarCapabilities.stopAvailable(in: .tray, isRecording: true))
  }

  func testStopIsNotOfferedWhenNothingIsBeingCaptured() {
    XCTAssertFalse(
      CepessaSessionFloatingBarCapabilities.stopAvailable(in: .idle, isRecording: false))
    XCTAssertFalse(
      CepessaSessionFloatingBarCapabilities.stopAvailable(in: .processing, isRecording: false))
    XCTAssertFalse(
      CepessaSessionFloatingBarCapabilities.stopAvailable(in: .tray, isRecording: false))
    XCTAssertFalse(
      CepessaSessionFloatingBarCapabilities.stopAvailable(in: .recording, isRecording: false))
  }

  // MARK: - Capture health

  func testCaptureHealthDoesNotTreatIntentionalMuteAsFailure() {
    XCTAssertEqual(
      CepessaSessionCaptureHealth.resolve(
        microphoneActive: false,
        microphoneMuted: true,
        systemAudioActive: true,
        hasError: false
      ),
      .muted
    )
  }

  func testCaptureHealthDistinguishesHealthyPartialAndUnavailableCapture() {
    XCTAssertEqual(
      CepessaSessionCaptureHealth.resolve(
        microphoneActive: true,
        microphoneMuted: false,
        systemAudioActive: true,
        hasError: false
      ),
      .healthy
    )
    XCTAssertEqual(
      CepessaSessionCaptureHealth.resolve(
        microphoneActive: true,
        microphoneMuted: false,
        systemAudioActive: false,
        hasError: false
      ),
      .partial
    )
    XCTAssertEqual(
      CepessaSessionCaptureHealth.resolve(
        microphoneActive: true,
        microphoneMuted: false,
        systemAudioActive: true,
        hasError: true
      ),
      .unavailable
    )
    XCTAssertEqual(
      CepessaSessionCaptureHealth.resolve(
        microphoneActive: false,
        microphoneMuted: true,
        systemAudioActive: false,
        hasError: false
      ),
      .unavailable
    )
  }

  // MARK: - State ring

  func testHealthyRecordingIsNeverPaintedWithASuccessState() {
    XCTAssertEqual(
      CepessaSessionIndicatorRing.resolve(
        mode: .recording, isRecording: true, health: .healthy, progress: nil),
      .recording
    )
    XCTAssertEqual(
      CepessaSessionIndicatorRing.resolve(
        mode: .recording, isRecording: true, health: .muted, progress: nil),
      .recordingMuted
    )
  }

  func testDegradedAndFaultyCaptureAreEncodedInTheRingShape() {
    XCTAssertEqual(
      CepessaSessionIndicatorRing.resolve(
        mode: .recording, isRecording: true, health: .partial, progress: nil),
      .degraded
    )
    XCTAssertEqual(
      CepessaSessionIndicatorRing.resolve(
        mode: .recording, isRecording: true, health: .unavailable, progress: nil),
      .fault
    )
  }

  func testIdleAndProcessingRingsIgnoreRecordingOnlyStates() {
    XCTAssertEqual(
      CepessaSessionIndicatorRing.resolve(
        mode: .idle, isRecording: false, health: .healthy, progress: nil),
      .idle
    )
    XCTAssertEqual(
      CepessaSessionIndicatorRing.resolve(
        mode: .processing, isRecording: false, health: .healthy, progress: 0.4),
      .processing(progress: 0.4)
    )
    XCTAssertEqual(
      CepessaSessionIndicatorRing.resolve(
        mode: .processing, isRecording: false, health: .healthy, progress: nil),
      .processing(progress: nil)
    )
    XCTAssertEqual(
      CepessaSessionIndicatorRing.resolve(
        mode: .idle, isRecording: false, health: .unavailable, progress: nil),
      .idle
    )
  }

  // MARK: - Timer

  func testTimerDropsTheHourFieldUnderOneHourAndUnpadsItAfter() {
    XCTAssertEqual(CepessaSessionIndicatorTimer.compactText(from: "00:00:07"), "00:07")
    XCTAssertEqual(CepessaSessionIndicatorTimer.compactText(from: "00:12:34"), "12:34")
    XCTAssertEqual(CepessaSessionIndicatorTimer.compactText(from: "01:02:03"), "1:02:03")
    XCTAssertEqual(CepessaSessionIndicatorTimer.compactText(from: "12:00:00"), "12:00:00")
  }

  func testTimerFallsBackToItsSourceWhenUnparsable() {
    XCTAssertEqual(CepessaSessionIndicatorTimer.compactText(from: "--:--"), "--:--")
    XCTAssertFalse(CepessaSessionIndicatorTimer.showsHours("--:--"))
  }

  func testShowsHoursDrivesTheSingleWidthChange() {
    XCTAssertFalse(CepessaSessionIndicatorTimer.showsHours("00:59:59"))
    XCTAssertTrue(CepessaSessionIndicatorTimer.showsHours("01:00:00"))
  }

  // MARK: - Tray status line

  func testTrayStatusReportsOnlyWhatTheAppActuallyKnows() {
    XCTAssertEqual(
      CepessaSessionIndicatorTrayStatus.text(
        isRecording: true,
        isTranscribing: false,
        hasFault: false,
        compactTimerText: "12:34",
        progress: nil
      ),
      "12:34"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorTrayStatus.text(
        isRecording: false,
        isTranscribing: true,
        hasFault: false,
        compactTimerText: "00:00",
        progress: 0.42
      ),
      "Transcribing 42%"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorTrayStatus.text(
        isRecording: false,
        isTranscribing: true,
        hasFault: false,
        compactTimerText: "00:00",
        progress: nil
      ),
      "Transcribing"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorTrayStatus.text(
        isRecording: false,
        isTranscribing: false,
        hasFault: false,
        compactTimerText: "00:00",
        progress: nil
      ),
      "Not recording"
    )
  }

  /// With nothing running every audio source is inactive, which resolves to
  /// `.unavailable` capture health. The idle tray must not read that as a
  /// problem — only the recorder's own error counts.
  func testIdleTrayNeverClaimsAProblemItDoesNotHave() {
    XCTAssertEqual(
      CepessaSessionCaptureHealth.resolve(
        microphoneActive: false, microphoneMuted: false, systemAudioActive: false, hasError: false),
      .unavailable
    )
    XCTAssertEqual(
      CepessaSessionIndicatorTrayStatus.text(
        isRecording: false,
        isTranscribing: false,
        hasFault: false,
        compactTimerText: "00:00",
        progress: nil
      ),
      "Not recording"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorTrayStatus.text(
        isRecording: false,
        isTranscribing: false,
        hasFault: true,
        compactTimerText: "00:00",
        progress: nil
      ),
      "Needs attention"
    )
  }

  func testANoticeOutranksEveryOtherStatusWhileItIsOnScreen() {
    XCTAssertEqual(
      CepessaSessionIndicatorTrayStatus.text(
        isRecording: true,
        isTranscribing: false,
        hasFault: true,
        compactTimerText: "12:34",
        progress: nil,
        notice: "Screenshot pinned at 12:34."
      ),
      "Screenshot pinned at 12:34."
    )
    // A blank notice is not a notice.
    XCTAssertEqual(
      CepessaSessionIndicatorTrayStatus.text(
        isRecording: true,
        isTranscribing: false,
        hasFault: false,
        compactTimerText: "12:34",
        progress: nil,
        notice: "   "
      ),
      "12:34"
    )
  }

  func testOnlyTheTimerHoldsAMonospacedWidth() {
    XCTAssertTrue(
      CepessaSessionIndicatorTrayStatus.usesMonospacedDigits(isRecording: true, hasNotice: false))
    XCTAssertFalse(
      CepessaSessionIndicatorTrayStatus.usesMonospacedDigits(isRecording: true, hasNotice: true))
    XCTAssertFalse(
      CepessaSessionIndicatorTrayStatus.usesMonospacedDigits(isRecording: false, hasNotice: false))
  }

  // MARK: - Shared status vocabulary

  func testClipsAndSessionsDescribeThemselvesWithTheSameVocabulary() {
    XCTAssertEqual(CepessaStatusStyle.resolve(LocalClipStatus.recording), .capturing)
    XCTAssertEqual(CepessaStatusStyle.resolve(LocalMeetingSessionStatus.recording), .capturing)
    XCTAssertEqual(CepessaStatusStyle.resolve(LocalClipStatus.processing), .working)
    XCTAssertEqual(CepessaStatusStyle.resolve(LocalMeetingSessionStatus.transcribing), .working)
    XCTAssertEqual(CepessaStatusStyle.resolve(LocalClipStatus.ready), .ready)
    XCTAssertEqual(CepessaStatusStyle.resolve(LocalMeetingSessionStatus.ready), .ready)
    XCTAssertEqual(CepessaStatusStyle.resolve(LocalClipStatus.failed), .needsAttention)
    XCTAssertEqual(CepessaStatusStyle.resolve(LocalMeetingSessionStatus.failed), .needsAttention)

    XCTAssertEqual(CepessaStatusStyle.needsAttention.label, "Needs attention")
    XCTAssertTrue(CepessaStatusStyle.capturing.isTransient)
    XCTAssertTrue(CepessaStatusStyle.working.isTransient)
    XCTAssertFalse(CepessaStatusStyle.ready.isTransient)
  }

  // MARK: - Accessibility

  func testIndicatorLabelDescribesCaptureHealthWhileRecording() {
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.indicatorLabel(
        mode: .recording,
        isRecording: true,
        health: .healthy,
        timerText: "00:04:07",
        progress: nil
      ),
      "Recording 4 minutes 7 seconds. Microphone and system audio are recording."
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.indicatorLabel(
        mode: .recording,
        isRecording: true,
        health: .muted,
        timerText: "00:00:05",
        progress: nil
      ),
      "Recording 5 seconds. Microphone muted; system audio is recording."
    )
  }

  func testIndicatorLabelCoversProcessingAndIdleStates() {
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.indicatorLabel(
        mode: .processing,
        isRecording: false,
        health: .healthy,
        timerText: "00:00:00",
        progress: 0.42
      ),
      "Transcribing, 42 percent complete."
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.indicatorLabel(
        mode: .processing,
        isRecording: false,
        health: .healthy,
        timerText: "00:00:00",
        progress: nil
      ),
      "Transcribing."
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.indicatorLabel(
        mode: .idle,
        isRecording: false,
        health: .healthy,
        timerText: "00:00:00",
        progress: nil
      ),
      "Sessions idle. Not recording."
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.indicatorLabel(
        mode: .idle,
        isRecording: false,
        health: .unavailable,
        timerText: "00:00:00",
        progress: nil
      ),
      "Sessions idle. Not recording."
    )
  }

  func testIndicatorValueAndHintTrackTheTrayState() {
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.indicatorValue(
        isRecording: true, timerText: "01:00:01", progress: nil),
      "1 hour 1 second"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.indicatorValue(
        isRecording: false, timerText: "00:00:00", progress: 0.5),
      "50 percent"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.indicatorValue(
        isRecording: false, timerText: "00:00:00", progress: nil),
      "Idle"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.indicatorHint(isTrayOpen: false),
      "Opens the recording controls."
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.indicatorHint(isTrayOpen: true),
      "Closes the recording controls. Press Escape to close."
    )
  }

  func testStatusItemIsMeaningfulInEveryState() {
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemLabel(
        isRecording: false, isTranscribing: false, hasFault: false),
      "Cepessa Sessions, idle"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemLabel(
        isRecording: true, isTranscribing: false, hasFault: false),
      "Cepessa Sessions, recording"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemLabel(
        isRecording: false, isTranscribing: true, hasFault: false),
      "Cepessa Sessions, transcribing"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemLabel(
        isRecording: true, isTranscribing: false, hasFault: true),
      "Cepessa Sessions, recording, needs attention"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemAction,
      "Open the Cepessa Sessions menu"
    )
  }

  func testHiddenIndicatorAlwaysAnnouncesTheReversiblePath() {
    let value = CepessaSessionIndicatorAccessibility.statusItemValue(
      isRecording: true,
      isTranscribing: false,
      hasFault: false,
      timerText: "00:02:00",
      progress: nil,
      indicatorHidden: true
    )

    XCTAssertEqual(
      value,
      "Recording 2 minutes 0 seconds. Floating indicator hidden; choose Show Recording Indicator to bring it back"
    )
  }

  func testStatusItemValueReportsProcessingAndIdleWithoutTheHiddenSuffix() {
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemValue(
        isRecording: false,
        isTranscribing: true,
        hasFault: false,
        timerText: "00:00:00",
        progress: 0.25,
        indicatorHidden: false
      ),
      "Transcribing 25 percent"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemValue(
        isRecording: false,
        isTranscribing: false,
        hasFault: false,
        timerText: "00:00:00",
        progress: nil,
        indicatorHidden: false
      ),
      "Not recording"
    )
    XCTAssertEqual(
      CepessaSessionIndicatorAccessibility.statusItemValue(
        isRecording: true,
        isTranscribing: false,
        hasFault: true,
        timerText: "00:02:00",
        progress: nil,
        indicatorHidden: false
      ),
      "Recording 2 minutes 0 seconds. Capture needs attention"
    )
  }
}
