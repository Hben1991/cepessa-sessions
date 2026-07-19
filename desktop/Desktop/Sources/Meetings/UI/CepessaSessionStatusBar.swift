import AppKit
import Combine
import SwiftUI

enum CepessaSessionStatusBarMode: Equatable {
  case idle
  case recording
  case transcribing
  case failed
  case transcriptReady
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
    if let error = model.recorderErrorMessage, !error.isEmpty {
      return CepessaSessionStatusBarSnapshot(
        mode: .failed,
        title: "Transcription needs attention",
        detail: error,
        progress: nil,
        canRetryLocal: model.selectedSession.map { model.canRetranscribe($0) } ?? false,
        queueCount: model.processingQueue.count
      )
    }

    if model.isRecording {
      return CepessaSessionStatusBarSnapshot(
        mode: .recording,
        title: "Recording \(model.recordingDurationText)",
        detail: "Capturing local audio. Stop recording to run the final transcript pass.",
        progress: nil,
        canRetryLocal: false,
        queueCount: model.processingQueue.count
      )
    }

    if model.isTranscribing {
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

  func connect(model: LocalMeetingAppModel) {
    if self.model !== model {
      self.model = model
      bind(to: model)
    }
    ensureStatusItem()
    refresh()
  }

  func toggleRecording() {
    model?.toggleRecording()
  }

  func openMainWindow() {
    CepessaSessionsWindowController.shared.show(destination: .sessions)
  }

  func retryLocalTranscription() {
    guard let sessionID = model?.selectedSessionID else { return }
    model?.retranscribeSession(id: sessionID)
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
    }
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
    let record = NSMenuItem(
      title: isRecording ? "Stop Recording" : "Start Recording",
      action: #selector(recordMenuItem),
      keyEquivalent: ""
    )
    record.target = self
    menu.addItem(record)

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
    let toggleBar = NSMenuItem(
      title: barVisible ? "Hide Floating Bar" : "Show Floating Bar",
      action: #selector(toggleBarMenuItem),
      keyEquivalent: ""
    )
    toggleBar.target = self
    menu.addItem(toggleBar)

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
      return " \(snapshot.title.replacingOccurrences(of: "Recording ", with: ""))"
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
