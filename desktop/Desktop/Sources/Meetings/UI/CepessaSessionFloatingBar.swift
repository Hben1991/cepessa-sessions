import AppKit
import Combine
import SwiftUI

@MainActor
final class CepessaSessionsStore {
  static let shared = CepessaSessionsStore()

  let model: LocalMeetingAppModel
  let captureLifecycle: LocalCaptureLifecycle

  private init() {
    let lifecycle = LocalCaptureLifecycle()
    self.captureLifecycle = lifecycle
    self.model = LocalMeetingAppModel(
      installsTranscriptionModelOnDemand: !LocalSessionStorageRoot.isIsolatedTestRoot,
      captureLifecycle: lifecycle
    )
  }
}

enum CepessaSessionFloatingBarPreferences {
  static let enabledKey = "cepessa.sessions.floatingBarEnabled"
  static let legacyDefaultOffMigrationKey = "cepessa.sessions.floatingBarDefaultOffMigrated"
  static let defaultOnMigrationKey = "cepessa.sessions.floatingBarDefaultOnMigrated"
  /// The owner's choice to keep the recording capsule collapsed.
  static let compactKey = "cepessa.sessions.capsuleCompact"

  static func installDefaults(in defaults: UserDefaults = .standard) {
    defaults.register(defaults: [
      enabledKey: true,
      legacyDefaultOffMigrationKey: true,
      defaultOnMigrationKey: false,
      compactKey: false,
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

enum CepessaSessionCaptureControlPolicy: Equatable {
  case startSession
  case cancelSessionStart
  case stopSession
  case unavailable

  static func resolve(_ phase: LocalCaptureLifecycle.Phase) -> Self {
    switch phase {
    case .idle:
      return .startSession
    case .starting:
      return .cancelSessionStart
    case .recording:
      return .stopSession
    case .stopping:
      return .unavailable
    }
  }

  var allowsStoppingSession: Bool {
    self == .cancelSessionStart || self == .stopSession
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
  @Published var capturePhase: LocalCaptureLifecycle.Phase = .idle
  @Published var isMicrophoneCaptureActive = false
  @Published var isMicrophoneMuted = false
  @Published var isSystemAudioCaptureActive = false
  @Published var micLevel: Double = 0
  @Published var systemLevel: Double = 0
  @Published var timerText = "00:00:00"
  @Published var errorMessage: String?
  @Published var noticeMessage: String?
  @Published var noticeStyle: NoticeStyle = .neutral
  @Published var interaction = CepessaSessionCapsuleInteraction()
  @Published var isCompact = false
  /// The capsule itself. Animated — this is the shape that morphs.
  @Published var barContentSize = CepessaSessionCapsuleMetrics.contentSize(
    for: .init(phase: .idle))
  /// The footprint the panel is sized for: `barContentSize` at rest, the union
  /// of both footprints while the capsule morphs.
  @Published var panelContentSize = CepessaSessionCapsuleMetrics.contentSize(
    for: .init(phase: .idle))
  /// True while the capsule is changing shape. Only the controls read it; the
  /// orb stays live throughout, so a transition that failed to end can never
  /// leave the recorder unclickable.
  @Published var isTransitioning = false
  @Published var processingProgress: Double?
  @Published var processingStage: String?

  var phase: CepessaSessionCapsulePhase {
    switch capturePhase {
    case .starting, .stopping: return .preparing
    case .recording: return .recording
    case .idle: break
    }
    if isRecording { return .recording }
    if isTranscribing { return .processing }
    return hasFault ? .attention : .idle
  }

  var layout: CepessaSessionCapsuleLayout {
    CepessaSessionCapsuleLayout(
      phase: phase,
      isCompact: isCompact,
      showsHours: CepessaSessionIndicatorTimer.showsHours(timerText),
      hasNotice: hasNotice
    )
  }

  var isStopping: Bool {
    if case .stopping = capturePhase { return true }
    return false
  }

  var canActivateSessionTransport: Bool {
    CepessaSessionCaptureControlPolicy.resolve(capturePhase) != .unavailable
  }

  var sessionTransportTitle: String {
    switch capturePhase {
    case .idle: return "Start Recording"
    case .starting: return "Cancel Starting Recording"
    case .recording: return "Stop Recording"
    case .stopping: return "Stopping Recording…"
    }
  }

  var captureHealth: CepessaSessionCaptureHealth {
    CepessaSessionCaptureHealth.resolve(
      microphoneActive: isMicrophoneCaptureActive,
      microphoneMuted: isMicrophoneMuted,
      systemAudioActive: isSystemAudioCaptureActive,
      hasError: hasFault
    )
  }

  var orbMood: SessionsOrb.Mood {
    SessionsOrb.Mood.resolve(phase: phase, health: captureHealth, progress: processingProgress)
  }

  var compactTimerText: String {
    CepessaSessionIndicatorTimer.compactText(from: timerText)
  }

  var hasNotice: Bool {
    noticeMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }

  var hasFault: Bool {
    errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }
}

/// The panel's content view: a pass-through filter and nothing else.
///
/// The panel is larger than the capsule — it carries transparent bleed so the
/// shadows are never clipped — so it decides which points count as the
/// capsule and hands everything else back to whatever is behind it. It never
/// returns *itself* for a point on the capsule: that would replace the real
/// SwiftUI element with an anonymous view and remove the recorder from
/// accessibility hit-testing.
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
    static let panelBleed = CepessaSessionCapsuleMetrics.panelBleed
    /// The capsule's top-centre point, in screen coordinates.
    static let anchorKey = "CepessaSessionsCapsuleAnchor"
    /// Saved by the former 22pt indicator: its content origin.
    static let legacyContentOriginKey = "CepessaSessionsFloatingBarContentOrigin"
    /// Resting distance from the top of the visible screen on first launch.
    static let defaultTopInset: CGFloat = 12
    static let enabledKey = CepessaSessionFloatingBarPreferences.enabledKey
    static let compactKey = CepessaSessionFloatingBarPreferences.compactKey
  }

  let state = CepessaSessionFloatingBarState()

  private weak var model: LocalMeetingAppModel?
  private var panel: NSPanel?
  private var hostingView: NSHostingView<CepessaSessionCapsuleView>?
  private var cancellables: Set<AnyCancellable> = []
  private var levelCancellables: Set<AnyCancellable> = []
  private var liveSessionSnapshot: LocalSession?
  private var liveSessionID: UUID?
  private var applyingLiveSessionSnapshot = false
  private var noticeDismissTask: Task<Void, Never>?
  private var settleTask: DispatchWorkItem?
  /// True from the moment a morph starts until the panel settles.
  private var isTransitioning = false
  /// Where the in-flight morph is heading, so a redundant publish can be
  /// recognised and ignored instead of restarting the animation.
  private var pendingContentSize: CGSize?
  /// Invalidates completions and watchdogs belonging to superseded morphs.
  private var transitionToken = 0
  /// Set while the controller resizes the panel itself, so its own frame
  /// changes cannot re-enter `updateLayout` through the move delegate.
  private var isApplyingPanelFrame = false

  var currentPanel: NSWindow? {
    panel
  }

  func connect(model: LocalMeetingAppModel) {
    CepessaSessionFloatingBarPreferences.installDefaults()
    state.isCompact = UserDefaults.standard.bool(forKey: Constants.compactKey)

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
    levelCancellables.removeAll()
    liveSessionSnapshot = nil
    liveSessionID = nil
    noticeDismissTask?.cancel()
    state.noticeMessage = nil
    state.isVisible = false
    panel?.orderOut(nil)
  }

  // MARK: - Capture

  func startRecording() {
    guard
      CepessaSessionCaptureControlPolicy.resolve(
        CepessaSessionsStore.shared.captureLifecycle.phase) == .startSession
    else { return }
    model?.toggleRecording()
  }

  func stopRecording() {
    guard
      CepessaSessionCaptureControlPolicy.resolve(
        CepessaSessionsStore.shared.captureLifecycle.phase
      ).allowsStoppingSession
    else { return }
    model?.toggleRecording()
  }

  func toggleSessionRecording() {
    switch CepessaSessionCaptureControlPolicy.resolve(
      CepessaSessionsStore.shared.captureLifecycle.phase)
    {
    case .startSession, .cancelSessionStart, .stopSession:
      model?.toggleRecording()
    case .unavailable:
      return
    }
  }

  func toggleMicrophoneMute() {
    model?.toggleMicrophoneMute()
  }

  /// The orb's one click. What it does follows what the capsule is showing:
  /// record at rest, fold the controls while recording, open the session
  /// that is being transcribed or needs a look.
  func activateOrb() {
    switch state.phase {
    case .idle:
      startRecording()
    case .recording:
      setCompact(!state.isCompact)
    case .processing, .attention:
      if let session = activeSession() ?? model?.selectedSession {
        CepessaSessionsWindowController.shared.showSession(id: session.id)
      } else {
        CepessaSessionsWindowController.shared.showLibrary()
      }
    case .preparing:
      return
    }
  }

  func setCompact(_ isCompact: Bool) {
    guard state.isCompact != isCompact else { return }
    state.isCompact = isCompact
    UserDefaults.standard.set(isCompact, forKey: Constants.compactKey)
    updateLayout(animated: true)
  }

  // MARK: - Visibility

  /// Re-shows the capsule after the owner hid it.
  func showBar() {
    state.interaction.show()
    UserDefaults.standard.set(true, forKey: Constants.enabledKey)
    syncVisibility()
  }

  var isBarVisible: Bool {
    state.isVisible
  }

  /// True when the owner hid the capsule while capture is still live. The
  /// status item surfaces the way back.
  var isHiddenDuringRecording: Bool {
    state.interaction.isHiddenForCurrentRecording && state.isRecording
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

  /// Pointer proximity changes lighting only — never geometry.
  func setHoveringBar(_ isHovering: Bool) {
    guard state.interaction.isHovered != isHovering else { return }
    state.interaction.hoverChanged(isHovering)
  }

  // MARK: - Menus

  /// The ⋯ menu: capture that is not one click, recent sessions, and the way
  /// to everything else. Clicking ⋯ again closes it.
  func showBarMenu() {
    guard let anchor = capsuleScreenRect else { return }
    let menu = CepessaSessionCapsuleMenuController.shared
    if menu.isOpen || menu.wasJustClosedByClick {
      menu.close()
      return
    }
    menu.open(items: captureItems() + navigationItems(), below: anchor)
  }

  /// Right-click anywhere on the capsule. Stop stays one deliberate gesture
  /// away even when the controls are folded.
  func showCapsuleContextMenu() {
    guard let anchor = capsuleScreenRect else { return }
    var items: [CepessaSessionCapsuleMenuItem] = []

    switch CepessaSessionCaptureControlPolicy.resolve(state.capturePhase) {
    case .cancelSessionStart, .stopSession:
      items.append(.action(state.sessionTransportTitle, symbol: "stop.fill") { [weak self] in
        self?.stopRecording()
      })
      if state.isRecording {
        items.append(
          .action(
            state.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone",
            symbol: state.isMicrophoneMuted ? "mic.fill" : "mic.slash.fill"
          ) { [weak self] in self?.toggleMicrophoneMute() })
        items.append(
          .action(
            state.isCompact ? "Show Controls" : "Fold Controls",
            symbol: state.isCompact ? "arrow.left.and.right" : "arrow.right.and.line.vertical.and.arrow.left"
          ) { [weak self] in
            guard let self else { return }
            self.setCompact(!self.state.isCompact)
          })
      }
    case .unavailable:
      items.append(.action(state.sessionTransportTitle, symbol: "hourglass", isEnabled: false) {})
    case .startSession:
      items.append(.action("Start Recording", symbol: "record.circle") { [weak self] in
        self?.startRecording()
      })
    }
    items.append(.separator)
    CepessaSessionCapsuleMenuController.shared.open(
      items: items + captureItems() + navigationItems(), below: anchor)
  }

  private func captureItems() -> [CepessaSessionCapsuleMenuItem] {
    guard state.isRecording else { return [] }
    var items: [CepessaSessionCapsuleMenuItem] = [.header("Pin to this moment")]
    let screens = NSScreen.screens
    if screens.count > 1 {
      for (index, screen) in screens.enumerated() {
        items.append(.action("Capture \(screen.localizedName)", symbol: "display") { [weak self] in
          Task { @MainActor in await self?.captureScreenshot(interactive: false, display: index + 1) }
        })
      }
    } else {
      items.append(.action("Capture Whole Screen", symbol: "display") { [weak self] in
        Task { @MainActor in await self?.captureScreenshot(interactive: false, display: nil) }
      })
    }
    items.append(.action("Attach File…", symbol: "paperclip") { [weak self] in
      self?.importDocument()
    })
    items.append(.separator)
    return items
  }

  private func navigationItems() -> [CepessaSessionCapsuleMenuItem] {
    var items: [CepessaSessionCapsuleMenuItem] = []
    let sessions = Array((model?.sessions ?? []).prefix(5))
    if !sessions.isEmpty {
      items.append(.header("Recent"))
      for session in sessions {
        items.append(
          .action(
            session.displayTitle,
            detail: session.startedAt.formatted(date: .omitted, time: .shortened)
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
    items.append(.action("Settings…", symbol: "gearshape", detail: "⌘,") {
      CepessaSessionsWindowController.shared.openSettings()
    })
    items.append(.action("Hide Recorder", symbol: "eye.slash") { [weak self] in
      self?.dismissForCurrentRecording()
    })
    items.append(.action("Quit Cepessa Sessions", symbol: "power") {
      NSApp.terminate(nil)
    })
    return items
  }

  /// The capsule itself, in screen coordinates: where menus hang from.
  private var capsuleScreenRect: NSRect? {
    guard let panel else { return nil }
    let content = CepessaSessionCapsuleMetrics.contentRect(
      contentSize: state.barContentSize, inPanelOfSize: panel.frame.size)
    return NSRect(
      x: panel.frame.minX + content.minX, y: panel.frame.minY + content.minY,
      width: content.width, height: content.height)
  }

  // MARK: - Capture and attachments

  func captureRegionScreenshot() {
    Task { @MainActor in
      await captureScreenshot(interactive: true, display: nil)
    }
  }

  func importDocument() {
    guard let session = activeSession(), session.status == .recording else {
      presentNotice("Start recording before attaching files.", style: .warning)
      return
    }

    let openPanel = NSOpenPanel()
    openPanel.canChooseFiles = true
    openPanel.canChooseDirectories = false
    openPanel.allowsMultipleSelection = true
    openPanel.resolvesAliases = true
    openPanel.prompt = "Attach"
    openPanel.message = "Attach files to this moment of the recording."

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
          self.presentNotice(
            importedCount == 1
              ? "File pinned at \(self.state.compactTimerText)"
              : "\(importedCount) files pinned at \(self.state.compactTimerText)",
            style: .success
          )
        } else if lastError != nil {
          self.presentNotice("The file could not be attached", style: .error)
        }
      }
    }
  }

  /// Only an owner's drag reaches here as a real move. The controller's own
  /// resizes also fire this delegate; letting them re-enter `updateLayout`
  /// would cancel the settle that was about to run and kill the morph.
  func windowDidMove(_ notification: Notification) {
    guard panel != nil, !isApplyingPanelFrame, !isTransitioning else { return }
    updateLayout(animated: false)
  }

  // MARK: - Binding

  private func bind(to model: LocalMeetingAppModel) {
    cancellables.removeAll()

    // `@Published` re-publishes on every assignment, not only on change.
    model.$isRecording
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isRecording in
        guard let self else { return }
        if isRecording {
          self.state.interaction.recordingDidStart()
          self.bindLevels(to: model)
        } else {
          self.state.interaction.recordingDidEnd()
          self.levelCancellables.removeAll()
          self.state.micLevel = 0
          self.state.systemLevel = 0
        }
        self.refreshState()
        self.syncVisibility()
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
      .sink { [weak self] value in self?.state.isMicrophoneCaptureActive = value }
      .store(in: &cancellables)

    model.$isMicrophoneMuted
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in self?.state.isMicrophoneMuted = value }
      .store(in: &cancellables)

    model.$isSystemAudioCaptureActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in self?.state.isSystemAudioCaptureActive = value }
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
        self?.reconcileLiveSessionSnapshot()
      }
      .store(in: &cancellables)

    model.$sessions
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.reconcileLiveSessionSnapshot()
      }
      .store(in: &cancellables)

    model.$recorderErrorMessage
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.errorMessage = value
        self?.updateLayout(animated: true)
      }
      .store(in: &cancellables)

    model.$processingStatusTitle
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in self?.state.processingStage = value }
      .store(in: &cancellables)

    model.$processingProgress
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in self?.state.processingProgress = value }
      .store(in: &cancellables)

    CepessaSessionsStore.shared.captureLifecycle.$phase
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshState()
        self?.syncVisibility()
      }
      .store(in: &cancellables)
  }

  /// Levels move ~12 times a second; they only matter while recording, so the
  /// capsule only listens then.
  private func bindLevels(to model: LocalMeetingAppModel) {
    levelCancellables.removeAll()
    model.$micLevel
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in self?.state.micLevel = value }
      .store(in: &levelCancellables)
    model.$systemLevel
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in self?.state.systemLevel = value }
      .store(in: &levelCancellables)
  }

  private func refreshState() {
    guard let model else { return }

    state.isRecording = model.isRecording
    state.isTranscribing = model.isTranscribing
    state.capturePhase = CepessaSessionsStore.shared.captureLifecycle.phase
    state.isMicrophoneCaptureActive = model.isMicrophoneCaptureActive
    state.isMicrophoneMuted = model.isMicrophoneMuted
    state.isSystemAudioCaptureActive = model.isSystemAudioCaptureActive
    state.timerText = model.recordingDurationText
    state.errorMessage = model.recorderErrorMessage
    state.processingStage = model.processingStatusTitle
    state.processingProgress = model.processingProgress

    updateLayout(animated: true)
  }

  // MARK: - Panel

  private func ensurePanel() {
    guard panel == nil else { return }

    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: panelSize(for: state.panelContentSize)),
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
      rootView: CepessaSessionCapsuleView(controller: self, state: state))

    let container = CepessaFloatingPanelContainerView()
    container.wantsLayer = true
    hostingView.frame = container.bounds
    hostingView.autoresizingMask = [.width, .height]
    container.addSubview(hostingView)

    panel.contentView = container
    refreshLayoutMetrics()

    let anchor = restoredAnchor() ?? defaultAnchor()
    var frame = CepessaSessionCapsuleMetrics.panelFrame(
      anchor: anchor, contentSize: state.panelContentSize)
    frame.origin = clampedOrigin(for: frame)
    panel.setFrame(frame, display: false)

    self.panel = panel
    self.hostingView = hostingView
    applyPanelSize()
  }

  /// The saved anchor, migrating the former indicator's position once so an
  /// existing install finds the recorder where it left it.
  private func restoredAnchor() -> NSPoint? {
    let defaults = UserDefaults.standard
    if let saved = defaults.string(forKey: Constants.anchorKey) {
      return NSPointFromString(saved)
    }
    guard let legacy = defaults.string(forKey: Constants.legacyContentOriginKey) else {
      return nil
    }
    let migrated = CepessaSessionCapsuleMetrics.migratedAnchor(
      fromLegacyContentOrigin: NSPointFromString(legacy))
    defaults.set(NSStringFromPoint(migrated), forKey: Constants.anchorKey)
    return migrated
  }

  private func defaultAnchor() -> NSPoint {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
    let frame = screen.visibleFrame
    return NSPoint(x: frame.midX, y: frame.maxY - Constants.defaultTopInset)
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

  private func panelSize(for contentSize: CGSize) -> NSSize {
    CepessaSessionCapsuleMetrics.panelSize(for: contentSize, bleed: Constants.panelBleed)
  }

  private var currentBarContentSize: CGSize {
    let availableWidth =
      (panel.flatMap { screen(for: $0.frame) } ?? NSScreen.main ?? NSScreen.screens.first)?
      .visibleFrame.width
    return CepessaSessionCapsuleMetrics.contentSize(
      for: state.layout, availableScreenWidth: availableWidth)
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

  /// Grow the panel, morph the capsule, settle the panel.
  ///
  /// The order is the whole trick. If the panel resized in step with the
  /// shape, the glass would be clipped for the entire animation; if it never
  /// resized, the resting capsule could not be parked near a screen edge.
  /// Taking the union up front and giving it back at the end buys both. The
  /// shrink is driven by SwiftUI's completion rather than a timer, because a
  /// spring settles well after its `response`.
  private func updateLayout(animated: Bool) {
    let target = currentBarContentSize

    // A redundant publish must not cancel, restart, or short-circuit a morph
    // already on its way to the same footprint.
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
    state.panelContentSize = CepessaSessionCapsuleTransition.panelContentSize(
      from: current, to: target)
    applyPanelSize()

    withAnimation(SessionsMotion.capsule) {
      state.barContentSize = target
    } completion: { [weak self] in
      self?.settleLayout(ifToken: token)
    }

    // Watchdog: the panel must never be stranded on the union footprint if
    // the completion is lost.
    let settle = DispatchWorkItem { [weak self] in
      self?.settleLayout(ifToken: token)
    }
    settleTask = settle
    DispatchQueue.main.asyncAfter(
      deadline: .now() + SessionsMotion.capsuleSettleTimeout, execute: settle)
  }

  private func settleLayout(ifToken token: Int) {
    guard token == transitionToken else { return }
    settleLayout()
  }

  /// Lands the panel on the footprint the current state wants. Idempotent and
  /// self-invalidating: any completion still in flight for an earlier morph
  /// is ignored.
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

    hostingView?.needsDisplay = true
    panel?.invalidateShadow()
  }

  private func applyPanelSize() {
    guard let panel else { return }
    let targetSize = panelSize(for: state.panelContentSize)

    guard panel.frame.size != targetSize else {
      updateInteractiveRect()
      return
    }

    // Grow and shrink around the anchor — horizontal centre, top edge — so the
    // capsule stays where the owner put it.
    let anchor = CepessaSessionCapsuleMetrics.anchor(
      ofPanelFrame: panel.frame, bleed: Constants.panelBleed)
    var nextFrame = CepessaSessionCapsuleMetrics.panelFrame(
      anchor: anchor, contentSize: state.panelContentSize, bleed: Constants.panelBleed)
    nextFrame.origin = clampedOrigin(for: nextFrame)

    // The panel adopts each footprint atomically; SwiftUI owns the motion.
    isApplyingPanelFrame = true
    panel.setFrame(nextFrame, display: true)
    isApplyingPanelFrame = false
    updateInteractiveRect()
  }

  /// Teaches the panel which part of itself is the capsule.
  private func updateInteractiveRect() {
    guard let container = panel?.contentView as? CepessaFloatingPanelContainerView else { return }
    container.interactiveRect = CepessaSessionCapsuleTransition.interactiveRect(
      contentSize: state.barContentSize,
      panelContentSize: state.panelContentSize,
      panelSize: panelSize(for: state.panelContentSize),
      isTransitioning: isTransitioning
    )
  }

  fileprivate func beginPanelDrag(with event: NSEvent) {
    guard let panel else { return }
    panel.performDrag(with: event)

    var frame = panel.frame
    frame.origin = clampedOrigin(for: frame)
    if frame.origin != panel.frame.origin {
      isApplyingPanelFrame = true
      panel.setFrameOrigin(frame.origin)
      isApplyingPanelFrame = false
    }
    let anchor = CepessaSessionCapsuleMetrics.anchor(
      ofPanelFrame: frame, bleed: Constants.panelBleed)
    UserDefaults.standard.set(NSStringFromPoint(anchor), forKey: Constants.anchorKey)
    updateInteractiveRect()
  }

  // MARK: - Session helpers

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
      presentNotice("Start recording before capturing the screen.", style: .warning)
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
      presentNotice(
        interactive
          ? "Region pinned at \(state.compactTimerText)"
          : "Screen pinned at \(state.compactTimerText)",
        style: .success
      )
    } catch is CancellationError {
      return
    } catch {
      presentNotice(
        interactive ? "Region capture failed" : "Screen capture failed", style: .error)
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
    let fileLayout = LocalMeetingFileLayout(baseDirectory: LocalSessionStorageRoot.defaultBaseDirectory)
    try fileLayout.ensureDirectories(for: sessionID)
    let attachmentsDirectory = fileLayout.attachmentsDirectory(for: sessionID)

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

  private func clampedOrigin(for frame: NSRect) -> NSPoint {
    guard let screen = screen(for: frame) ?? NSScreen.main ?? NSScreen.screens.first else {
      return frame.origin
    }
    // The bleed may hang past the screen edge; the capsule itself may not.
    let visible = screen.visibleFrame.insetBy(
      dx: -Constants.panelBleed, dy: -Constants.panelBleed)
    var origin = frame.origin
    origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
    origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
    return origin
  }

  private func screen(for frame: NSRect) -> NSScreen? {
    NSScreen.screens.first { NSIntersectionRect($0.visibleFrame, frame).isEmpty == false }
  }

  /// A short confirmation or problem, read in full in the capsule for a
  /// couple of seconds, then gone.
  func presentNotice(_ text: String, style: CepessaSessionFloatingBarState.NoticeStyle) {
    noticeDismissTask?.cancel()
    state.noticeMessage = text
    state.noticeStyle = style
    updateLayout(animated: true)

    noticeDismissTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 2_600_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.dismissNotice()
      }
    }
  }

  func dismissNotice() {
    noticeDismissTask?.cancel()
    guard state.noticeMessage != nil else { return }
    state.noticeMessage = nil
    state.noticeStyle = .neutral
    updateLayout(animated: true)
  }

  private enum FloatingBarError: LocalizedError {
    case noModel
    case noSession

    var errorDescription: String? {
      switch self {
      case .noModel: return "The live session store is unavailable."
      case .noSession: return "The live session could not be found."
      }
    }
  }
}

// MARK: - View

struct CepessaSessionCapsuleView: View {
  let controller: CepessaSessionFloatingBarController
  @ObservedObject var state: CepessaSessionFloatingBarState

  var body: some View {
    SessionCapsule(controller: controller, state: state)
      // The panel carries transparent bleed around the capsule; filling it and
      // centring is what keeps the glass off the window edge.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("cepessa.floatingBar")
  }
}

/// One object. The orb is the first child in every state, pinned to the
/// leading edge, so as the capsule grows the orb stays put and the controls
/// open out of it; that continuity is what makes the change read as one thing
/// opening rather than two things cross-fading.
private struct SessionCapsule: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let controller: CepessaSessionFloatingBarController
  @ObservedObject var state: CepessaSessionFloatingBarState

  private typealias M = CepessaSessionCapsuleMetrics

  var body: some View {
    let phase = state.phase
    HStack(spacing: 0) {
      SessionCapsuleOrb(controller: controller, state: state)
        .frame(width: M.orb, height: M.orb)

      Group {
        if state.hasNotice {
          SessionCapsuleNotice(state: state)
            .padding(.leading, M.gap)
            .transition(contentTransition)
        } else {
          switch phase {
          case .recording:
            SessionCapsuleLiveReadout(state: state)
              .padding(.leading, M.gap)
              .transition(contentTransition)
          case .preparing, .processing, .attention:
            SessionCapsuleStatus(state: state)
              .padding(.leading, M.gap)
              .transition(contentTransition)
          case .idle:
            EmptyView()
          }
        }
      }

      Spacer(minLength: 0)

      Group {
        if phase == .recording && !state.isCompact {
          SessionCapsuleLiveControls(controller: controller, state: state)
            .transition(contentTransition)
        } else if phase != .recording {
          SessionCapsuleMoreButton(controller: controller)
            .transition(contentTransition)
        }
      }
      // A collapsing capsule must not deliver the release to whichever
      // control slid under the pointer — Stop above all.
      .allowsHitTesting(CepessaSessionCapsuleTransition.acceptsClicks(isTransitioning: state.isTransitioning))
    }
    .padding(.horizontal, M.inset)
    // Leading alignment keeps the orb still while the capsule changes width.
    .frame(
      width: state.barContentSize.width,
      height: state.barContentSize.height,
      alignment: .leading
    )
    .background {
      // The capsule's body is draggable and answers right-click; its
      // controls sit above this and keep their own clicks.
      SessionCapsuleHitArea(
        cursor: .openHand,
        onClick: {},
        onSecondaryClick: controller.showCapsuleContextMenu,
        onHover: controller.setHoveringBar,
        onDrag: controller.beginPanelDrag
      )
      .accessibilityHidden(true)
    }
    .clipShape(Capsule())
    .sessionsNightGlass(
      in: Capsule(),
      glow: glow,
      glowStrength: glowStrength,
      isHighlighted: state.interaction.isHovered
    )
    .environment(\.colorScheme, .dark)
    .animation(motion, value: state.barContentSize)
    .animation(motion, value: phase)
    .animation(motion, value: state.isCompact)
    .animation(motion, value: state.hasNotice)
    .animation(reduceMotion ? nil : SessionsMotion.hover, value: state.interaction.isHovered)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Cepessa Sessions recorder")
    .accessibilityValue(
      CepessaSessionIndicatorAccessibility.capsuleValue(
        phase: phase,
        health: state.captureHealth,
        timerText: state.timerText,
        progress: state.processingProgress))
    .accessibilityIdentifier("cepessa.floatingBar.capsule")
  }

  private var motion: Animation? {
    reduceMotion ? nil : SessionsMotion.capsule
  }

  private var contentTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .opacity.combined(with: .modifier(
        active: CapsuleBlur(radius: 6), identity: CapsuleBlur(radius: 0)))
        .animation(SessionsMotion.capsuleContentIn),
      removal: .opacity.animation(SessionsMotion.capsuleContentOut)
    )
  }

  private var glow: Color? {
    switch state.phase {
    case .recording: return SessionsPalette.cloudCoral
    case .processing: return SessionsPalette.sunriseGold
    default: return nil
    }
  }

  private var glowStrength: Double {
    switch state.phase {
    case .recording:
      return state.isMicrophoneMuted ? 0.3 : 0.6 + 0.4 * min(1, max(state.micLevel, state.systemLevel) * 2)
    case .processing: return 0.45
    default: return 0
    }
  }
}

private struct CapsuleBlur: ViewModifier {
  let radius: CGFloat
  func body(content: Content) -> some View {
    content.blur(radius: radius)
  }
}

// MARK: Orb

private struct SessionCapsuleOrb: View {
  let controller: CepessaSessionFloatingBarController
  @ObservedObject var state: CepessaSessionFloatingBarState

  var body: some View {
    SessionsOrb(
      mood: state.orbMood,
      level: max(state.micLevel, state.systemLevel),
      diameter: 28,
      isHighlighted: state.interaction.isHovered
    )
    .frame(width: CepessaSessionCapsuleMetrics.orb, height: CepessaSessionCapsuleMetrics.orb)
    .overlay {
      SessionCapsuleHitArea(
        onClick: controller.activateOrb,
        onSecondaryClick: controller.showCapsuleContextMenu,
        onHover: controller.setHoveringBar,
        onDrag: controller.beginPanelDrag
      )
      .help(helpText)
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(
        CepessaSessionIndicatorAccessibility.orbLabel(
          phase: state.phase, isCompact: state.isCompact))
      .accessibilityAction { controller.activateOrb() }
      .accessibilityActions {
        if state.canActivateSessionTransport && state.phase != .idle {
          Button(state.sessionTransportTitle) { controller.toggleSessionRecording() }
        }
      }
      .accessibilityIdentifier(orbIdentifier)
    }
  }

  private var orbIdentifier: String {
    state.phase == .idle ? "cepessa.floatingBar.record" : "cepessa.floatingBar.orb"
  }

  private var helpText: String {
    switch state.phase {
    case .idle: return "Start recording. Drag to move."
    case .recording: return state.isCompact ? "Show controls" : "Fold controls"
    case .processing: return "Open the session being transcribed"
    case .attention: return state.errorMessage ?? "Open for details"
    case .preparing: return state.isStopping ? "Saving the recording…" : "Starting…"
    }
  }
}

// MARK: Readouts

/// The timer and the two measured levels: microphone, then system audio.
private struct SessionCapsuleLiveReadout: View {
  @ObservedObject var state: CepessaSessionFloatingBarState

  var body: some View {
    HStack(spacing: 8) {
      Text(state.compactTimerText)
        .font(SessionsType.figure(15, weight: .medium))
        .foregroundStyle(SessionsNight.ink)
        .lineLimit(1)
        .fixedSize()
        .contentTransition(.numericText())
        .frame(
          width: CepessaSessionIndicatorTimer.showsHours(state.timerText)
            ? CepessaSessionCapsuleMetrics.timerWithHours
            : CepessaSessionCapsuleMetrics.timer,
          alignment: .leading)
        .accessibilityLabel(
          "Recording duration "
            + CepessaSessionIndicatorAccessibility.compactSpokenTimer(state.timerText))
        .accessibilityIdentifier("cepessa.floatingBar.timer")

      HStack(spacing: 3) {
        SessionLevelBar(
          level: state.isMicrophoneMuted ? 0 : state.micLevel,
          isActive: state.isMicrophoneCaptureActive && !state.isMicrophoneMuted)
        SessionLevelBar(level: state.systemLevel, isActive: state.isSystemAudioCaptureActive)
      }
      .frame(width: CepessaSessionCapsuleMetrics.levels, height: 18)
      .help("Microphone · System audio")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(levelDescription)
    }
  }

  private var levelDescription: String {
    let mic =
      state.isMicrophoneMuted
      ? "Microphone muted"
      : state.isMicrophoneCaptureActive ? "Microphone active" : "Microphone not capturing"
    let system =
      state.isSystemAudioCaptureActive ? "system audio active" : "system audio not capturing"
    return "\(mic), \(system)"
  }
}

/// A level that is only ever what the recorder measured. A source that is not
/// capturing shows an empty, dimmed track — never a fake flicker.
private struct SessionLevelBar: View {
  let level: Double
  let isActive: Bool

  var body: some View {
    GeometryReader { proxy in
      let height = proxy.size.height
      let fill = isActive ? max(0.12, min(1, sqrt(max(level, 0)) * 1.3)) : 0
      ZStack(alignment: .bottom) {
        Capsule().fill(SessionsNight.ink.opacity(isActive ? 0.16 : 0.08))
        Capsule()
          .fill(
            LinearGradient(
              colors: [SessionsPalette.sunriseGold, SessionsPalette.lightCore],
              startPoint: .bottom, endPoint: .top)
          )
          .frame(height: height * fill)
      }
    }
    .frame(width: 3)
    .animation(.easeOut(duration: 0.12), value: level)
  }
}

private struct SessionCapsuleStatus: View {
  @ObservedObject var state: CepessaSessionFloatingBarState

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(
        CepessaSessionCapsuleStatus.title(
          phase: state.phase, isStopping: state.isStopping))
        .font(SessionsType.text(12.5, weight: .semibold))
        .foregroundStyle(SessionsNight.ink)
      if let detail = CepessaSessionCapsuleStatus.detail(
        phase: state.phase, progress: state.processingProgress, stage: state.processingStage)
      {
        Text(detail)
          .font(SessionsType.text(11, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(SessionsNight.inkSecondary)
      }
    }
    .lineLimit(1)
    .truncationMode(.tail)
    .frame(width: CepessaSessionCapsuleMetrics.statusColumn, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("cepessa.floatingBar.status")
  }
}

private struct SessionCapsuleNotice: View {
  @ObservedObject var state: CepessaSessionFloatingBarState

  var body: some View {
    HStack(spacing: 6) {
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(tint)
          .accessibilityHidden(true)
      }
      Text(state.noticeMessage ?? "")
        .font(SessionsType.text(12.5, weight: .medium))
        .foregroundStyle(SessionsNight.ink)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .frame(width: CepessaSessionCapsuleMetrics.notice, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.updatesFrequently)
    .accessibilityIdentifier("cepessa.floatingBar.notice")
  }

  private var symbol: String? {
    switch state.noticeStyle {
    case .success: return "pin.fill"
    case .warning, .error: return "exclamationmark.triangle.fill"
    case .neutral: return nil
    }
  }

  private var tint: Color {
    switch state.noticeStyle {
    case .success: return SessionsPalette.sunriseGold
    case .warning, .error: return SessionsPalette.attention
    case .neutral: return SessionsNight.inkSecondary
    }
  }
}

// MARK: Controls

private struct SessionCapsuleLiveControls: View {
  let controller: CepessaSessionFloatingBarController
  @ObservedObject var state: CepessaSessionFloatingBarState

  private typealias M = CepessaSessionCapsuleMetrics

  var body: some View {
    HStack(spacing: M.controlSpacing) {
      Rectangle()
        .fill(SessionsNight.hairline)
        .frame(width: M.divider, height: 18)
        .padding(.trailing, M.gap - M.controlSpacing)
        .accessibilityHidden(true)

      SessionCapsuleIconButton(
        symbol: state.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
        title: state.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone",
        tint: state.isMicrophoneMuted ? SessionsPalette.attention : SessionsNight.ink,
        action: controller.toggleMicrophoneMute
      )
      .accessibilityIdentifier("cepessa.floatingBar.mute")

      SessionCapsuleIconButton(
        symbol: "viewfinder",
        title: "Capture a region of the screen",
        action: controller.captureRegionScreenshot
      )
      .accessibilityIdentifier("cepessa.floatingBar.captureRegion")

      SessionCapsuleStopButton(
        isEnabled: state.canActivateSessionTransport,
        title: state.sessionTransportTitle,
        action: controller.stopRecording
      )

      SessionCapsuleMoreButton(controller: controller)
    }
  }
}

private struct SessionCapsuleIconButton: View {
  let symbol: String
  let title: String
  var tint: Color = SessionsNight.ink
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: CepessaSessionCapsuleMetrics.control, height: CepessaSessionCapsuleMetrics.control)
        .background(Circle().fill(isHovered ? SessionsNight.controlHover : SessionsNight.controlFill))
        .contentShape(Circle())
    }
    .buttonStyle(SessionsPressStyle(scale: 0.92))
    .onHover { isHovered = $0 }
    .animation(SessionsMotion.hover, value: isHovered)
    .help(title)
    .accessibilityLabel(title)
  }
}

/// Stop: the one saturated control, always last among the live controls, so
/// it never moves and never hides behind a menu.
private struct SessionCapsuleStopButton: View {
  let isEnabled: Bool
  let title: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle().fill(SessionsPalette.recording.opacity(isHovered ? 1 : 0.9))
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
          .fill(Color.white)
          .frame(width: 10, height: 10)
      }
      .frame(width: CepessaSessionCapsuleMetrics.control, height: CepessaSessionCapsuleMetrics.control)
      .shadow(color: SessionsPalette.recording.opacity(isHovered ? 0.6 : 0.35), radius: isHovered ? 6 : 3)
      .contentShape(Circle())
    }
    .buttonStyle(SessionsPressStyle(scale: 0.9))
    .disabled(!isEnabled)
    .onHover { isHovered = $0 }
    .animation(SessionsMotion.hover, value: isHovered)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityHint("Ends capture and begins the transcript on this Mac.")
    .accessibilityIdentifier("cepessa.floatingBar.stop")
  }
}

private struct SessionCapsuleMoreButton: View {
  let controller: CepessaSessionFloatingBarController

  var body: some View {
    SessionCapsuleIconButton(
      symbol: "ellipsis",
      title: "Sessions menu",
      tint: SessionsNight.inkSecondary,
      action: controller.showBarMenu
    )
    .accessibilityIdentifier("cepessa.floatingBar.menu")
  }
}

// MARK: Hit testing

/// A target that serves click, right-click and drag without any of them
/// stealing the others. Past a few points of movement the gesture becomes a
/// window drag; otherwise it is a click on mouse-up.
private struct SessionCapsuleHitArea: NSViewRepresentable {
  var cursor: NSCursor = .pointingHand
  let onClick: () -> Void
  let onSecondaryClick: () -> Void
  let onHover: (Bool) -> Void
  let onDrag: (NSEvent) -> Void

  func makeNSView(context: Context) -> SessionIndicatorHitNSView {
    let view = SessionIndicatorHitNSView()
    view.cursor = cursor
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
  var cursor: NSCursor = .pointingHand

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

  /// The SwiftUI element above this view carries the accessibility element;
  /// the bare hit target must not appear as a second, unlabelled one.
  override func accessibilityIsIgnored() -> Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
    addCursorRect(bounds, cursor: cursor)
  }
}
