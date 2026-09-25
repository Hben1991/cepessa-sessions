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
    title: "Sessions ready",
    detail: "Start or monitor a local session from the status bar.",
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
        detail = "Capturing local audio. Stop recording to run the final transcript pass."
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

/// Status bar item with a plain native menu. The former glass popover
/// (queue rows, live log feed) is gone; progress reads as menu text and the
/// full trace stays available in the sessions window.
@MainActor
final class CepessaSessionStatusBarController: NSObject, NSMenuDelegate {
  static let shared = CepessaSessionStatusBarController()

  private var statusItem: NSStatusItem?
  private weak var model: LocalMeetingAppModel?
  private var cancellables: Set<AnyCancellable> = []
  private var snapshot = CepessaSessionStatusBarSnapshot.idle
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
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    statusItem = item
  }

  private func refresh() {
    guard let model else { return }
    snapshot = CepessaSessionStatusBarSnapshot.make(from: model)

    if let button = statusItem?.button {
      button.image = statusImage(for: snapshot.mode)
      button.title = titleSuffix(for: snapshot)
      button.toolTip = "\(snapshot.title) - \(snapshot.detail)"
      applyAccessibility(to: button, model: model)
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

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    let status = NSMenuItem(title: snapshot.title, action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)

    if snapshot.queueCount > 1 {
      let queue = NSMenuItem(
        title: "\(snapshot.queueCount) sessions in the processing queue",
        action: nil, keyEquivalent: "")
      queue.isEnabled = false
      menu.addItem(queue)
    }

    menu.addItem(.separator())

    let isRecording = model?.isRecording == true

    // A hidden recorder must never become a dead end: while capture is live
    // the way back sits at the top of the menu, not buried under it.
    if isRecording && !CepessaSessionFloatingBarController.shared.isBarVisible {
      let reveal = NSMenuItem(
        title: "Show Recorder",
        action: #selector(toggleBarMenuItem),
        keyEquivalent: ""
      )
      reveal.target = self
      menu.addItem(reveal)
      menu.addItem(.separator())
    }

    switch CepessaSessionCaptureControlPolicy.resolve(captureLifecycle.phase) {
    case .cancelSessionStart:
      let record = NSMenuItem(
        title: "Cancel Starting Recording",
        action: #selector(recordMenuItem),
        keyEquivalent: ""
      )
      record.target = self
      menu.addItem(record)
    case .stopSession:
      let record = NSMenuItem(
        title: "Stop Recording",
        action: #selector(recordMenuItem),
        keyEquivalent: ""
      )
      record.target = self
      menu.addItem(record)
    case .unavailable:
      let stopping = NSMenuItem(
        title: "Stopping Recording…",
        action: nil,
        keyEquivalent: ""
      )
      stopping.isEnabled = false
      menu.addItem(stopping)
    case .startSession:
      let record = NSMenuItem(
        title: "Start Recording",
        action: #selector(recordMenuItem),
        keyEquivalent: ""
      )
      record.target = self
      menu.addItem(record)
    }

    if snapshot.mode == .failed && snapshot.canRetryLocal {
      let retry = NSMenuItem(
        title: "Retry Transcription",
        action: #selector(retryMenuItem),
        keyEquivalent: ""
      )
      retry.target = self
      menu.addItem(retry)
    }

    menu.addItem(.separator())

    let sessions = Array((model?.sessions ?? []).prefix(5))
    if !sessions.isEmpty {
      for session in sessions {
        let item = NSMenuItem(
          title: session.displayTitle,
          action: #selector(openSessionMenuItem(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.representedObject = session.id
        menu.addItem(item)
      }
      menu.addItem(.separator())
    }

    let library = NSMenuItem(
      title: "All Sessions", action: #selector(openWindowMenuItem), keyEquivalent: "")
    library.target = self
    menu.addItem(library)

    let importAudio = NSMenuItem(
      title: "Import Audio…", action: #selector(importAudioMenuItem), keyEquivalent: "")
    importAudio.target = self
    menu.addItem(importAudio)

    menu.addItem(.separator())

    let barVisible = CepessaSessionFloatingBarController.shared.isBarVisible
    if !isRecording || barVisible {
      let toggleBar = NSMenuItem(
        title: barVisible ? "Hide Recorder" : "Show Recorder",
        action: #selector(toggleBarMenuItem),
        keyEquivalent: ""
      )
      toggleBar.target = self
      menu.addItem(toggleBar)
    }

    let settings = NSMenuItem(
      title: "Settings…", action: #selector(settingsMenuItem), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)

    menu.addItem(.separator())

    let quit = NSMenuItem(
      title: "Quit Cepessa Sessions", action: #selector(quitMenuItem), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
  }

  @objc private func recordMenuItem() {
    toggleRecording()
  }

  @objc private func retryMenuItem() {
    retryLocalTranscription()
  }

  @objc private func openSessionMenuItem(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    CepessaSessionsWindowController.shared.showSession(id: id)
  }

  @objc private func openWindowMenuItem() {
    CepessaSessionsWindowController.shared.showLibrary()
  }

  @objc private func importAudioMenuItem() {
    CepessaSessionsWindowController.shared.importAudio()
  }

  @objc private func toggleBarMenuItem() {
    let controller = CepessaSessionFloatingBarController.shared
    if controller.isBarVisible {
      controller.dismissForCurrentRecording()
    } else {
      controller.showBar()
    }
  }

  @objc private func settingsMenuItem() {
    CepessaSessionsWindowController.shared.openSettings()
  }

  @objc private func quitMenuItem() {
    NSApp.terminate(nil)
  }

  // MARK: - Icon

  private func titleSuffix(for snapshot: CepessaSessionStatusBarSnapshot) -> String {
    switch snapshot.mode {
    case .idle:
      return ""
    case .recording:
      let raw = snapshot.title.split(separator: " ").last.map(String.init) ?? snapshot.title
      return " \(CepessaSessionIndicatorTimer.compactText(from: raw))"
    case .transcribing:
      return snapshot.progress.map { " \(Int(($0 * 100).rounded()))%" } ?? " ..."
    case .failed:
      return " !"
    case .transcriptReady:
      return " Ready"
    }
  }

  private func statusImage(for mode: CepessaSessionStatusBarMode) -> NSImage? {
    // Two opposing voice strokes form the Sessions S. Draw at menu-bar size
    // instead of scaling a document or microphone symbol down to fit.
    let width: CGFloat = mode == .idle ? 18 : 25
    let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
      NSColor.black.setStroke()
      NSColor.black.setFill()
      let voices = NSBezierPath()
      voices.lineWidth = 2.25
      voices.lineCapStyle = .round
      voices.lineJoinStyle = .round
      voices.move(to: NSPoint(x: 14.25, y: 13.75))
      voices.line(to: NSPoint(x: 7.5, y: 13.75))
      voices.curve(
        to: NSPoint(x: 7.5, y: 9.75),
        controlPoint1: NSPoint(x: 2.75, y: 13.75),
        controlPoint2: NSPoint(x: 2.75, y: 9.75))
      voices.line(to: NSPoint(x: 10.5, y: 9.75))
      voices.move(to: NSPoint(x: 3.75, y: 4.25))
      voices.line(to: NSPoint(x: 10.5, y: 4.25))
      voices.curve(
        to: NSPoint(x: 10.5, y: 8.25),
        controlPoint1: NSPoint(x: 15.25, y: 4.25),
        controlPoint2: NSPoint(x: 15.25, y: 8.25))
      voices.line(to: NSPoint(x: 7.5, y: 8.25))
      voices.stroke()

      let badge = NSBezierPath()
      badge.lineWidth = 1.5
      badge.lineCapStyle = .round
      badge.lineJoinStyle = .round
      switch mode {
      case .idle:
        break
      case .recording:
        NSBezierPath(ovalIn: NSRect(x: 19, y: 6.5, width: 5, height: 5)).fill()
      case .transcribing:
        for y: CGFloat in [5.5, 8.5, 11.5] {
          NSBezierPath(ovalIn: NSRect(x: 20.5, y: y, width: 1.5, height: 1.5)).fill()
        }
      case .failed:
        badge.move(to: NSPoint(x: 21.5, y: 12))
        badge.line(to: NSPoint(x: 21.5, y: 8.5))
        badge.stroke()
        NSBezierPath(ovalIn: NSRect(x: 20.75, y: 5, width: 1.5, height: 1.5)).fill()
      case .transcriptReady:
        badge.move(to: NSPoint(x: 19, y: 8.5))
        badge.line(to: NSPoint(x: 20.75, y: 6.75))
        badge.line(to: NSPoint(x: 24, y: 11))
        badge.stroke()
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Sessions"
    return image
  }
}
