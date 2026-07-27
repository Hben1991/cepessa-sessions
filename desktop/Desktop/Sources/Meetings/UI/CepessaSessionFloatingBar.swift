import AppKit
import Combine
import SwiftUI

@MainActor
final class CepessaSessionsStore {
  static let shared = CepessaSessionsStore()

  let model: LocalMeetingAppModel
  let clipModel: LocalClipViewModel

  private init() {
    self.model = LocalMeetingAppModel()
    self.clipModel = LocalClipViewModel()
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
  @Published var timerText = "00:00:00"
  @Published var title = "Session capture idle"
  @Published var statusMessage = "Local capture stays on this Mac."
  @Published var errorMessage: String?
  @Published var noticeMessage: String?
  @Published var noticeStyle: NoticeStyle = .neutral
  @Published var interaction = CepessaSessionFloatingBarInteractionState()
  /// The lozenge itself. Animated — this is the shape that morphs.
  @Published var barContentSize = CepessaSessionFloatingBarGeometry.idleSize
  /// The footprint the panel is currently sized for. Equal to `barContentSize`
  /// at rest and the union of both footprints while the lozenge is morphing.
  @Published var panelContentSize = CepessaSessionFloatingBarGeometry.idleSize
  /// True while the lozenge is changing shape. Only the tray's controls read
  /// it — the ring stays live throughout, so the indicator can never be left
  /// unclickable by a transition that failed to end.
  @Published var isTransitioning = false
  @Published var processingStatusTitle: String?
  @Published var processingStatusDetail: String?
  @Published var processingProgress: Double?
  @Published var processingQueue: [CepessaSessionFloatingProcessingItem] = []
  @Published var attachmentDeck = CepessaSessionFloatingAttachmentDeck.empty

  var mode: CepessaSessionFloatingBarMode {
    if interaction.isTrayOpen { return .tray }
    if isRecording { return .recording }
    return isTranscribing ? .processing : .idle
  }

  var captureHealth: CepessaSessionCaptureHealth {
    CepessaSessionCaptureHealth.resolve(
      microphoneActive: isMicrophoneCaptureActive,
      microphoneMuted: isMicrophoneMuted,
      systemAudioActive: isSystemAudioCaptureActive,
      hasError: errorMessage?.isEmpty == false
    )
  }

  var ring: CepessaSessionIndicatorRing {
    CepessaSessionIndicatorRing.resolve(
      mode: mode,
      isRecording: isRecording,
      health: captureHealth,
      progress: processingProgress
    )
  }

  var compactTimerText: String {
    CepessaSessionIndicatorTimer.compactText(from: timerText)
  }

  var showsHours: Bool {
    CepessaSessionIndicatorTimer.showsHours(timerText)
  }

  var hasNotice: Bool {
    noticeMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }

  var hasFault: Bool {
    errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }

  /// The single line the open tray reads out next to the ring.
  var trayStatusText: String {
    CepessaSessionIndicatorTrayStatus.text(
      isRecording: isRecording,
      isTranscribing: isTranscribing,
      hasFault: hasFault,
      compactTimerText: compactTimerText,
      progress: processingProgress,
      notice: noticeMessage
    )
  }
}

/// The panel's content view.
///
/// The panel is deliberately larger than the lozenge — it carries transparent
/// bleed so the glass rim and shadows are never clipped — which means it must
/// decide for itself what counts as a click on the indicator. Anything outside
/// the live lozenge passes straight through to whatever is behind it, and
/// while the lozenge is morphing the whole surface swallows clicks instead of
/// forwarding them to a control that is still moving.
/// A pass-through filter and nothing else.
///
/// It answers exactly one question — is this point on the lozenge? — and hands
/// everything else back to whatever is behind the panel. It deliberately never
/// returns *itself* for a point on the lozenge: doing so replaces the real
/// SwiftUI element with an anonymous view, which silently removes the
/// indicator from accessibility hit-testing. Suppressing clicks during a morph
/// is SwiftUI's job (see `allowsHitTesting` on the tray), not this view's.
final class CepessaFloatingPanelContainerView: NSView {
  var interactiveRect: CGRect = .zero

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = superview.map { convert(point, from: $0) } ?? point
    guard interactiveRect.contains(local) else { return nil }
    return super.hitTest(point)
  }
}

@MainActor
final class CepessaSessionFloatingBarController: NSObject, NSWindowDelegate {
  static let shared = CepessaSessionFloatingBarController()

  fileprivate enum Constants {
    /// Transparent room around the lozenge for the glass rim and both shadow
    /// layers. Anything less and the panel edge cuts them into a square.
    static let panelBleed = CepessaSessionFloatingBarGeometry.panelBleed
    /// Stores the *content* origin, so future changes to the bleed never move
    /// anyone's indicator.
    static let positionKey = "CepessaSessionsFloatingBarContentOrigin"
    /// Pre-bleed key: a panel origin, migrated once on first launch.
    static let legacyPositionKey = "CepessaSessionsFloatingBarPosition"
    /// Resting distance from the top of the visible screen on first launch.
    /// One bleed puts the panel flush with the visible frame, which is also
    /// where clamping would settle anything closer.
    static let defaultTopInset: CGFloat = panelBleed
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
  private var escapeMonitor: Any?
  private var settleTask: DispatchWorkItem?
  /// True from the moment a morph starts until the panel settles on the new
  /// footprint.
  private var isTransitioning = false
  /// The footprint the in-flight morph is heading for, so a redundant publish
  /// can be recognised and ignored instead of restarting the animation.
  private var pendingContentSize: CGSize?
  /// Invalidates completions and watchdogs belonging to superseded morphs.
  private var transitionToken = 0
  /// Set while the controller is resizing the panel itself, so its own frame
  /// changes cannot re-enter `updateLayout` through the move delegate.
  private var isApplyingPanelFrame = false

  var currentPanel: NSWindow? {
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
    uninstallEscapeMonitor()
    state.noticeMessage = nil
    state.isVisible = false
    panel?.orderOut(nil)
  }

  func stopRecording() {
    guard model?.isRecording == true else { return }
    model?.toggleRecording()
  }

  func startRecording() {
    guard model?.isRecording != true else { return }
    model?.toggleRecording()
  }

  /// Re-shows the indicator after the user hid it.
  func showBar() {
    state.interaction.show()
    UserDefaults.standard.set(true, forKey: Constants.enabledKey)
    syncVisibility()
  }

  var isBarVisible: Bool {
    state.isVisible
  }

  /// True when the user hid the indicator while capture is still live. The
  /// status item surfaces the reversible path back.
  var isHiddenDuringRecording: Bool {
    state.interaction.isHiddenForCurrentRecording && state.isRecording
  }

  // MARK: - Menus

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
      title: "Hide Recording Indicator", action: #selector(hideBarMenuItem), keyEquivalent: "")
    hide.target = self
    menu.addItem(hide)

    let quit = NSMenuItem(
      title: "Quit Cepessa Sessions", action: #selector(quitMenuItem), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)

    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }

  /// Right-click on the indicator. Stop stays one deliberate gesture away even
  /// when the tray is closed.
  func showIndicatorContextMenu() {
    let menu = NSMenu()

    if state.isRecording {
      let stop = NSMenuItem(
        title: "Stop Recording", action: #selector(stopMenuItem), keyEquivalent: "")
      stop.target = self
      menu.addItem(stop)

      let mute = NSMenuItem(
        title: state.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone",
        action: #selector(toggleMuteMenuItem), keyEquivalent: "")
      mute.target = self
      menu.addItem(mute)
    } else {
      let record = NSMenuItem(
        title: "Start Recording", action: #selector(startMenuItem), keyEquivalent: "")
      record.target = self
      menu.addItem(record)
    }

    menu.addItem(.separator())

    let controls = NSMenuItem(
      title: state.interaction.isTrayOpen ? "Close Controls" : "Show Controls",
      action: #selector(toggleTrayMenuItem), keyEquivalent: "")
    controls.target = self
    menu.addItem(controls)

    let hide = NSMenuItem(
      title: "Hide Recording Indicator", action: #selector(hideBarMenuItem), keyEquivalent: "")
    hide.target = self
    menu.addItem(hide)

    menu.addItem(.separator())

    let more = NSMenuItem(
      title: "Sessions Menu", action: #selector(sessionsMenuItem), keyEquivalent: "")
    more.target = self
    menu.addItem(more)

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

  @objc private func stopMenuItem() {
    stopRecording()
  }

  @objc private func startMenuItem() {
    startRecording()
  }

  @objc private func toggleMuteMenuItem() {
    toggleMicrophoneMute()
  }

  @objc private func toggleTrayMenuItem() {
    toggleControlTray()
  }

  @objc private func sessionsMenuItem() {
    showBarMenu()
  }

  @objc private func quitMenuItem() {
    NSApp.terminate(nil)
  }

  // MARK: - Interaction

  func toggleMicrophoneMute() {
    model?.toggleMicrophoneMute()
  }

  func dismissForCurrentRecording() {
    if state.isRecording {
      state.interaction.hideForCurrentRecording()
    } else {
      UserDefaults.standard.set(false, forKey: Constants.enabledKey)
    }
    updateLayout(animated: false)
    syncVisibility()
  }

  /// Pointer proximity changes opacity only — never geometry.
  func setHoveringBar(_ isHovering: Bool) {
    guard state.interaction.isHovered != isHovering else { return }
    state.interaction.hoverChanged(isHovering)
  }

  func toggleControlTray() {
    state.interaction.toggleTray()
    syncEscapeMonitor()
    updateLayout(animated: true)
  }

  func closeControlTray() {
    guard state.interaction.isTrayOpen else { return }
    state.interaction.closeTray()
    syncEscapeMonitor()
    updateLayout(animated: true)
  }

  private func syncEscapeMonitor() {
    if state.interaction.isTrayOpen {
      guard escapeMonitor == nil else { return }
      escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard event.keyCode == 53 else { return event }
        Task { @MainActor in self?.closeControlTray() }
        return nil
      }
    } else {
      uninstallEscapeMonitor()
    }
  }

  private func uninstallEscapeMonitor() {
    if let escapeMonitor {
      NSEvent.removeMonitor(escapeMonitor)
    }
    escapeMonitor = nil
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
              ? "File pinned at \(self.state.compactTimerText)."
              : "\(importedCount) files pinned at \(self.state.compactTimerText).",
            style: .success
          )
        } else if lastError != nil {
          self.showNotice("File attachment failed.", style: .error)
        }
      }
    }
  }

  /// Only a *user* drag reaches here as a real move. The controller's own
  /// resizes also fire this delegate, and letting them re-enter `updateLayout`
  /// cancelled the settle that was about to run and wrote the animation's
  /// target straight into state — killing the morph it had just started.
  func windowDidMove(_ notification: Notification) {
    guard panel != nil, !isApplyingPanelFrame, !isTransitioning else { return }
    updateLayout(animated: false)
  }

  private func bind(to model: LocalMeetingAppModel) {
    cancellables.removeAll()

    // `@Published` re-publishes on every assignment, not only on change, and
    // these two sinks reset the tray. Without `removeDuplicates` a redundant
    // `isRecording = false` closed a tray the user had deliberately opened.
    model.$isRecording
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isRecording in
        if isRecording {
          // Every recording starts visible and deliberately at rest.
          self?.state.interaction.recordingDidStart()
        } else {
          self?.state.interaction.recordingDidEnd()
        }
        self?.syncEscapeMonitor()
        self?.refreshState()
        self?.syncVisibility()
      }
      .store(in: &cancellables)

    model.$isTranscribing
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshState()
        self?.syncVisibility()
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

    model.$recordingDurationText
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        guard let self else { return }
        let hoursChanged =
          CepessaSessionIndicatorTimer.showsHours(self.state.timerText)
          != CepessaSessionIndicatorTimer.showsHours(value)
        self.state.timerText = value
        if hoursChanged {
          self.updateLayout(animated: true)
        }
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
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = false
    panel.delegate = self

    let hostingView = NSHostingView(
      rootView: CepessaSessionFloatingBarView(controller: self, state: state))

    let container = CepessaFloatingPanelContainerView()
    container.wantsLayer = true
    hostingView.frame = container.bounds
    hostingView.autoresizingMask = [.width, .height]
    container.addSubview(hostingView)

    panel.contentView = container
    panel.setContentSize(preferredPanelSize)
    refreshLayoutMetrics()

    if let contentOrigin = restoredContentOrigin() {
      panel.setFrameOrigin(
        CepessaSessionFloatingBarGeometry.panelOrigin(
          forContentOrigin: contentOrigin, bleed: Constants.panelBleed))
      clamp(panel: panel)
    } else {
      positionPanel(panel)
    }

    self.panel = panel
    self.hostingView = hostingView
    applyPanelSize()
  }

  /// The saved resting *content* origin, migrating a pre-bleed panel origin
  /// once so an existing install does not find its indicator shifted.
  private func restoredContentOrigin() -> NSPoint? {
    let defaults = UserDefaults.standard

    if let saved = defaults.string(forKey: Constants.positionKey) {
      return NSPointFromString(saved)
    }

    guard let legacy = defaults.string(forKey: Constants.legacyPositionKey) else { return nil }
    let migrated = CepessaSessionFloatingBarGeometry.migratedContentOrigin(
      fromLegacyPanelOrigin: NSPointFromString(legacy))
    defaults.set(NSStringFromPoint(migrated), forKey: Constants.positionKey)
    return migrated
  }

  private func positionPanel(_ panel: NSPanel) {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let frame = screen.visibleFrame
    let contentSize = state.panelContentSize
    let contentOrigin = NSPoint(
      x: frame.midX - (contentSize.width / 2),
      y: frame.maxY - Constants.defaultTopInset - contentSize.height
    )
    panel.setFrameOrigin(
      CepessaSessionFloatingBarGeometry.panelOrigin(
        forContentOrigin: contentOrigin, bleed: Constants.panelBleed))
    clamp(panel: panel)
  }

  private func refreshState() {
    guard let model else { return }

    state.isRecording = model.isRecording
    state.isTranscribing = model.isTranscribing
    state.isMicrophoneCaptureActive = model.isMicrophoneCaptureActive
    state.isMicrophoneMuted = model.isMicrophoneMuted
    state.isSystemAudioCaptureActive = model.isSystemAudioCaptureActive
    state.timerText = model.recordingDurationText
    state.errorMessage = model.recorderErrorMessage
    state.processingStatusTitle = model.processingStatusTitle
    state.processingStatusDetail = model.processingStatusDetail
    state.processingProgress = model.processingProgress
    state.processingQueue = processingQueueItems(from: model)

    if let session = activeSession() {
      state.title = session.title
      state.attachmentDeck = CepessaSessionFloatingAttachmentDeck.build(from: session)
      switch session.status {
      case .recording:
        state.statusMessage =
          state.isMicrophoneMuted
          ? "Recording on this Mac. The microphone is muted in the transcript mix."
          : "Recording on this Mac."
      case .transcribing:
        state.statusMessage = model.processingStatusDetail ?? "Finishing the local transcript."
      case .ready:
        state.statusMessage = "Session saved locally."
      case .failed:
        state.statusMessage = "Processing stopped. Open the session for details."
      }
    } else if model.isTranscribing {
      state.title = model.processingStatusTitle ?? "Processing session"
      state.statusMessage = model.processingStatusDetail ?? "Finishing the local transcript."
      if let lastSession = model.sessions.first(where: { $0.status == .transcribing }) {
        state.attachmentDeck = CepessaSessionFloatingAttachmentDeck.build(from: lastSession)
      } else {
        state.attachmentDeck = .empty
      }
    } else {
      state.title = "Session capture idle"
      state.statusMessage = "Start a session to keep audio and context in one timeline."
      state.attachmentDeck = .empty
    }

    updateLayout(animated: true)
  }

  private func syncVisibility() {
    guard let panel else { return }
    let shouldShow = isFloatingBarEnabled && !state.interaction.isHiddenForCurrentRecording
    state.isVisible = shouldShow

    if shouldShow {
      if !panel.isVisible {
        panel.orderFrontRegardless()
      }
    } else {
      panel.orderOut(nil)
    }

    CepessaSessionStatusBarController.shared.refreshAccessibilityState()
  }

  private var isFloatingBarEnabled: Bool {
    let value = UserDefaults.standard.object(forKey: Constants.enabledKey) as? Bool
    return value ?? false
  }

  private var preferredPanelSize: NSSize {
    panelSize(for: state.panelContentSize)
  }

  private func panelSize(for contentSize: CGSize) -> NSSize {
    let size = CepessaSessionFloatingBarGeometry.panelSize(
      for: contentSize, bleed: Constants.panelBleed)
    return NSSize(width: size.width, height: size.height)
  }

  private var restingContentSize: CGSize {
    CepessaSessionFloatingBarGeometry.idleSize
  }

  private var currentBarContentSize: CGSize {
    let availableWidth =
      (panel.flatMap { screen(for: $0.frame) } ?? NSScreen.main ?? NSScreen.screens.first)?
      .visibleFrame.width
    return CepessaSessionFloatingBarGeometry.contentSize(
      for: state.mode,
      showsHours: state.showsHours,
      isRecording: state.isRecording,
      hasNotice: state.hasNotice,
      availableScreenWidth: availableWidth
    )
  }

  private func refreshLayoutMetrics() {
    let size = currentBarContentSize
    if state.barContentSize != size {
      state.barContentSize = size
    }
    if state.panelContentSize != size && !isTransitioning {
      state.panelContentSize = size
    }
  }

  /// Grow the panel, morph the lozenge, settle the panel.
  ///
  /// The order is the whole trick. If the panel resized in step with the
  /// shape, the glass would be clipped for the entire animation; if it never
  /// resized, the resting dot could not be parked near a screen edge. Taking
  /// the union up front and giving it back at the end buys both.
  ///
  /// The shrink is driven by SwiftUI's own completion callback rather than a
  /// timer, because a spring settles well after its `response`. Resizing the
  /// host window out from under an animation that is still running leaves the
  /// glass mid-flight and is exactly how the collapsed indicator went missing.
  private func updateLayout(animated: Bool) {
    let target = currentBarContentSize

    // A redundant publish must not cancel, restart, or short-circuit a morph
    // that is already on its way to the same footprint.
    if isTransitioning, target == pendingContentSize { return }

    settleTask?.cancel()
    settleTask = nil

    let current = state.barContentSize
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    guard animated, !reduceMotion, target != current else {
      settleLayout()
      return
    }

    transitionToken &+= 1
    let token = transitionToken
    pendingContentSize = target
    isTransitioning = true
    state.isTransitioning = true

    // Grow first: the panel is never smaller than the shape inside it.
    state.panelContentSize = CepessaSessionIndicatorTransition.panelContentSize(
      from: current, to: target)
    applyPanelSize()

    withAnimation(CepessaChrome.Motion.expand) {
      state.barContentSize = target
    } completion: { [weak self] in
      self?.settleLayout(ifToken: token)
    }

    // Watchdog. The panel must never be stranded on the union footprint if the
    // completion is lost — a view torn down mid-animation, or an animation
    // pre-empted before it ever attached, would otherwise leave the indicator
    // sized for a tray that is no longer on screen.
    let settle = DispatchWorkItem { [weak self] in
      self?.settleLayout(ifToken: token)
    }
    settleTask = settle
    DispatchQueue.main.asyncAfter(
      deadline: .now() + CepessaChrome.Motion.settleTimeout, execute: settle)
  }

  private func settleLayout(ifToken token: Int) {
    guard token == transitionToken else { return }
    settleLayout()
  }

  /// Lands the panel on the footprint the current state actually wants.
  ///
  /// Idempotent and self-invalidating: bumping the token means any completion
  /// or watchdog still in flight for an earlier morph is ignored, so a
  /// superseded callback can never resize the panel for a stale state.
  private func settleLayout() {
    settleTask?.cancel()
    settleTask = nil
    transitionToken &+= 1
    pendingContentSize = nil
    isTransitioning = false
    state.isTransitioning = false

    let target = currentBarContentSize
    state.barContentSize = target
    state.panelContentSize = target
    applyPanelSize()

    // The shape has stopped moving: make sure what is on screen agrees.
    hostingView?.needsDisplay = true
    panel?.invalidateShadow()
  }

  private func applyPanelSize() {
    guard let panel else { return }
    let targetSize = preferredPanelSize

    guard panel.frame.size != targetSize else {
      updateInteractiveRect()
      return
    }

    // Grow/shrink around the horizontal centre and the top edge so the lozenge
    // stays where the user put it, and clamp the target frame (not the stale
    // pre-resize one).
    var nextFrame = panel.frame
    nextFrame.origin.x += (panel.frame.width - targetSize.width) / 2
    nextFrame.origin.y -= targetSize.height - panel.frame.height
    nextFrame.size = targetSize
    nextFrame.origin = clampedOrigin(for: nextFrame)

    // The panel adopts each footprint atomically; SwiftUI owns the motion.
    // Animating the NSPanel frame instead can re-enter AppKit's constraint
    // pass while the hosting view is mid-layout and raise an exception.
    isApplyingPanelFrame = true
    panel.setFrame(nextFrame, display: true)
    isApplyingPanelFrame = false
    updateInteractiveRect()
  }

  /// Teaches the panel which part of itself is the indicator.
  private func updateInteractiveRect() {
    guard let container = panel?.contentView as? CepessaFloatingPanelContainerView else { return }
    container.interactiveRect = CepessaSessionIndicatorTransition.interactiveRect(
      contentSize: state.barContentSize,
      panelContentSize: state.panelContentSize,
      panelSize: panelSize(for: state.panelContentSize),
      isTransitioning: isTransitioning
    )
  }

  fileprivate func beginPanelDrag(with event: NSEvent) {
    guard let panel else { return }
    panel.performDrag(with: event)

    let contentOrigin = CepessaSessionFloatingBarGeometry.restingContentOrigin(
      afterDragging: panel.frame,
      restingContentSize: restingContentSize,
      bleed: Constants.panelBleed
    )
    var restingFrame = NSRect(
      origin: CepessaSessionFloatingBarGeometry.panelOrigin(
        forContentOrigin: contentOrigin, bleed: Constants.panelBleed),
      size: panelSize(for: restingContentSize)
    )
    restingFrame.origin = clampedOrigin(for: restingFrame)

    UserDefaults.standard.set(
      NSStringFromPoint(
        NSPoint(
          x: restingFrame.origin.x + Constants.panelBleed,
          y: restingFrame.origin.y + Constants.panelBleed
        )
      ),
      forKey: Constants.positionKey
    )
    updateInteractiveRect()
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
      showNotice(
        interactive
          ? "Region pinned at \(state.compactTimerText)."
          : "Screenshot pinned at \(state.compactTimerText).",
        style: .success
      )
    } catch is CancellationError {
      return
    } catch {
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
    LocalSessionStorageRoot.defaultBaseDirectory
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
    updateLayout(animated: true)

    noticeDismissTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 2_400_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self else { return }
        self.state.noticeMessage = nil
        self.state.noticeStyle = .neutral
        self.updateLayout(animated: true)
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

// MARK: - View

private struct CepessaSessionFloatingBarView: View {
  let controller: CepessaSessionFloatingBarController
  @ObservedObject var state: CepessaSessionFloatingBarState

  var body: some View {
    SessionIndicatorLozenge(controller: controller, state: state)
      // The panel carries transparent bleed around the lozenge; filling it and
      // centring is what keeps the glass off the window edge.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onExitCommand(perform: controller.closeControlTray)
      .accessibilityIdentifier("cepessa.floatingBar")
  }
}

// MARK: The lozenge

/// One object, four states.
///
/// The resting dot, the recording lozenge and the open tray are the same view
/// changing width — never separate subtrees swapping places. The state ring is
/// the first child in every state, so as the capsule grows the ring rides its
/// leading edge outward and rides back on the way in; that continuity is the
/// entire reason the expansion reads as one thing opening rather than two
/// things cross-fading.
///
/// Geometry follows `state.barContentSize`, which only ever changes because
/// the app's state changed or the user deliberately clicked. Hover reaches the
/// lighting and nothing else.
private struct SessionIndicatorLozenge: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let controller: CepessaSessionFloatingBarController
  @ObservedObject var state: CepessaSessionFloatingBarState

  private var isTray: Bool { state.interaction.isTrayOpen }

  var body: some View {
    HStack(spacing: 0) {
      SessionStateRing(ring: state.ring)
        .frame(width: CepessaChrome.Control.micro, height: CepessaChrome.Control.micro)
        .overlay { trayHandle }

      if isTray {
        SessionTrayTail(controller: controller, state: state)
          .transition(tailTransition)
          // A collapsing tray must not deliver the release to whichever
          // control slid under the pointer — Record and Stop above all.
          .allowsHitTesting(
            CepessaSessionIndicatorTransition.acceptsClicks(
              isTransitioning: state.isTransitioning))
      } else if state.isRecording {
        SessionRestingTimer(state: state)
          .transition(tailTransition)
      }
    }
    .padding(.leading, leadingInset)
    .padding(.trailing, trailingInset)
    // Leading alignment is what makes the morph continuous. The tray's
    // contents finish fading out well before the capsule finishes closing, and
    // a centred row would snap the ring to the middle the instant they leave.
    // Anchored to the leading edge it simply rides the closing capsule in.
    .frame(
      width: state.barContentSize.width,
      height: state.barContentSize.height,
      alignment: .leading
    )
    // Contents are clipped to the shape so a tray that is still fading out is
    // absorbed by the collapsing capsule instead of spilling past its edge.
    .clipShape(Capsule())
    .cepessaGlass(
      in: Capsule(),
      interactive: true,
      elevation: isTray ? .lifted : .resting,
      isHighlighted: state.interaction.isHovered
    )
    .overlay { restingHitArea }
    .onHover(perform: controller.setHoveringBar)
    .animation(motion, value: state.barContentSize)
    .animation(motion, value: isTray)
    // Hover reaches the lighting only, and settles on its own short curve so
    // it never borrows the expansion timing.
    .animation(
      reduceMotion ? nil : CepessaChrome.Motion.state, value: state.interaction.isHovered
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(isTray ? "Recording controls" : "Cepessa Sessions")
    .accessibilityIdentifier(
      isTray ? "cepessa.floatingBar.tray" : "cepessa.floatingBar.indicator")
  }

  private var motion: Animation? {
    CepessaChrome.Motion.expand(reduceMotion: reduceMotion)
  }

  private var tailTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .opacity.animation(CepessaChrome.Motion.contentIn),
      removal: .opacity.animation(CepessaChrome.Motion.contentOut)
    )
  }

  /// The ring keeps its own 22pt frame in every state; only in the tray does
  /// it also become the close affordance. The idle dot takes no inset at all —
  /// the ring's frame already carries 5pt of clearance around a 12pt circle.
  private var leadingInset: CGFloat {
    if isTray { return 5 }
    return state.isRecording ? 2 : 0
  }

  private var trailingInset: CGFloat {
    if isTray { return 6 }
    return state.isRecording ? 6 : 0
  }

  /// Resting: the whole lozenge is one button — click opens the tray, drag
  /// moves it, right-click reaches Stop without opening anything.
  @ViewBuilder
  private var restingHitArea: some View {
    if !isTray {
      SessionIndicatorHitArea(
        onClick: controller.toggleControlTray,
        onSecondaryClick: controller.showIndicatorContextMenu,
        onHover: controller.setHoveringBar,
        onDrag: controller.beginPanelDrag
      )
      .help(restingHelpText)
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(
        CepessaSessionIndicatorAccessibility.indicatorLabel(
          mode: state.mode,
          isRecording: state.isRecording,
          health: state.captureHealth,
          timerText: state.timerText,
          progress: state.processingProgress
        )
      )
      .accessibilityValue(
        CepessaSessionIndicatorAccessibility.indicatorValue(
          isRecording: state.isRecording,
          timerText: state.timerText,
          progress: state.processingProgress
        )
      )
      .accessibilityHint(CepessaSessionIndicatorAccessibility.indicatorHint(isTrayOpen: false))
      // Default activation (VO-Space) opens the tray; the named actions are
      // the rotor entries beside it.
      .accessibilityAction { controller.toggleControlTray() }
      .accessibilityAction(named: "Show Controls", controller.toggleControlTray)
      .accessibilityAction(named: state.isRecording ? "Stop Recording" : "Start Recording") {
        if state.isRecording {
          controller.stopRecording()
        } else {
          controller.startRecording()
        }
      }
      .accessibilityIdentifier("cepessa.floatingBar.recordingSummary")
    }
  }

  /// Tray: the ring alone stays draggable and closes the tray, so the controls
  /// beside it can be clicked without the whole row acting as one button.
  @ViewBuilder
  private var trayHandle: some View {
    if isTray {
      SessionIndicatorHitArea(
        onClick: controller.closeControlTray,
        onSecondaryClick: controller.showIndicatorContextMenu,
        onHover: controller.setHoveringBar,
        onDrag: controller.beginPanelDrag
      )
      .help("Close the controls. Drag to move.")
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel("Close recording controls")
      .accessibilityHint(CepessaSessionIndicatorAccessibility.indicatorHint(isTrayOpen: true))
      .accessibilityAction { controller.closeControlTray() }
      .accessibilityAction(named: "Close Controls", controller.closeControlTray)
      .accessibilityIdentifier("cepessa.floatingBar.minimize")
    }
  }

  private var restingHelpText: String {
    state.isRecording
      ? "Recording \(state.compactTimerText). Click for controls, drag to move."
      : "Cepessa Sessions. Click for controls, drag to move."
  }
}

/// The advancing timer beside the ring while capture is live and the tray is
/// closed. Monospaced so the lozenge never reflows on a digit change.
private struct SessionRestingTimer: View {
  @ObservedObject var state: CepessaSessionFloatingBarState

  var body: some View {
    Text(state.compactTimerText)
      .font(.system(size: 11, weight: .medium, design: .monospaced))
      .monospacedDigit()
      .foregroundStyle(CepessaColors.textPrimary)
      .lineLimit(1)
      .fixedSize()
      .padding(.leading, 2)
      .accessibilityHidden(true)
  }
}

/// The single state ring. Shape carries the meaning; colour only confirms it.
///
/// At rest this ring *is* the app on screen, sitting on whatever the user
/// happens to be reading — so the idle stroke is a full secondary label rather
/// than the tertiary grey it used to be. Tertiary on a white document is a
/// suggestion; the indicator has to be a statement.
private struct SessionStateRing: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  let ring: CepessaSessionIndicatorRing

  private let diameter: CGFloat = 12
  private let lineWidth: CGFloat = 1.6

  var body: some View {
    ZStack {
      switch ring {
      case .idle:
        Circle()
          .strokeBorder(idleStroke, lineWidth: lineWidth)

      case .processing(let progress):
        Circle()
          .strokeBorder(CepessaColors.textTertiary, lineWidth: lineWidth)
        Circle()
          .trim(from: 0, to: progress.map { CGFloat(min(max($0, 0.02), 1)) } ?? 0.28)
          .stroke(
            CepessaColors.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
          .padding(0.8)

      case .recording:
        Circle()
          .strokeBorder(CepessaColors.signalRed, lineWidth: lineWidth)
        Circle()
          .fill(CepessaColors.signalRed)
          .frame(width: diameter * 0.42, height: diameter * 0.42)

      case .recordingMuted:
        Circle()
          .strokeBorder(CepessaColors.signalRed, lineWidth: lineWidth)
        Capsule()
          .fill(CepessaColors.signalRed)
          .frame(width: diameter * 0.86, height: 1.6)
          .rotationEffect(.degrees(-45))

      case .degraded:
        Circle()
          .strokeBorder(
            CepessaColors.warning,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [2.2, 2.2])
          )

      case .fault:
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(CepessaColors.warning)
      }
    }
    .frame(width: diameter, height: diameter)
    .animation(reduceMotion ? nil : CepessaChrome.Motion.state, value: ring)
    .accessibilityHidden(true)
  }

  private var idleStroke: Color {
    colorSchemeContrast == .increased ? CepessaColors.textPrimary : CepessaColors.textSecondary
  }
}

// MARK: Control tray

/// Everything the tray adds to the ring, in three parts with a fixed rhythm:
/// a hairline that separates state from readout, one line of status text, and
/// a trailing cluster of equal 22pt circular slots.
///
/// The equal slots are the point. The tray used to end with a wide pale
/// "Record" capsule that outweighed everything beside it, so the row read as
/// one big button with some decoration around it. Every control now occupies
/// the same footprint and the transport control — record, then stop — always
/// sits last, which gives the row a metronome and keeps the primary action in
/// one place across both states.
private struct SessionTrayTail: View {
  let controller: CepessaSessionFloatingBarController
  @ObservedObject var state: CepessaSessionFloatingBarState

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(CepessaColors.textQuaternary)
        .frame(width: 1, height: 13)
        .padding(.horizontal, 7)
        .accessibilityHidden(true)

      statusText

      Spacer(minLength: CepessaChrome.Space.s)

      HStack(spacing: 2) {
        if state.isRecording {
          SessionTrayIconButton(
            icon: state.isMicrophoneMuted ? "mic.slash" : "mic",
            title: state.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone",
            isProminent: state.isMicrophoneMuted,
            action: controller.toggleMicrophoneMute
          )
          .accessibilityIdentifier("cepessa.floatingBar.mute")

          SessionTrayCaptureMenu(controller: controller)
        }

        SessionTrayIconButton(
          icon: "eye.slash",
          title: "Hide the recording indicator",
          action: controller.dismissForCurrentRecording
        )
        .accessibilityIdentifier("cepessa.floatingBar.hide")

        SessionTrayIconButton(
          icon: "ellipsis",
          title: "Sessions menu",
          action: controller.showBarMenu
        )

        SessionTrayTransportButton(
          isRecording: state.isRecording,
          action: state.isRecording ? controller.stopRecording : controller.startRecording
        )
      }
    }
  }

  private var statusText: some View {
    HStack(spacing: 4) {
      // Only a notice that reports a problem earns a glyph. A confirmation
      // reads fine on its own, and the state ring already carries the state.
      if let symbol = problemSymbol {
        Image(systemName: symbol)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(CepessaColors.warning)
          .accessibilityHidden(true)
      }

      Text(state.trayStatusText)
        .font(.system(size: 11, weight: .medium, design: usesMonospace ? .monospaced : .default))
        .monospacedDigit()
        .foregroundStyle(tint)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
    .accessibilityIdentifier("cepessa.floatingBar.status")
  }

  private var problemSymbol: String? {
    if state.hasNotice {
      switch state.noticeStyle {
      case .warning, .error: return "exclamationmark.triangle.fill"
      case .neutral, .success: return nil
      }
    }
    return state.hasFault && !state.isRecording ? "exclamationmark.triangle.fill" : nil
  }

  private var usesMonospace: Bool {
    CepessaSessionIndicatorTrayStatus.usesMonospacedDigits(
      isRecording: state.isRecording, hasNotice: state.hasNotice)
  }

  private var tint: Color {
    if state.hasNotice || state.isRecording { return CepessaColors.textPrimary }
    return state.hasFault ? CepessaColors.textPrimary : CepessaColors.textSecondary
  }

  /// VoiceOver gets the sentence; the capsule gets the short form.
  private var accessibilityText: String {
    if let notice = state.noticeMessage { return notice }
    if state.isRecording {
      return "Recording duration "
        + CepessaSessionIndicatorAccessibility.compactSpokenTimer(state.timerText)
    }
    if state.hasFault, let error = state.errorMessage { return error }
    return state.trayStatusText
  }
}

private struct SessionTrayIconButton: View {
  @State private var isHovered = false

  let icon: String
  let title: String
  var isProminent = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 11, weight: .medium))
        .frame(width: CepessaChrome.Control.micro, height: CepessaChrome.Control.micro)
        .foregroundStyle(tint)
        .background(
          Circle().fill(
            isHovered ? CepessaColors.textPrimary.opacity(0.1) : Color.clear)
        )
        .contentShape(Circle())
    }
    .buttonStyle(CepessaPressStyle(scale: 0.94))
    .onHover { isHovered = $0 }
    .help(title)
    .accessibilityLabel(title)
  }

  private var tint: Color {
    isProminent ? CepessaColors.warning : CepessaColors.textSecondary
  }
}

/// The transport control: start when nothing is running, stop when capture is
/// live. Same slot, same size, same place — only the fill and the glyph change,
/// so the one saturated element in the indicator never moves.
private struct SessionTrayTransportButton: View {
  @State private var isHovered = false

  let isRecording: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle().fill(fill)

        if isRecording {
          // White on `systemRed` is the platform's own stop-button pairing and
          // is the only fixed foreground left in the app; the fill beneath it
          // is a fixed hue in both appearances, so a semantic label colour
          // here would invert into red-on-red in dark mode.
          Image(systemName: "stop.fill")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(Color.white)
        } else {
          Circle()
            .fill(CepessaColors.signalRed)
            .frame(width: 8, height: 8)
        }
      }
      .frame(width: CepessaChrome.Control.micro, height: CepessaChrome.Control.micro)
      .contentShape(Circle())
    }
    .buttonStyle(CepessaPressStyle(scale: 0.92, pressedBrightness: -0.05))
    .onHover { isHovered = $0 }
    .help(isRecording ? "Stop recording" : "Start a new recording session")
    .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    .accessibilityHint(
      isRecording
        ? "Ends capture and begins final transcription."
        : "Begins a new local recording session."
    )
    .accessibilityIdentifier(
      isRecording ? "cepessa.floatingBar.stop" : "cepessa.floatingBar.record")
  }

  private var fill: Color {
    if isRecording { return CepessaColors.signalRed }
    return CepessaColors.signalRed.opacity(isHovered ? 0.26 : 0.16)
  }
}

/// Capture and attachment live one deliberate step deeper: never at rest, and
/// never as four separate buttons in the tray.
private struct SessionTrayCaptureMenu: View {
  let controller: CepessaSessionFloatingBarController

  var body: some View {
    Menu {
      Button("Capture Screen", action: controller.captureFullScreenshot)
      Button("Capture Region", action: controller.captureRegionScreenshot)
      Button("Attach File…", action: controller.importDocument)
    } label: {
      Image(systemName: "camera")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(CepessaColors.textSecondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .frame(width: CepessaChrome.Control.micro, height: CepessaChrome.Control.micro)
    .help("Pin a screenshot or file to this moment")
    .accessibilityLabel("Capture or attach")
    .accessibilityIdentifier("cepessa.floatingBar.capture")
  }
}

// MARK: Hit testing

/// A 22pt target has to serve click, right-click and drag without any of them
/// stealing the others. AppKit resolves the ambiguity by distance: past a few
/// points of movement the gesture becomes a window drag, otherwise it is a
/// click on mouse-up.
private struct SessionIndicatorHitArea: NSViewRepresentable {
  let onClick: () -> Void
  let onSecondaryClick: () -> Void
  let onHover: (Bool) -> Void
  let onDrag: (NSEvent) -> Void

  func makeNSView(context: Context) -> SessionIndicatorHitNSView {
    let view = SessionIndicatorHitNSView()
    view.configure(
      onClick: onClick, onSecondaryClick: onSecondaryClick, onHover: onHover, onDrag: onDrag)
    return view
  }

  func updateNSView(_ nsView: SessionIndicatorHitNSView, context: Context) {
    nsView.configure(
      onClick: onClick, onSecondaryClick: onSecondaryClick, onHover: onHover, onDrag: onDrag)
  }
}

final class SessionIndicatorHitNSView: NSView {
  private var onClick: () -> Void = {}
  private var onSecondaryClick: () -> Void = {}
  private var onHover: (Bool) -> Void = { _ in }
  private var onDrag: (NSEvent) -> Void = { _ in }
  private var trackingArea: NSTrackingArea?

  private let dragThreshold: CGFloat = 3

  func configure(
    onClick: @escaping () -> Void,
    onSecondaryClick: @escaping () -> Void,
    onHover: @escaping (Bool) -> Void,
    onDrag: @escaping (NSEvent) -> Void
  ) {
    self.onClick = onClick
    self.onSecondaryClick = onSecondaryClick
    self.onHover = onHover
    self.onDrag = onDrag
  }

  override var isOpaque: Bool { false }

  /// The SwiftUI indicator above this view carries the accessibility element;
  /// the bare hit target must not appear as a second, unlabelled one.
  override func accessibilityIsIgnored() -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    onHover(true)
  }

  override func mouseExited(with event: NSEvent) {
    onHover(false)
  }

  override func mouseDown(with event: NSEvent) {
    let origin = event.locationInWindow

    while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
      switch next.type {
      case .leftMouseDragged:
        let delta = hypot(
          next.locationInWindow.x - origin.x, next.locationInWindow.y - origin.y)
        if delta > dragThreshold {
          onDrag(event)
          return
        }
      case .leftMouseUp:
        onClick()
        return
      default:
        return
      }
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    onSecondaryClick()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }
}
