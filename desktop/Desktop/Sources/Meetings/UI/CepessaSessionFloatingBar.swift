import AppKit
import Combine
import SwiftUI

@MainActor
final class CepessaSessionsStore {
  static let shared = CepessaSessionsStore()

  let model: LocalMeetingAppModel

  private init() {
    self.model = LocalMeetingAppModel()
  }
}

enum CepessaSessionFloatingBarPreferences {
  static let enabledKey = "cepessa.sessions.floatingBarEnabled"
  static let legacyDefaultOffMigrationKey = "cepessa.sessions.floatingBarDefaultOffMigrated"
  static let defaultOnMigrationKey = "cepessa.sessions.floatingBarDefaultOnMigrated"

  static func installDefaults(in defaults: UserDefaults = .standard) {
    defaults.register(defaults: [
      enabledKey: true,
      legacyDefaultOffMigrationKey: true,
      defaultOnMigrationKey: false,
      "cepessa.sessions.floatingBarAttachmentDeckHidden": true,
    ])

    guard !defaults.bool(forKey: defaultOnMigrationKey) else { return }

    let hasStoredPreference = defaults.object(forKey: enabledKey) != nil
    let wasMovedOffByLegacyMigration = defaults.bool(forKey: legacyDefaultOffMigrationKey)
    if !hasStoredPreference || wasMovedOffByLegacyMigration {
      defaults.set(true, forKey: enabledKey)
    }
    defaults.set(true, forKey: defaultOnMigrationKey)
  }
}

@MainActor
final class CepessaSessionFloatingBarState: ObservableObject {
  enum NoticeStyle: Equatable {
    case neutral
    case success
    case warning
    case error
  }

  @Published var isVisible = false
  @Published var isRecording = false
  @Published var isTranscribing = false
  @Published var isMicrophoneCaptureActive = false
  @Published var isMicrophoneMuted = false
  @Published var isSystemAudioCaptureActive = false
  @Published var timerText = "00:00"
  @Published var micLevel: Double = 0
  @Published var systemLevel: Double = 0
  @Published var title = "Start a session to see the live bar."
  @Published var statusMessage = "Local capture stays on this Mac."
  @Published var errorMessage: String?
  @Published var noticeMessage: String?
  @Published var noticeStyle: NoticeStyle = .neutral
  @Published var isDismissedForCurrentRecording = false
  @Published var barContentWidth: CGFloat =
    CepessaSessionFloatingBarController.Constants.preferredBarContentWidth
  @Published var processingStatusTitle: String?
  @Published var processingStatusDetail: String?
  @Published var processingProgress: Double?
  @Published var processingQueue: [CepessaSessionFloatingProcessingItem] = []
  @Published var attachmentDeck = CepessaSessionFloatingAttachmentDeck.empty
  @Published var isAttachmentDeckExpanded = true
  /// Rolling audio-level history driving the live waveform (newest last).
  @Published var levelHistory: [Double] = []

  var accentColor: Color {
    if noticeStyle == .error || errorMessage?.isEmpty == false {
      return CepessaColors.warning
    }

    if isRecording {
      return CepessaColors.success
    }

    if isTranscribing {
      return CepessaColors.purplePrimary
    }

    return CepessaColors.textTertiary
  }
}

@MainActor
final class CepessaSessionFloatingBarController: NSObject, NSWindowDelegate {
  static let shared = CepessaSessionFloatingBarController()

  fileprivate enum Constants {
    static let preferredBarContentWidth: CGFloat = 860
    static let minimumBarContentWidth: CGFloat = 620
    static let maximumBarContentWidth: CGFloat = 920
    static let idleBarContentWidth: CGFloat = 336
    static let processingBarContentWidth: CGFloat = 360
    static let panelHorizontalPadding: CGFloat = 20
    static let compactBarHeight: CGFloat = 78
    static let idleBarHeight: CGFloat = 64
    static let expandedBarHeight: CGFloat = 152
    static let recordingPillHeight: CGFloat = 58
    static let idlePillHeight: CGFloat = 48
    static let positionKey = "CepessaSessionsFloatingBarPosition"
    static let attachmentsFolder = "Attachments"
    static let enabledKey = CepessaSessionFloatingBarPreferences.enabledKey
    static let attachmentDeckHiddenKey = "cepessa.sessions.floatingBarAttachmentDeckHidden"
  }

  let state = CepessaSessionFloatingBarState()

  private weak var model: LocalMeetingAppModel?
  private var panel: NSPanel?
  private var hostingView: NSHostingView<CepessaSessionFloatingBarView>?
  private var cancellables: Set<AnyCancellable> = []
  private var liveSessionSnapshot: LocalSession?
  private var liveSessionID: UUID?
  private var applyingLiveSessionSnapshot = false
  private var noticeDismissTask: Task<Void, Never>?
  private var lastLevelSampleAt: TimeInterval = 0

  fileprivate var currentPanel: NSWindow? {
    panel
  }

  func connect(model: LocalMeetingAppModel) {
    CepessaSessionFloatingBarPreferences.installDefaults()

    if self.model !== model {
      self.model = model
      bind(to: model)
    }

    ensurePanel()
    refreshState()
    syncVisibility()
  }

  func disconnect(model: LocalMeetingAppModel) {
    guard self.model === model else { return }
    self.model = nil
    cancellables.removeAll()
    liveSessionSnapshot = nil
    liveSessionID = nil
    noticeDismissTask?.cancel()
    state.noticeMessage = nil
    state.isVisible = false
    panel?.orderOut(nil)
  }

  func stopRecording() {
    model?.toggleRecording()
  }

  func startRecording() {
    guard model?.isRecording != true else { return }
    model?.toggleRecording()
  }

  /// Re-shows the bar after the user hid it with the close button.
  func showBar() {
    state.isDismissedForCurrentRecording = false
    UserDefaults.standard.set(true, forKey: Constants.enabledKey)
    syncVisibility()
  }

  var isBarVisible: Bool {
    state.isVisible
  }

  func showBarMenu() {
    let menu = NSMenu()

    let sessions = Array((model?.sessions ?? []).prefix(5))
    if sessions.isEmpty {
      let empty = NSMenuItem(title: "No sessions yet", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    } else {
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
    }

    menu.addItem(.separator())

    let library = NSMenuItem(
      title: "All Sessions", action: #selector(openLibraryMenuItem), keyEquivalent: "")
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

    let settings = NSMenuItem(
      title: "Settings…", action: #selector(openSettingsMenuItem), keyEquivalent: "")
    settings.target = self
    menu.addItem(settings)

    menu.addItem(.separator())

    let hide = NSMenuItem(
      title: "Hide Floating Bar", action: #selector(hideBarMenuItem), keyEquivalent: "")
    hide.target = self
    menu.addItem(hide)

    let quit = NSMenuItem(
      title: "Quit Cepessa Sessions", action: #selector(quitMenuItem), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)

    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }

  @objc private func openSessionMenuItem(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    CepessaSessionsWindowController.shared.showSession(id: id)
  }

  @objc private func openLibraryMenuItem() {
    CepessaSessionsWindowController.shared.show(destination: .sessions)
  }

  @objc private func openClipsMenuItem() {
    CepessaSessionsWindowController.shared.show(destination: .clips)
  }

  @objc private func importAudioMenuItem() {
    CepessaSessionsWindowController.shared.importAudio()
  }

  @objc private func openSettingsMenuItem() {
    CepessaSessionsWindowController.shared.openSettings()
  }

  @objc private func hideBarMenuItem() {
    dismissForCurrentRecording()
  }

  @objc private func quitMenuItem() {
    NSApp.terminate(nil)
  }

  func toggleMicrophoneMute() {
    model?.toggleMicrophoneMute()
  }

  func dismissForCurrentRecording() {
    state.isDismissedForCurrentRecording = true
    syncVisibility()
  }

  func toggleAttachmentDeckVisibility() {
    let shouldHide = state.isAttachmentDeckExpanded
    UserDefaults.standard.set(shouldHide, forKey: Constants.attachmentDeckHiddenKey)
    state.isAttachmentDeckExpanded = !shouldHide
    updatePanelSize(animated: true)
  }

  func captureFullScreenshot() {
    let screens = NSScreen.screens
    guard screens.count > 1 else {
      Task { @MainActor in
        await captureScreenshot(interactive: false, display: nil)
      }
      return
    }

    // Multiple displays: let the user pick which screen to capture.
    let menu = NSMenu()
    for (index, screen) in screens.enumerated() {
      let item = NSMenuItem(
        title: screen.localizedName,
        action: #selector(captureDisplayMenuItem(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = index + 1
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }

  @objc private func captureDisplayMenuItem(_ sender: NSMenuItem) {
    guard let display = sender.representedObject as? Int else { return }
    Task { @MainActor in
      await captureScreenshot(interactive: false, display: display)
    }
  }

  func captureRegionScreenshot() {
    Task { @MainActor in
      await captureScreenshot(interactive: true, display: nil)
    }
  }

  func importDocument() {
    guard let session = activeSession(), session.status == .recording else {
      showNotice("Start a live session before attaching files.", style: .warning)
      return
    }

    let openPanel = NSOpenPanel()
    openPanel.canChooseFiles = true
    openPanel.canChooseDirectories = false
    openPanel.allowsMultipleSelection = true
    openPanel.resolvesAliases = true
    openPanel.prompt = "Attach"
    openPanel.message = "Attach files to this live session."

    openPanel.begin { [weak self] response in
      guard response == .OK else { return }
      Task { @MainActor in
        guard let self else { return }
        var importedCount = 0
        var lastError: Error?

        for fileURL in openPanel.urls {
          do {
            try self.attachImportedFile(fileURL, to: session.id)
            importedCount += 1
          } catch {
            lastError = error
          }
        }

        if importedCount > 0 {
          self.showNotice(
            importedCount == 1
              ? "File pinned at \(self.state.timerText)."
              : "\(importedCount) files pinned at \(self.state.timerText).",
            style: .success
          )
        } else if let lastError {
          self.state.errorMessage = lastError.localizedDescription
          self.showNotice("File attachment failed.", style: .error)
        }
      }
    }
  }

  func windowDidMove(_ notification: Notification) {
    guard let panel else { return }
    UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Constants.positionKey)
    refreshLayoutMetrics()
    updatePanelSize(animated: false)
  }

  private func bind(to model: LocalMeetingAppModel) {
    cancellables.removeAll()

    model.$isRecording
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isRecording in
        if isRecording {
          // Starting a recording always brings the bar back.
          self?.state.isDismissedForCurrentRecording = false
          self?.state.levelHistory = []
        }
        self?.refreshState()
        self?.syncVisibility()
      }
      .store(in: &cancellables)

    model.$isTranscribing
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshState()
        self?.syncVisibility()
      }
      .store(in: &cancellables)

    model.$micLevel
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.micLevel = value
        self?.appendLevelSample()
      }
      .store(in: &cancellables)

    model.$isMicrophoneCaptureActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.isMicrophoneCaptureActive = value
      }
      .store(in: &cancellables)

    model.$isMicrophoneMuted
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.isMicrophoneMuted = value
      }
      .store(in: &cancellables)

    model.$isSystemAudioCaptureActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.isSystemAudioCaptureActive = value
      }
      .store(in: &cancellables)

    model.$systemLevel
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.systemLevel = value
        self?.appendLevelSample()
      }
      .store(in: &cancellables)

    model.$recordingDurationText
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.timerText = value
      }
      .store(in: &cancellables)

    model.$selectedSessionID
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshState()
        self?.reconcileLiveSessionSnapshot()
      }
      .store(in: &cancellables)

    model.$sessions
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshState()
        self?.reconcileLiveSessionSnapshot()
      }
      .store(in: &cancellables)

    model.$recorderErrorMessage
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.errorMessage = value
      }
      .store(in: &cancellables)

    model.$processingStatusTitle
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.processingStatusTitle = value
      }
      .store(in: &cancellables)

    model.$processingStatusDetail
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.processingStatusDetail = value
      }
      .store(in: &cancellables)

    model.$processingProgress
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.processingProgress = value
      }
      .store(in: &cancellables)
  }

  private func ensurePanel() {
    guard panel == nil else { return }

    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: preferredPanelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    // The bar is a light paper surface by design; don't let system dark mode
    // turn the glass/material dark.
    panel.appearance = NSAppearance(named: .aqua)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.delegate = self

    let hostingView = NSHostingView(
      rootView: CepessaSessionFloatingBarView(controller: self, state: state))
    hostingView.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.wantsLayer = true
    container.addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: container.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    panel.contentView = container
    panel.setContentSize(preferredPanelSize)
    refreshLayoutMetrics()

    if let savedOrigin = UserDefaults.standard.string(forKey: Constants.positionKey) {
      let origin = NSPointFromString(savedOrigin)
      panel.setFrameOrigin(origin)
      clamp(panel: panel)
    } else {
      positionPanel(panel)
    }

    self.panel = panel
    self.hostingView = hostingView
  }

  private func positionPanel(_ panel: NSPanel) {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let frame = screen.visibleFrame
    let origin = NSPoint(
      x: frame.midX - (preferredPanelSize.width / 2),
      y: frame.maxY - preferredPanelSize.height - 18
    )
    panel.setFrameOrigin(origin)
  }

  private func refreshState() {
    guard let model else { return }

    refreshLayoutMetrics()
    state.isRecording = model.isRecording
    state.isTranscribing = model.isTranscribing
    state.isMicrophoneCaptureActive = model.isMicrophoneCaptureActive
    state.isMicrophoneMuted = model.isMicrophoneMuted
    state.isSystemAudioCaptureActive = model.isSystemAudioCaptureActive
    state.timerText = model.recordingDurationText
    state.micLevel = model.micLevel
    state.systemLevel = model.systemLevel
    state.errorMessage = model.recorderErrorMessage
    state.processingStatusTitle = model.processingStatusTitle
    state.processingStatusDetail = model.processingStatusDetail
    state.processingProgress = model.processingProgress
    state.processingQueue = processingQueueItems(from: model)
    state.isAttachmentDeckExpanded = !UserDefaults.standard.bool(
      forKey: Constants.attachmentDeckHiddenKey)

    if let session = activeSession() {
      state.title = session.title
      state.attachmentDeck = CepessaSessionFloatingAttachmentDeck.build(from: session)
      switch session.status {
      case .recording:
        state.statusMessage =
          state.isMicrophoneMuted
          ? "Recording on this Mac. The microphone is muted in the transcript mix."
          : "Recording on this Mac. Add screenshots or files to pin context to this moment."
      case .transcribing:
        state.statusMessage =
          model.processingStatusDetail
          ?? "Finishing the local transcript."
      case .ready:
        state.statusMessage = "Session saved locally."
      case .failed:
        state.statusMessage = "Processing stopped. Open the session for details."
      }
    } else if model.isTranscribing {
      state.title = model.processingStatusTitle ?? "Processing session"
      state.statusMessage =
        model.processingStatusDetail
        ?? "Finishing the local transcript."
      if let lastSession = model.sessions.first(where: {
        $0.status == .transcribing
      }) {
        state.attachmentDeck = CepessaSessionFloatingAttachmentDeck.build(from: lastSession)
      } else {
        state.attachmentDeck = .empty
      }
    } else {
      state.title = "Session capture idle"
      state.statusMessage = "Start a session to keep audio and context in one timeline."
      state.attachmentDeck = .empty
    }

    refreshLayoutMetrics()
    updatePanelSize(animated: true)
  }

  /// Feeds the scrolling waveform. Samples are throttled to ~20 Hz so the
  /// wave scrolls at a steady, readable pace regardless of publisher cadence.
  private func appendLevelSample() {
    guard state.isRecording else { return }
    let now = Date().timeIntervalSinceReferenceDate
    guard now - lastLevelSampleAt >= 0.05 else { return }
    lastLevelSampleAt = now

    let combined = min(1, max(state.isMicrophoneMuted ? 0 : state.micLevel, state.systemLevel))
    var history = state.levelHistory
    history.append(combined)
    if history.count > 160 {
      history.removeFirst(history.count - 160)
    }
    state.levelHistory = history
  }

  private func syncVisibility() {
    guard let panel else { return }
    // The bar is the app: visible whenever enabled, in every state.
    let shouldShow = isFloatingBarEnabled && !state.isDismissedForCurrentRecording
    state.isVisible = shouldShow

    if shouldShow {
      if !panel.isVisible {
        panel.orderFrontRegardless()
      }
    } else {
      panel.orderOut(nil)
    }
  }

  private var isFloatingBarEnabled: Bool {
    let value = UserDefaults.standard.object(forKey: Constants.enabledKey) as? Bool
    return value ?? false
  }

  private var preferredPanelSize: NSSize {
    let baseHeight: CGFloat
    if state.isRecording {
      baseHeight =
        (state.isAttachmentDeckExpanded && state.attachmentDeck.hasContent)
        ? Constants.expandedBarHeight
        : Constants.compactBarHeight
    } else {
      baseHeight = Constants.idleBarHeight
    }
    return NSSize(
      width: currentBarContentWidth + Constants.panelHorizontalPadding,
      height: baseHeight)
  }

  private var currentBarContentWidth: CGFloat {
    if !state.isRecording {
      return state.isTranscribing
        ? Constants.processingBarContentWidth
        : Constants.idleBarContentWidth
    }
    let availableWidth =
      (panel.flatMap { screen(for: $0.frame) } ?? NSScreen.main ?? NSScreen.screens.first)?
      .visibleFrame.width
    let screenBoundWidth = max(
      Constants.minimumBarContentWidth,
      (availableWidth ?? Constants.preferredBarContentWidth) - 48
    )
    return min(Constants.maximumBarContentWidth, screenBoundWidth)
  }

  private func refreshLayoutMetrics() {
    let width = currentBarContentWidth
    if state.barContentWidth != width {
      state.barContentWidth = width
    }
  }

  private func updatePanelSize(animated: Bool) {
    guard let panel else { return }
    let targetSize = preferredPanelSize
    guard panel.frame.size != targetSize else { return }

    // Grow/shrink around the center so the bar stays where the user put it,
    // and clamp the target frame (not the stale pre-animation frame).
    var nextFrame = panel.frame
    nextFrame.origin.x += (panel.frame.width - targetSize.width) / 2
    nextFrame.origin.y -= targetSize.height - panel.frame.height
    nextFrame.size = targetSize
    nextFrame.origin = clampedOrigin(for: nextFrame)

    if animated {
      panel.animator().setFrame(nextFrame, display: true)
    } else {
      panel.setFrame(nextFrame, display: true)
    }
  }

  private func activeSession() -> LocalSession? {
    if let selected = model?.selectedSession,
      selected.status == .recording || selected.status == .transcribing
    {
      return selected
    }

    return model?.sessions.first(where: {
      $0.status == .recording || $0.status == .transcribing
    })
  }

  private func captureScreenshot(interactive: Bool, display: Int?) async {
    guard let session = activeSession(), session.status == .recording else {
      showNotice("Start a live session before capturing screenshots.", style: .warning)
      return
    }

    do {
      let fileURL = try screenshotTargetURL(
        for: session.id, prefix: interactive ? "region" : "screen")
      try await runScreencapture(to: fileURL, interactive: interactive, display: display)
      try attachFile(
        at: fileURL,
        to: session.id,
        kind: .image,
        source: .floatingBar,
        title: interactive ? "Region capture" : "Screenshot",
        note: "Captured during the live session."
      )
      state.errorMessage = nil
      showNotice(
        interactive
          ? "Region pinned at \(state.timerText)." : "Screenshot pinned at \(state.timerText).",
        style: .success
      )
    } catch is CancellationError {
      return
    } catch {
      state.errorMessage = error.localizedDescription
      showNotice(interactive ? "Region capture failed." : "Screenshot failed.", style: .error)
    }
  }

  private func attachImportedFile(_ fileURL: URL, to sessionID: UUID) throws {
    let destinationURL = try attachmentTargetURL(
      for: sessionID,
      prefix: "document",
      preferredName: fileURL.lastPathComponent
    )
    try copyItem(at: fileURL, to: destinationURL)
    try attachFile(
      at: destinationURL,
      to: sessionID,
      kind: .file,
      source: .imported,
      title: fileURL.deletingPathExtension().lastPathComponent,
      note: "Imported during the live session."
    )
    state.errorMessage = nil
  }

  private func attachFile(
    at fileURL: URL,
    to sessionID: UUID,
    kind: LocalSessionAttachment.Kind,
    source: LocalSessionAttachment.Source,
    title: String,
    note: String?
  ) throws {
    guard let model else {
      throw FloatingBarError.noModel
    }

    guard let index = model.sessions.firstIndex(where: { $0.id == sessionID }) else {
      throw FloatingBarError.noSession
    }

    var session = model.sessions[index]

    let capturedAt = Date()
    let offset = max(0, capturedAt.timeIntervalSince(session.startedAt))
    let attachment = LocalSessionAttachment(
      id: UUID(),
      kind: kind,
      source: source,
      title: title,
      timestamp: capturedAt,
      sessionOffset: offset,
      fileName: fileURL.lastPathComponent,
      mimeType: mimeType(for: fileURL),
      urlString: fileURL.path,
      note: note
    )
    let artifact = LocalSessionCaptureArtifact(
      id: UUID(),
      kind: kind == .image ? .screenCapture : .note,
      title: title,
      capturedAt: capturedAt,
      sessionOffset: offset,
      attachmentIDs: [attachment.id],
      notes: note
    )

    session.attachments.append(attachment)
    session.captureArtifacts.append(artifact)
    model.upsertSession(session)
    model.selectSession(id: session.id)
    cacheLiveSessionSnapshot(for: session)
  }

  private func screenshotTargetURL(for sessionID: UUID, prefix: String) throws -> URL {
    try attachmentTargetURL(for: sessionID, prefix: prefix, preferredName: nil)
  }

  private func attachmentTargetURL(for sessionID: UUID, prefix: String, preferredName: String?)
    throws -> URL
  {
    let fileLayout = LocalMeetingFileLayout(baseDirectory: defaultBaseDirectory())
    let attachmentsDirectory =
      fileLayout
      .sessionDirectory(for: sessionID)
      .appendingPathComponent(Constants.attachmentsFolder, isDirectory: true)

    try FileManager.default.createDirectory(
      at: attachmentsDirectory, withIntermediateDirectories: true)

    if let preferredName {
      return uniqueURL(in: attachmentsDirectory, preferredName: preferredName)
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    return attachmentsDirectory.appendingPathComponent("\(prefix)-\(stamp).png", isDirectory: false)
  }

  private func uniqueURL(in directory: URL, preferredName: String) -> URL {
    let sanitizedName = preferredName.replacingOccurrences(of: "/", with: "-")
    var candidate = directory.appendingPathComponent(sanitizedName, isDirectory: false)
    var counter = 2

    while FileManager.default.fileExists(atPath: candidate.path) {
      let stem = candidate.deletingPathExtension().lastPathComponent
      let ext = candidate.pathExtension
      let fileName = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
      candidate = directory.appendingPathComponent(fileName, isDirectory: false)
      counter += 1
    }

    return candidate
  }

  private func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destinationURL.path) {
      try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.copyItem(at: sourceURL, to: destinationURL)
  }

  private func mimeType(for fileURL: URL) -> String? {
    switch fileURL.pathExtension.lowercased() {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "pdf": return "application/pdf"
    case "txt": return "text/plain"
    case "wav": return "audio/wav"
    default: return nil
    }
  }

  private func runScreencapture(
    to destinationURL: URL, interactive: Bool, display: Int? = nil
  ) async throws {
    let executable =
      FileManager.default.fileExists(atPath: "/usr/sbin/screencapture")
      ? "/usr/sbin/screencapture"
      : "/usr/bin/screencapture"

    try await withCheckedThrowingContinuation { continuation in
      let task = Process()
      task.executableURL = URL(fileURLWithPath: executable)
      var arguments = interactive ? ["-i", "-x"] : ["-x"]
      if let display, !interactive {
        arguments += ["-D", String(display)]
      }
      arguments.append(destinationURL.path)
      task.arguments = arguments

      task.terminationHandler = { process in
        DispatchQueue.main.async {
          if process.terminationStatus == 0 {
            continuation.resume()
          } else if process.terminationStatus == 1 {
            continuation.resume(throwing: CancellationError())
          } else {
            continuation.resume(
              throwing: NSError(
                domain: "CepessaSessionsFloatingBar",
                code: Int(process.terminationStatus),
                userInfo: [
                  NSLocalizedDescriptionKey:
                    "Screen capture failed with exit code \(process.terminationStatus)."
                ]
              ))
          }
        }
      }

      do {
        try task.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  private func defaultBaseDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Cepessa", isDirectory: true)
  }

  private func processingQueueItems(from model: LocalMeetingAppModel)
    -> [CepessaSessionFloatingProcessingItem]
  {
    model.processingQueue.map { snapshot in
      CepessaSessionFloatingProcessingItem(
        id: snapshot.id,
        sessionTitle: model.sessions.first(where: { $0.id == snapshot.id })?.displayTitle
          ?? "Session",
        stageTitle: snapshot.title,
        detail: snapshot.detail,
        phaseLabel: snapshot.phase.label,
        progress: snapshot.progress
      )
    }
  }

  private func cacheLiveSessionSnapshot(for session: LocalSession) {
    liveSessionSnapshot = session
    liveSessionID = session.id
  }

  private func reconcileLiveSessionSnapshot() {
    guard !applyingLiveSessionSnapshot,
      let model,
      let sessionID = liveSessionID,
      let snapshot = liveSessionSnapshot,
      let index = model.sessions.firstIndex(where: { $0.id == sessionID })
    else {
      return
    }

    let current = model.sessions[index]
    let merged = mergeLiveSessionSnapshot(current: current, snapshot: snapshot)

    guard merged != current else {
      if current.status != .recording && current.status != .transcribing {
        self.liveSessionSnapshot = nil
        self.liveSessionID = nil
      }
      return
    }

    applyingLiveSessionSnapshot = true
    defer { applyingLiveSessionSnapshot = false }

    model.upsertSession(merged)

    if merged.status == .recording || merged.status == .transcribing {
      self.liveSessionSnapshot = merged
      self.liveSessionID = merged.id
    } else {
      self.liveSessionSnapshot = nil
      self.liveSessionID = nil
    }
  }

  private func mergeLiveSessionSnapshot(current: LocalSession, snapshot: LocalSession)
    -> LocalSession
  {
    var merged = current

    let attachmentIDs = Set(current.attachments.map(\.id))
    merged.attachments.append(
      contentsOf: snapshot.attachments.filter { !attachmentIDs.contains($0.id) })

    let artifactIDs = Set(current.captureArtifacts.map(\.id))
    merged.captureArtifacts.append(
      contentsOf: snapshot.captureArtifacts.filter { !artifactIDs.contains($0.id) })

    return merged
  }

  private func clamp(panel: NSPanel) {
    let origin = clampedOrigin(for: panel.frame)
    if origin != panel.frame.origin {
      panel.setFrameOrigin(origin)
    }
  }

  private func clampedOrigin(for frame: NSRect) -> NSPoint {
    guard let screen = screen(for: frame) ?? NSScreen.main ?? NSScreen.screens.first else {
      return frame.origin
    }
    let visible = screen.visibleFrame
    var origin = frame.origin
    origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
    origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
    return origin
  }

  private func screen(for frame: NSRect) -> NSScreen? {
    NSScreen.screens.first { NSIntersectionRect($0.visibleFrame, frame).isEmpty == false }
  }

  private func showNotice(_ text: String, style: CepessaSessionFloatingBarState.NoticeStyle) {
    noticeDismissTask?.cancel()
    state.noticeMessage = text
    state.noticeStyle = style

    noticeDismissTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 2_400_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self else { return }
        self.state.noticeMessage = nil
        self.state.noticeStyle = .neutral
      }
    }
  }

  private enum FloatingBarError: LocalizedError {
    case noModel
    case noSession

    var errorDescription: String? {
      switch self {
      case .noModel:
        return "The live session store is unavailable."
      case .noSession:
        return "The live session could not be found."
      }
    }
  }
}

struct CepessaSessionFloatingProcessingItem: Identifiable, Equatable {
  let id: UUID
  let sessionTitle: String
  let stageTitle: String
  let detail: String
  let phaseLabel: String
  let progress: Double?

  var progressLabel: String? {
    guard let progress else { return nil }
    return "\(Int((progress * 100).rounded()))%"
  }
}

private struct CepessaSessionFloatingBarView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let controller: CepessaSessionFloatingBarController
  @ObservedObject var state: CepessaSessionFloatingBarState

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if state.isRecording && state.attachmentDeck.hasContent {
        HStack(alignment: .bottom, spacing: 10) {
          if state.isAttachmentDeckExpanded {
            SessionFloatingAttachmentDeckView(deck: state.attachmentDeck)
              .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomLeading)))
          } else {
            SessionFloatingCollapsedAttachmentPill(deck: state.attachmentDeck)
              .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomLeading)))
          }

          SessionFloatingDeckToggleButton(
            isExpanded: state.isAttachmentDeckExpanded,
            action: controller.toggleAttachmentDeckVisibility
          )
          .padding(.bottom, 10)

          Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, -10)
        .zIndex(2)
      }

      barPill
    }
    .frame(
      width: state.barContentWidth
        + CepessaSessionFloatingBarController.Constants.panelHorizontalPadding
    )
    .padding(.vertical, 8)
    .background(Color.clear)
    .animation(barAnimation, value: state.isRecording)
    .animation(barAnimation, value: state.isTranscribing)
    .animation(barAnimation, value: state.attachmentDeck)
    .animation(barAnimation, value: state.isAttachmentDeckExpanded)
  }

  private var barPill: some View {
    Group {
      if state.isRecording {
        recordingContent
      } else if state.isTranscribing {
        processingContent
      } else {
        idleContent
      }
    }
    .padding(.horizontal, 10)
    .frame(
      width: state.barContentWidth,
      height: state.isRecording
        ? CepessaSessionFloatingBarController.Constants.recordingPillHeight
        : CepessaSessionFloatingBarController.Constants.idlePillHeight
    )
    .cepessaFloatingToolbarSurface()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Cepessa Sessions bar")
    .accessibilityHint("Drag the middle of the bar to move it.")
  }

  // MARK: Idle — record, quiet waveform, library shortcuts

  private var idleContent: some View {
    HStack(alignment: .center, spacing: 8) {
      SessionFloatingRecordButton(action: controller.startRecording)

      ZStack {
        SessionFloatingDragSpacer()

        SessionFloatingLiveWaveform(
          levels: [],
          isRecording: false,
          accent: CepessaColors.textTertiary
        )
        .frame(height: 26)
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
      }

      SessionFloatingToolbarIconButton(
        icon: "ellipsis",
        title: "Sessions menu",
        isDisabled: false,
        action: controller.showBarMenu
      )
    }
  }

  // MARK: Processing — quiet progress

  private var processingContent: some View {
    HStack(alignment: .center, spacing: 10) {
      ProgressView()
        .controlSize(.small)

      Text(progressText)
        .scaledFont(size: 12, weight: .medium)
        .monospacedDigit()
        .foregroundStyle(CepessaColors.textSecondary)
        .lineLimit(1)

      SessionFloatingDragSpacer()

      SessionFloatingToolbarIconButton(
        icon: "ellipsis",
        title: "Sessions menu",
        isDisabled: false,
        action: controller.showBarMenu
      )
    }
  }

  // MARK: Recording — full capture controls

  private var recordingContent: some View {
    HStack(alignment: .center, spacing: 7) {
      SessionFloatingToolbarIconButton(
        icon: state.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
        title: state.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone",
        isDisabled: !state.isRecording,
        action: controller.toggleMicrophoneMute
      )

      toolbarDivider

      SessionFloatingToolbarIconButton(
        icon: "laptopcomputer",
        title: "Capture screen",
        isDisabled: !state.isRecording,
        action: controller.captureFullScreenshot
      )
      SessionFloatingToolbarIconButton(
        icon: "camera",
        title: "Capture region",
        isDisabled: !state.isRecording,
        action: controller.captureRegionScreenshot
      )
      SessionFloatingToolbarIconButton(
        icon: "paperclip",
        title: "Attach file",
        isDisabled: !state.isRecording,
        action: controller.importDocument
      )

      SessionFloatingWaveformDragRegion(
        levels: state.levelHistory,
        accent: waveformAccent
      )
      .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 44)

      SessionFloatingTimerPill(timerText: state.timerText)

      SessionFloatingStopButton(action: controller.stopRecording)

      toolbarDivider

      SessionFloatingToolbarIconButton(
        icon: "ellipsis",
        title: "Sessions menu",
        isDisabled: false,
        action: controller.showBarMenu
      )
    }
  }

  private var progressText: String {
    if let progress = state.processingProgress {
      return "Transcribing \(Int((progress * 100).rounded()))%"
    }
    return state.processingStatusTitle ?? "Transcribing"
  }

  private var toolbarDivider: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor).opacity(0.65))
      .frame(width: 1, height: 20)
      .padding(.horizontal, 2)
  }

  private var waveformAccent: Color {
    if let error = state.errorMessage, !error.isEmpty {
      return CepessaColors.warning
    }
    return state.noticeStyle == .error ? CepessaColors.warning : CepessaColors.signalRed
  }

  private var noticeTextColor: Color {
    switch state.noticeStyle {
    case .success:
      return CepessaColors.success
    case .warning:
      return CepessaColors.warning
    case .error:
      return CepessaColors.warning
    case .neutral:
      return CepessaColors.textTertiary
    }
  }

  private var progressButtonTitle: String {
    guard state.isTranscribing else { return "Processing" }
    if let progress = state.processingProgress {
      return "Working \(Int((progress * 100).rounded()))%"
    }
    return state.processingStatusTitle ?? "Processing"
  }

  private var secondaryProcessingItems: [CepessaSessionFloatingProcessingItem] {
    Array(state.processingQueue.dropFirst().prefix(2))
  }

  private func meterAccent(isActive: Bool, isRecording: Bool, isTranscribing: Bool) -> Color {
    if isRecording {
      return isActive ? CepessaColors.success : CepessaColors.error
    }

    if isTranscribing {
      return CepessaColors.purplePrimary
    }

    return CepessaColors.textTertiary
  }

  private var barAnimation: Animation? {
    reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
  }
}

private struct SessionFloatingAttachmentDeckView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let deck: CepessaSessionFloatingAttachmentDeck

  private let cardSize = CGSize(width: 128, height: 82)

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(Array(layeredPreviews.enumerated()), id: \.element.id) { index, preview in
        SessionFloatingAttachmentCard(
          preview: preview,
          accent: accent(for: preview.kind),
          timestamp: timestampLabel(for: preview),
          isPrimary: index == 0
        )
        .frame(width: cardSize.width, height: cardSize.height)
        .rotationEffect(.degrees(rotation(for: index)))
        .offset(x: xOffset(for: index), y: yOffset(for: index))
        .zIndex(zIndex(for: index))
        .shadow(
          color: Color.black.opacity(index == 0 ? 0.18 : 0.08),
          radius: index == 0 ? 14 : 8,
          x: 0,
          y: index == 0 ? 10 : 5
        )
      }

      if deck.overflowCount > 0 {
        Text("+\(deck.overflowCount)")
          .scaledFont(size: 10.5, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            Capsule()
              .fill(CepessaColors.backgroundSecondary.opacity(0.96))
          )
          .overlay(
            Capsule()
              .stroke(Color.white.opacity(0.08), lineWidth: 1)
          )
          .offset(x: 122, y: 56)
          .zIndex(5)
      }
    }
    .frame(width: 250, height: 90, alignment: .topLeading)
    .animation(
      reduceMotion ? nil : .timingCurve(0.18, 0.88, 0.28, 1, duration: 0.28), value: deck.previews
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Recent captures")
  }

  private var layeredPreviews: [CepessaSessionFloatingAttachmentPreview] {
    if deck.previews.count <= 1 {
      return deck.previews
    }

    var arranged: [CepessaSessionFloatingAttachmentPreview] = [deck.previews[0]]
    if deck.previews.indices.contains(1) {
      arranged.append(deck.previews[1])
    }
    if deck.previews.indices.contains(2) {
      arranged.append(deck.previews[2])
    }
    return arranged
  }

  private func xOffset(for index: Int) -> CGFloat {
    switch layeredPreviews.count {
    case 1:
      return 0
    case 2:
      return index == 0 ? 52 : 0
    default:
      switch index {
      case 0: return 56
      case 1: return 0
      default: return 114
      }
    }
  }

  private func yOffset(for index: Int) -> CGFloat {
    switch layeredPreviews.count {
    case 1:
      return 6
    case 2:
      return index == 0 ? 0 : 12
    default:
      switch index {
      case 0: return 0
      case 1: return 10
      default: return 18
      }
    }
  }

  private func rotation(for index: Int) -> Double {
    switch layeredPreviews.count {
    case 1:
      return 0
    case 2:
      return index == 0 ? 2 : -4
    default:
      switch index {
      case 0: return 0
      case 1: return -4
      default: return 5
      }
    }
  }

  private func zIndex(for index: Int) -> Double {
    Double(layeredPreviews.count - index)
  }

  private func accent(for kind: LocalSessionAttachment.Kind) -> Color {
    switch kind {
    case .image, .capture:
      return CepessaColors.purplePrimary
    case .file:
      return CepessaColors.success
    case .audio:
      return CepessaColors.warning
    case .link:
      return CepessaColors.textSecondary
    }
  }

  private func timestampLabel(for preview: CepessaSessionFloatingAttachmentPreview) -> String {
    let rawOffset = preview.sessionOffset ?? 0
    let totalSeconds = max(0, Int(rawOffset.rounded()))
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }
}

private struct SessionFloatingAttachmentCard: View {
  let preview: CepessaSessionFloatingAttachmentPreview
  let accent: Color
  let timestamp: String
  let isPrimary: Bool

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      cardSurface

      LinearGradient(
        colors: [Color.clear, Color.black.opacity(0.22)],
        startPoint: .center,
        endPoint: .bottom
      )
      .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          AttachmentKindBadge(kind: preview.kind, accent: accent)
          Spacer(minLength: 8)
          Text(timestamp)
            .scaledFont(size: 10, weight: .semibold)
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.86))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.12))
            .clipShape(Capsule())
        }

        Spacer(minLength: 0)

        Text(previewTitle)
          .scaledFont(size: 11.5, weight: .semibold)
          .foregroundStyle(Color.white)
          .lineLimit(2)

        if let subtitle = previewSubtitle {
          Text(subtitle)
            .scaledFont(size: 9.5, weight: .medium)
            .foregroundStyle(Color.white.opacity(0.72))
            .lineLimit(1)
        }
      }
      .padding(12)
    }
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(Color.white.opacity(isPrimary ? 0.84 : 0.56), lineWidth: isPrimary ? 3 : 2)
    )
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }

  @ViewBuilder
  private var cardSurface: some View {
    if let image = previewImage {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
    } else {
      ZStack {
        LinearGradient(
          colors: backgroundGradient,
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )

        VStack(spacing: 10) {
          Image(systemName: fallbackIcon)
            .scaledFont(size: 24, weight: .semibold)
            .foregroundStyle(Color.white.opacity(0.9))

          Text(fallbackLabel)
            .scaledFont(size: 10, weight: .semibold)
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
        }
      }
    }
  }

  private var previewImage: NSImage? {
    guard let fileURL = preview.fileURL,
      FileManager.default.fileExists(atPath: fileURL.path)
    else {
      return nil
    }

    if let image = NSImage(contentsOf: fileURL) {
      return image
    }

    return nil
  }

  private var previewTitle: String {
    preview.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? (preview.fileName ?? "Attachment")
      : preview.title
  }

  private var previewSubtitle: String? {
    switch preview.kind {
    case .image, .capture:
      return "Pinned to the session"
    case .file:
      return preview.fileName ?? "Document"
    case .audio:
      return "Audio artifact"
    case .link:
      return "Linked reference"
    }
  }

  private var fallbackIcon: String {
    switch preview.kind {
    case .image, .capture:
      return "photo.on.rectangle.angled"
    case .file:
      return "doc.text.image"
    case .audio:
      return "waveform"
    case .link:
      return "link"
    }
  }

  private var fallbackLabel: String {
    switch preview.kind {
    case .image, .capture:
      return "Capture"
    case .file:
      return "Document"
    case .audio:
      return "Audio"
    case .link:
      return "Link"
    }
  }

  private var backgroundGradient: [Color] {
    switch preview.kind {
    case .image, .capture:
      return [
        accent.opacity(0.88), CepessaColors.purplePrimary.opacity(0.46),
        CepessaColors.backgroundRaised,
      ]
    case .file:
      return [
        CepessaColors.success.opacity(0.72), CepessaColors.backgroundRaised,
        CepessaColors.backgroundSecondary,
      ]
    case .audio:
      return [
        CepessaColors.warning.opacity(0.76), CepessaColors.backgroundRaised,
        CepessaColors.backgroundSecondary,
      ]
    case .link:
      return [
        CepessaColors.textSecondary.opacity(0.64), CepessaColors.backgroundRaised,
        CepessaColors.backgroundSecondary,
      ]
    }
  }
}

private struct AttachmentKindBadge: View {
  let kind: LocalSessionAttachment.Kind
  let accent: Color

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: icon)
        .scaledFont(size: 8.5, weight: .semibold)
      Text(label)
        .scaledFont(size: 8.5, weight: .semibold)
    }
    .foregroundStyle(Color.white.opacity(0.94))
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(accent.opacity(0.22))
    .overlay(
      Capsule()
        .stroke(Color.white.opacity(0.14), lineWidth: 1)
    )
    .clipShape(Capsule())
  }

  private var icon: String {
    switch kind {
    case .image, .capture:
      return "camera.fill"
    case .file:
      return "paperclip"
    case .audio:
      return "waveform"
    case .link:
      return "link"
    }
  }

  private var label: String {
    switch kind {
    case .image:
      return "Screen"
    case .capture:
      return "Capture"
    case .file:
      return "File"
    case .audio:
      return "Audio"
    case .link:
      return "Link"
    }
  }
}

private struct SessionFloatingCollapsedAttachmentPill: View {
  let deck: CepessaSessionFloatingAttachmentDeck

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: -10) {
        ForEach(Array(deck.previews.prefix(3).enumerated()), id: \.element.id) { _, preview in
          Circle()
            .fill(accent(for: preview.kind).opacity(0.85))
            .frame(width: 18, height: 18)
            .overlay(
              Circle()
                .stroke(Color.white.opacity(0.92), lineWidth: 2)
            )
        }
      }
      .padding(.leading, 4)

      Text(summaryText)
        .scaledFont(size: 11, weight: .semibold)
        .foregroundStyle(CepessaColors.textPrimary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      Capsule()
        .fill(CepessaColors.backgroundSecondary)
        .overlay(
          Capsule()
            .stroke(CepessaColors.hairline.opacity(0.5), lineWidth: 1)
        )
    )
    .shadow(color: CepessaColors.warmShadow.opacity(0.08), radius: 8, x: 0, y: 4)
  }

  private var summaryText: String {
    let count = deck.previews.count + deck.overflowCount
    return count == 1 ? "1 capture" : "\(count) captures"
  }

  private func accent(for kind: LocalSessionAttachment.Kind) -> Color {
    switch kind {
    case .image, .capture:
      return CepessaColors.purplePrimary
    case .file:
      return CepessaColors.success
    case .audio:
      return CepessaColors.warning
    case .link:
      return CepessaColors.textSecondary
    }
  }
}

private struct SessionFloatingDeckToggleButton: View {
  let isExpanded: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: isExpanded ? "eye.slash" : "eye")
        .scaledFont(size: 11, weight: .semibold)
        .foregroundStyle(CepessaColors.textSecondary)
        .frame(width: 30, height: 30)
        .background(CepessaColors.backgroundRaised.opacity(0.74))
        .clipShape(Circle())
    }
    .buttonStyle(SessionFloatingPressStyle())
    .help(isExpanded ? "Hide recent captures" : "Show recent captures")
  }
}

/// The one saturated element in the idle bar: a red record capsule.
private struct SessionFloatingRecordButton: View {
  @State private var isHovered = false

  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Circle()
          .fill(Color.white)
          .frame(width: 7, height: 7)

        Text("Record")
          .scaledFont(size: 12.5, weight: .semibold)
          .foregroundStyle(Color.white)
          .lineLimit(1)
          .fixedSize()
      }
      .padding(.horizontal, 14)
      .frame(height: 34)
      .background(
        Capsule().fill(CepessaColors.signalRed.opacity(isHovered ? 1 : 0.92))
      )
      .contentShape(Capsule())
    }
    .buttonStyle(CepessaPressStyle(scale: 0.97))
    .onHover { isHovered = $0 }
    .help("Start a new recording session")
    .accessibilityLabel("Start recording")
  }
}

/// Flexible middle region of the compact bar; doubles as the window drag handle.
private struct SessionFloatingDragSpacer: View {
  var body: some View {
    SessionFloatingDragHandleView()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .accessibilityHidden(true)
  }
}

private struct SessionFloatingToolbarIconButton: View {
  @State private var isHovered = false

  let icon: String
  let title: String
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .scaledFont(size: 12.5, weight: .medium)
        .frame(width: 34, height: 34)
        .contentShape(Circle())
        .background {
          Circle()
            .fill(
              CepessaColors.backgroundSecondary.opacity(
                isDisabled ? 0.4 : (isHovered ? 1 : 0.8)))
        }
    }
    .buttonStyle(CepessaPressStyle(scale: 0.96))
    .disabled(isDisabled)
    .onHover { isHovered = $0 }
    .foregroundColor(
      isDisabled ? CepessaColors.textTertiary.opacity(0.38) : CepessaColors.textSecondary
    )
    .help(title)
    .accessibilityLabel(title)
  }
}

private struct SessionFloatingTimerPill: View {
  let timerText: String

  var body: some View {
    Text(timerText)
      .scaledFont(size: 23, weight: .regular, design: .monospaced)
      .monospacedDigit()
      .foregroundStyle(CepessaColors.textPrimary.opacity(0.82))
      .frame(minWidth: 118, minHeight: 40)
      .padding(.horizontal, 4)
      .cepessaFloatingToolbarPillSurface()
      .accessibilityLabel("Recording duration \(timerText)")
  }
}

private struct SessionFloatingStopButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Stop", systemImage: "stop.fill")
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(.white)
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(Capsule().fill(CepessaColors.signalRed))
        .contentShape(Capsule())
    }
    .buttonStyle(CepessaPressStyle(scale: 0.96, pressedBrightness: -0.04))
    .help("Stop the current recording session")
    .accessibilityLabel("Stop recording")
  }
}

private struct SessionFloatingWaveformDragRegion: View {
  let levels: [Double]
  let accent: Color

  var body: some View {
    ZStack {
      SessionFloatingDragHandleView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      SessionFloatingLiveWaveform(
        levels: levels,
        isRecording: true,
        accent: accent
      )
      .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .accessibilityLabel("Move floating recording bar")
    .accessibilityHint("Drag to reposition the recording controls.")
  }
}

/// Voice-Memos-style scrolling waveform. While recording, each new audio
/// sample pushes in from the right and the history scrolls left, so the wave
/// genuinely moves with the sound. Idle shows a quiet breathing ripple.
private struct SessionFloatingLiveWaveform: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let levels: [Double]
  let isRecording: Bool
  let accent: Color

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
      Canvas { context, size in
        let barWidth: CGFloat = 3
        let gap: CGFloat = 3.2
        let step = barWidth + gap
        let count = max(8, Int(size.width / step))
        let inset = (size.width - (CGFloat(count) * step) + gap) / 2
        let midY = size.height / 2
        let maxHalf = max(4, midY - 3)
        let time = timeline.date.timeIntervalSinceReferenceDate

        for index in 0..<count {
          let norm = Double(index) / Double(max(count - 1, 1))
          let x = inset + CGFloat(index) * step
          var half: CGFloat
          let opacity: Double

          if isRecording {
            let sampleIndex = levels.count - count + index
            let level =
              sampleIndex >= 0 && sampleIndex < levels.count ? levels[sampleIndex] : 0
            let shaped = pow(min(max(level, 0), 1), 0.7)
            let shimmer =
              reduceMotion ? 1.0 : 1.0 + 0.07 * sin(time * 9 + Double(index) * 1.7)
            half = 1.6 + maxHalf * CGFloat(shaped * shimmer)
            opacity = 0.28 + 0.72 * norm
          } else {
            let envelope = sin(.pi * norm)
            let ripple = reduceMotion ? 0.5 : (sin(time * 1.7 + norm * 6.2) + 1) / 2
            half = 1.4 + CGFloat(ripple * envelope) * 6
            opacity = 0.40 + 0.30 * envelope
          }

          half = min(half, maxHalf + 1.6)
          let rect = CGRect(x: x, y: midY - half, width: barWidth, height: half * 2)
          context.fill(
            Path(roundedRect: rect, cornerRadius: barWidth / 2),
            with: .color(accent.opacity(opacity))
          )
        }
      }
    }
  }
}

private struct SessionFloatingPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(
        reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.14),
        value: configuration.isPressed
      )
  }
}

private struct SessionFloatingDragHandleView: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    SessionFloatingDragNSView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SessionFloatingDragNSView: NSView {
  override var isOpaque: Bool { false }

  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }
}
