import AppKit
import Combine
import SwiftUI

enum CepessaSessionStatusBarMode: Equatable {
  case idle
  case recording
  case transcribing
  case failed
  case transcriptReady

  /// Recording remains the primary visual contract even when capture needs
  /// attention. A warning can augment an active recording; it must never hide
  /// the timer or replace the stop affordance.
  static func resolve(
    isRecording: Bool,
    hasFault: Bool,
    isTranscribing: Bool
  ) -> Self {
    if isRecording {
      return .recording
    }
    if hasFault {
      return .failed
    }
    if isTranscribing {
      return .transcribing
    }
    return .idle
  }
}

struct CepessaSessionStatusBarSnapshot: Equatable {
  var mode: CepessaSessionStatusBarMode
  var title: String
  var detail: String
  var progress: Double?
  var canRetryLocal: Bool
  var queueCount: Int

  static let idle = CepessaSessionStatusBarSnapshot(
    mode: .idle,
    title: "Ready to record",
    detail: "Recordings and transcripts stay on this Mac.",
    progress: nil,
    canRetryLocal: false,
    queueCount: 0
  )

  @MainActor
  static func make(from model: LocalMeetingAppModel) -> Self {
    switch model.captureLifecycle.phase {
    case .starting:
      return CepessaSessionStatusBarSnapshot(
        mode: .transcribing,
        title: "Starting recording…",
        detail: "Preparing microphone and system audio capture.",
        progress: nil,
        canRetryLocal: false,
        queueCount: model.processingQueue.count
      )
    case .stopping:
      return CepessaSessionStatusBarSnapshot(
        mode: .transcribing,
        title: "Saving recording…",
        detail: "Finalizing local audio before transcription starts.",
        progress: nil,
        canRetryLocal: false,
        queueCount: model.processingQueue.count
      )
    case .idle, .recording:
      break
    }

    let lifecycleSessionIsRecording: Bool
    if case .recording = model.captureLifecycle.phase {
      lifecycleSessionIsRecording = true
    } else {
      lifecycleSessionIsRecording = false
    }
    let resolvedMode = CepessaSessionStatusBarMode.resolve(
      isRecording: model.isRecording || lifecycleSessionIsRecording,
      hasFault: model.recorderErrorMessage?.isEmpty == false,
      isTranscribing: model.isTranscribing
    )

    if resolvedMode == .recording {
      let captureWarning = model.recorderErrorMessage?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let detail: String
      if let captureWarning, !captureWarning.isEmpty {
        detail = "Capture needs attention: \(captureWarning)"
      } else {
        detail = "Microphone and system audio, on this Mac. The transcript is made when you stop."
      }

      return CepessaSessionStatusBarSnapshot(
        mode: .recording,
        title: "Recording \(model.recordingDurationText)",
        detail: detail,
        progress: nil,
        canRetryLocal: false,
        queueCount: model.processingQueue.count
      )
    }

    if resolvedMode == .failed, let error = model.recorderErrorMessage, !error.isEmpty {
      return CepessaSessionStatusBarSnapshot(
        mode: .failed,
        title: "Transcription needs attention",
        detail: error,
        progress: nil,
        canRetryLocal: model.selectedSession.map { model.canRetranscribe($0) } ?? false,
        queueCount: model.processingQueue.count
      )
    }

    if resolvedMode == .transcribing {
      return CepessaSessionStatusBarSnapshot(
        mode: .transcribing,
        title: model.processingStatusTitle ?? "Transcribing",
        detail: model.processingStatusDetail ?? "Preparing a local transcript.",
        progress: model.processingProgress,
        canRetryLocal: false,
        queueCount: model.processingQueue.count
      )
    }

    return .idle
  }
}

/// The menu-bar item: the recorder's orb drawn small, the live timer or
/// progress beside it, and the same night-glass menu the capsule uses.
@MainActor
final class CepessaSessionStatusBarController: NSObject {
  static let shared = CepessaSessionStatusBarController()

  private var statusItem: NSStatusItem?
  private weak var model: LocalMeetingAppModel?
  private var cancellables: Set<AnyCancellable> = []
  private var snapshot = CepessaSessionStatusBarSnapshot.idle
  private var isMenuOpen = false
  private var captureLifecycle: LocalCaptureLifecycle {
    CepessaSessionsStore.shared.captureLifecycle
  }

  func connect(model: LocalMeetingAppModel) {
    if self.model !== model {
      self.model = model
      bind(to: model)
    }
    ensureStatusItem()
    refresh()
  }

  func toggleRecording() {
    switch CepessaSessionCaptureControlPolicy.resolve(captureLifecycle.phase) {
    case .startSession, .cancelSessionStart, .stopSession:
      model?.toggleRecording()
    case .unavailable:
      return
    }
  }

  func openMainWindow() {
    CepessaSessionsWindowController.shared.showLibrary()
  }

  func retryLocalTranscription() {
    guard let sessionID = model?.selectedSessionID else { return }
    model?.retranscribeSession(id: sessionID)
  }

  func refreshAccessibilityState() {
    refresh()
  }

  private func bind(to model: LocalMeetingAppModel) {
    cancellables.removeAll()
    let publishers: [AnyPublisher<Void, Never>] = [
      model.$sessions.map { _ in () }.eraseToAnyPublisher(),
      model.$selectedSessionID.map { _ in () }.eraseToAnyPublisher(),
      model.$isRecording.map { _ in () }.eraseToAnyPublisher(),
      model.$isTranscribing.map { _ in () }.eraseToAnyPublisher(),
      model.$recordingDurationText.map { _ in () }.eraseToAnyPublisher(),
      model.$recorderErrorMessage.map { _ in () }.eraseToAnyPublisher(),
      model.$processingStatusTitle.map { _ in () }.eraseToAnyPublisher(),
      model.$processingStatusDetail.map { _ in () }.eraseToAnyPublisher(),
      model.$processingProgress.map { _ in () }.eraseToAnyPublisher(),
      model.$processingSnapshots.map { _ in () }.eraseToAnyPublisher(),
      captureLifecycle.$phase.map { _ in () }.eraseToAnyPublisher(),
    ]

    Publishers.MergeMany(publishers)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.refresh() }
      .store(in: &cancellables)
  }

  private func ensureStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.target = self
    item.button?.action = #selector(statusItemClicked)
    item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
    item.button?.imagePosition = .imageLeading
    statusItem = item
  }

  private func refresh() {
    guard let model else { return }
    snapshot = CepessaSessionStatusBarSnapshot.make(from: model)

    if let button = statusItem?.button {
      button.image = CepessaSessionStatusBarGlyph.image(
        for: snapshot.mode, progress: snapshot.progress)
      let suffix = titleSuffix(for: snapshot)
      button.attributedTitle = NSAttributedString(
        string: suffix,
        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)])
      button.toolTip = "\(snapshot.title) — \(snapshot.detail)"
      applyAccessibility(to: button, model: model)
    }
    if isMenuOpen {
      CepessaSessionCapsuleMenuController.shared.update(items: menuItems())
    }
  }

  /// The status item is the only surface guaranteed to exist in every state —
  /// including when the floating indicator has been hidden mid-recording — so
  /// it has to speak the full situation, and the way back, on its own.
  private func applyAccessibility(to button: NSStatusBarButton, model: LocalMeetingAppModel) {
    switch captureLifecycle.phase {
    case .starting:
      let label = "Cepessa Sessions, starting recording"
      button.setAccessibilityLabel(label)
      button.setAccessibilityTitle(label)
      button.setAccessibilityValue(snapshot.detail)
      button.setAccessibilityHelp(CepessaSessionIndicatorAccessibility.statusItemAction)
      return
    case .stopping:
      let label = "Cepessa Sessions, stopping recording"
      button.setAccessibilityLabel(label)
      button.setAccessibilityTitle(label)
      button.setAccessibilityValue(snapshot.detail)
      button.setAccessibilityHelp(CepessaSessionIndicatorAccessibility.statusItemAction)
      return
    case .idle, .recording:
      break
    }

    let hasFault = model.recorderErrorMessage?.isEmpty == false
    let indicatorHidden =
      model.isRecording && !CepessaSessionFloatingBarController.shared.isBarVisible

    let label = CepessaSessionIndicatorAccessibility.statusItemLabel(
      isRecording: model.isRecording,
      isTranscribing: model.isTranscribing,
      hasFault: hasFault
    )
    button.setAccessibilityLabel(label)
    button.setAccessibilityTitle(label)
    button.setAccessibilityValue(
      CepessaSessionIndicatorAccessibility.statusItemValue(
        isRecording: model.isRecording,
        isTranscribing: model.isTranscribing,
        hasFault: hasFault,
        timerText: model.recordingDurationText,
        progress: snapshot.progress,
        indicatorHidden: indicatorHidden
      )
    )
    button.setAccessibilityHelp(CepessaSessionIndicatorAccessibility.statusItemAction)
  }

  // MARK: - Menu

  @objc private func statusItemClicked() {
    let menu = CepessaSessionCapsuleMenuController.shared
    // A click on the item while its menu is open means "close".
    guard !menu.wasJustClosedByClick, !isMenuOpen,
      let button = statusItem?.button, let window = button.window
    else { return }
    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
    button.highlight(true)
    isMenuOpen = true
    menu.open(items: menuItems(), below: anchor.insetBy(dx: 0, dy: -2), alignLeading: true) {
      [weak self] in
      self?.isMenuOpen = false
      self?.statusItem?.button?.highlight(false)
    }
  }

  func menuItems() -> [CepessaSessionCapsuleMenuItem] {
    var items: [CepessaSessionCapsuleMenuItem] = [
      .status(
        snapshot.title,
        detail: snapshot.detail,
        progress: snapshot.mode == .transcribing ? snapshot.progress : nil,
        tone: statusTone),
      .separator,
    ]
    let isRecording = model?.isRecording == true
    let barVisible = CepessaSessionFloatingBarController.shared.isBarVisible

    // A hidden recorder must never become a dead end: while capture is live
    // the way back sits at the top of the menu, not buried under it.
    if isRecording && !barVisible {
      items.append(.action("Show Recorder", symbol: "capsule") { [weak self] in
        self?.toggleBar()
      })
    }

    switch CepessaSessionCaptureControlPolicy.resolve(captureLifecycle.phase) {
    case .startSession:
      items.append(.action("Start Recording", symbol: "record.circle") { [weak self] in
        self?.toggleRecording()
      })
    case .stopSession:
      items.append(.action("Stop Recording", symbol: "stop.fill") { [weak self] in
        self?.toggleRecording()
      })
    case .cancelSessionStart:
      items.append(.action("Cancel Starting Recording", symbol: "xmark") { [weak self] in
        self?.toggleRecording()
      })
    case .unavailable:
      items.append(.action("Stopping Recording…", symbol: "hourglass", isEnabled: false) {})
    }

    if snapshot.mode == .failed && snapshot.canRetryLocal {
      items.append(.action("Transcribe Again", symbol: "arrow.clockwise") { [weak self] in
        self?.retryLocalTranscription()
      })
    }
    items.append(.separator)

    let sessions = Array((model?.sessions ?? []).prefix(5))
    if !sessions.isEmpty {
      items.append(.header("Recent"))
      for session in sessions {
        items.append(
          .action(
            session.displayTitle,
            detail: session.startedAt.formatted(date: .omitted, time: .shortened),
            key: session.id.uuidString
          ) {
            CepessaSessionsWindowController.shared.showSession(id: session.id)
          })
      }
      items.append(.separator)
    }

    items.append(.action("All Sessions", symbol: "rectangle.stack", detail: "⌘O") {
      CepessaSessionsWindowController.shared.showLibrary()
    })
    items.append(.action("Import Audio…", symbol: "square.and.arrow.down") {
      CepessaSessionsWindowController.shared.importAudio()
    })
    items.append(.separator)
    if !isRecording || barVisible {
      items.append(
        .action(
          barVisible ? "Hide Recorder" : "Show Recorder",
          symbol: barVisible ? "eye.slash" : "capsule"
        ) { [weak self] in self?.toggleBar() })
    }
    items.append(.action("Settings…", symbol: "gearshape", detail: "⌘,") {
      CepessaSessionsWindowController.shared.openSettings()
    })
    items.append(.action("Quit Cepessa Sessions", symbol: "power") {
      NSApp.terminate(nil)
    })
    return items
  }

  private var statusTone: CepessaSessionCapsuleMenuItem.StatusTone {
    switch snapshot.mode {
    case .idle, .transcriptReady: return .quiet
    case .recording: return .recording
    case .transcribing: return .working
    case .failed: return .attention
    }
  }

  private func toggleBar() {
    let controller = CepessaSessionFloatingBarController.shared
    if controller.isBarVisible {
      controller.dismissForCurrentRecording()
    } else {
      controller.showBar()
    }
  }

  // MARK: - Title

  private func titleSuffix(for snapshot: CepessaSessionStatusBarSnapshot) -> String {
    switch snapshot.mode {
    case .idle, .failed, .transcriptReady:
      return ""
    case .recording:
      let raw = snapshot.title.split(separator: " ").last.map(String.init) ?? snapshot.title
      return " \(CepessaSessionIndicatorTimer.compactText(from: raw))"
    case .transcribing:
      return snapshot.progress.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
    }
  }
}

/// The recorder's orb at menu-bar size: a ring around a core. Drawn, not a
/// scaled symbol, so it stays crisp at 18 pt.
///
/// - Rest: the record mark, as a template that follows the menu bar.
/// - Recording: the core turns recording red; the one state in colour,
///   because it is the one the owner must never miss.
/// - Transcribing: the ring becomes a track and fills with real progress
///   (a fixed quarter when there is none to report).
/// - Needs attention: the record mark with a small mark beside it.
enum CepessaSessionStatusBarGlyph {
  static func image(for mode: CepessaSessionStatusBarMode, progress: Double?) -> NSImage {
    let hasBadge = mode == .failed
    let size = NSSize(width: hasBadge ? 24 : 18, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
      let center = NSPoint(x: 9, y: 9)
      let ringRadius: CGFloat = 6.4
      let ringRect = NSRect(
        x: center.x - ringRadius, y: center.y - ringRadius,
        width: ringRadius * 2, height: ringRadius * 2)
      let ink: NSColor = mode == .recording ? .labelColor : .black

      switch mode {
      case .transcribing:
        ink.withAlphaComponent(0.3).setStroke()
        let track = NSBezierPath(ovalIn: ringRect)
        track.lineWidth = 1.5
        track.stroke()
        let fraction = CGFloat(min(max(progress ?? 0.25, 0.04), 1))
        let arc = NSBezierPath()
        arc.appendArc(
          withCenter: center, radius: ringRadius, startAngle: 90,
          endAngle: 90 - 360 * fraction, clockwise: true)
        arc.lineWidth = 1.9
        arc.lineCapStyle = .round
        ink.setStroke()
        arc.stroke()
      default:
        ink.setStroke()
        let ring = NSBezierPath(ovalIn: ringRect)
        ring.lineWidth = 1.5
        ring.stroke()
      }

      let coreRadius: CGFloat = mode == .recording ? 3.4 : 2.8
      let core = NSBezierPath(
        ovalIn: NSRect(
          x: center.x - coreRadius, y: center.y - coreRadius,
          width: coreRadius * 2, height: coreRadius * 2))
      (mode == .recording ? NSColor(SessionsPalette.recording) : ink).setFill()
      core.fill()

      if hasBadge {
        ink.setStroke()
        ink.setFill()
        let bar = NSBezierPath()
        bar.lineWidth = 1.7
        bar.lineCapStyle = .round
        bar.move(to: NSPoint(x: 21.5, y: 13))
        bar.line(to: NSPoint(x: 21.5, y: 8.2))
        bar.stroke()
        NSBezierPath(ovalIn: NSRect(x: 20.6, y: 4.3, width: 1.8, height: 1.8)).fill()
      }
      return true
    }
    image.isTemplate = mode != .recording
    image.accessibilityDescription = "Sessions"
    return image
  }
}
