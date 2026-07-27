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
  static func make(from model: LocalMeetingAppModel, clipModel: LocalClipViewModel) -> Self {
    if clipModel.isRecording {
      return CepessaSessionStatusBarSnapshot(
        mode: .recording,
        title: "Clip recording \(clipModel.recordingDurationText)",
        detail: "Capturing the screen and local audio for a clip.",
        progress: nil,
        canRetryLocal: false,
        queueCount: model.processingQueue.count
      )
    }

    let resolvedMode = CepessaSessionStatusBarMode.resolve(
      isRecording: model.isRecording,
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
  private var clipModel: LocalClipViewModel {
    CepessaSessionsStore.shared.clipModel
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
    guard !clipModel.isRecording else { return }
    model?.toggleRecording()
  }

  func stopClipRecording() {
    clipModel.stopClip()
  }

  func openMainWindow() {
    CepessaSessionsWindowController.shared.show(destination: .sessions)
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
      clipModel.$isRecording.map { _ in () }.eraseToAnyPublisher(),
      clipModel.$recordingDurationText.map { _ in () }.eraseToAnyPublisher(),
      clipModel.$statusMessage.map { _ in () }.eraseToAnyPublisher(),
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
    snapshot = CepessaSessionStatusBarSnapshot.make(from: model, clipModel: clipModel)

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
    if clipModel.isRecording {
      let label = "Cepessa Sessions, clip recording"
      button.setAccessibilityLabel(label)
      button.setAccessibilityTitle(label)
      button.setAccessibilityValue(
        "Clip recording "
          + CepessaSessionIndicatorAccessibility.compactSpokenTimer(
            clipModel.recordingDurationText))
      button.setAccessibilityHelp(CepessaSessionIndicatorAccessibility.statusItemAction)
      return
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
    let isClipRecording = clipModel.isRecording

    // A hidden indicator must never become a dead end: while capture is live
    // the way back sits at the top of the menu, not buried under it.
    if isRecording && !CepessaSessionFloatingBarController.shared.isBarVisible {
      let reveal = NSMenuItem(
        title: "Show Recording Indicator",
        action: #selector(toggleBarMenuItem),
        keyEquivalent: ""
      )
      reveal.target = self
      menu.addItem(reveal)
      menu.addItem(.separator())
    }

    if isClipRecording {
      let stopClip = NSMenuItem(
        title: "Stop Clip Recording",
        action: #selector(stopClipMenuItem),
        keyEquivalent: ""
      )
      stopClip.target = self
      menu.addItem(stopClip)
    } else {
      let record = NSMenuItem(
        title: isRecording ? "Stop Recording" : "Start Recording",
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

    let clips = NSMenuItem(
      title: "Clips", action: #selector(openClipsMenuItem), keyEquivalent: "")
    clips.target = self
    menu.addItem(clips)

    let importAudio = NSMenuItem(
      title: "Import Audio…", action: #selector(importAudioMenuItem), keyEquivalent: "")
    importAudio.target = self
    menu.addItem(importAudio)

    menu.addItem(.separator())

    let barVisible = CepessaSessionFloatingBarController.shared.isBarVisible
    if !isRecording || barVisible {
      let toggleBar = NSMenuItem(
        title: barVisible ? "Hide Recording Indicator" : "Show Recording Indicator",
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

  @objc private func stopClipMenuItem() {
    stopClipRecording()
  }

  @objc private func retryMenuItem() {
    retryLocalTranscription()
  }

  @objc private func openSessionMenuItem(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    CepessaSessionsWindowController.shared.showSession(id: id)
  }

  @objc private func openWindowMenuItem() {
    CepessaSessionsWindowController.shared.show(destination: .sessions)
  }

  @objc private func openClipsMenuItem() {
    CepessaSessionsWindowController.shared.show(destination: .clips)
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
    let symbolNames: [String]
    switch mode {
    case .idle:
      symbolNames = ["text.bubble", "quote.bubble", "waveform"]
    case .recording:
      symbolNames = ["record.circle.fill", "mic.circle.fill"]
    case .transcribing:
      symbolNames = ["text.magnifyingglass", "waveform.badge.magnifyingglass", "waveform"]
    case .failed:
      symbolNames = ["exclamationmark.bubble.fill", "exclamationmark.triangle.fill"]
    case .transcriptReady:
      symbolNames = ["text.bubble.fill", "checkmark.circle.fill"]
    }

    let image = symbolNames.lazy.compactMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: "Sessions")
    }.first
    image?.isTemplate = mode != .failed
    return image
  }
}
