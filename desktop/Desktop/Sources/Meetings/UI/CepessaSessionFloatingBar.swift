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
    static let panelHorizontalPadding: CGFloat = 20
    static let compactBarHeight: CGFloat = 78
    static let expandedBarHeight: CGFloat = 152
    static let recordingPillHeight: CGFloat = 58
    static let queueRowHeight: CGFloat = 34
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
    Task { @MainActor in
      await captureScreenshot(interactive: false)
    }
  }

  func captureRegionScreenshot() {
    Task { @MainActor in
      await captureScreenshot(interactive: true)
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
        if !isRecording {
          self?.state.isDismissedForCurrentRecording = false
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

    model.$isGeneratingRecap
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
      }
      .store(in: &cancellables)

    model.$isMicrophoneCaptureActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.state.isMicrophoneCaptureActive = value
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
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
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
    state.isTranscribing = model.isTranscribing || model.isGeneratingRecap
    state.isMicrophoneCaptureActive = model.isMicrophoneCaptureActive
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
      if model.isGeneratingRecap(for: session.id) {
        state.statusMessage =
          model.processingStatusDetail ?? "Transcript is ready. The recap is still running locally."
      } else {
        switch session.status {
        case .recording:
          state.statusMessage =
            "Recording on this Mac. Add screenshots or files to pin context to this moment."
        case .transcribing:
          state.statusMessage =
            model.processingStatusDetail
            ?? "Finishing locally. Transcript and recap are being prepared."
        case .ready:
          state.statusMessage = "Session saved locally."
        case .failed:
          state.statusMessage = "Processing stopped. Open the session for details."
        }
      }
    } else if model.isTranscribing || model.isGeneratingRecap {
      state.title = model.processingStatusTitle ?? "Processing session"
      state.statusMessage =
        model.processingStatusDetail
        ?? "Finishing locally. Transcript and recap are still being prepared."
      if let lastSession = model.sessions.first(where: {
        $0.status == .transcribing || model.isGeneratingRecap(for: $0.id)
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

    updatePanelSize(animated: true)
  }

  private func syncVisibility() {
    guard let panel else { return }
    let shouldShow =
      isFloatingBarEnabled && state.isRecording && !state.isTranscribing
      && !state.isDismissedForCurrentRecording
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
    let baseHeight =
      (state.isAttachmentDeckExpanded && state.attachmentDeck.hasContent)
      ? Constants.expandedBarHeight
      : Constants.compactBarHeight
    let queueRows = max(0, min(2, state.processingQueue.count - 1))
    return NSSize(
      width: currentBarContentWidth + Constants.panelHorizontalPadding,
      height: baseHeight + (CGFloat(queueRows) * Constants.queueRowHeight))
  }

  private var currentBarContentWidth: CGFloat {
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

    var nextFrame = panel.frame
    let heightDelta = targetSize.height - panel.frame.height
    nextFrame.origin.y -= heightDelta
    nextFrame.size = targetSize

    if animated {
      panel.animator().setFrame(nextFrame, display: true)
    } else {
      panel.setFrame(nextFrame, display: true)
    }
    clamp(panel: panel)
  }

  private func activeSession() -> LocalSession? {
    if let selected = model?.selectedSession,
      selected.status == .recording || selected.status == .transcribing
        || model?.isGeneratingRecap(for: selected.id) == true
    {
      return selected
    }

    return model?.sessions.first(where: {
      $0.status == .recording || $0.status == .transcribing
        || model?.isGeneratingRecap(for: $0.id) == true
    })
  }

  private func captureScreenshot(interactive: Bool) async {
    guard let session = activeSession(), session.status == .recording else {
      showNotice("Start a live session before capturing screenshots.", style: .warning)
      return
    }

    do {
      let fileURL = try screenshotTargetURL(
        for: session.id, prefix: interactive ? "region" : "screen")
      try await runScreencapture(to: fileURL, interactive: interactive)
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

  private func runScreencapture(to destinationURL: URL, interactive: Bool) async throws {
    let executable =
      FileManager.default.fileExists(atPath: "/usr/sbin/screencapture")
      ? "/usr/sbin/screencapture"
      : "/usr/bin/screencapture"

    try await withCheckedThrowingContinuation { continuation in
      let task = Process()
      task.executableURL = URL(fileURLWithPath: executable)
      task.arguments =
        interactive
        ? ["-i", "-x", destinationURL.path]
        : ["-x", destinationURL.path]

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
    guard let screen = screen(for: panel.frame) ?? NSScreen.main ?? NSScreen.screens.first else {
      return
    }
    let frame = screen.visibleFrame
    var origin = panel.frame.origin
    origin.x = min(max(origin.x, frame.minX), frame.maxX - panel.frame.width)
    origin.y = min(max(origin.y, frame.minY), frame.maxY - panel.frame.height)
    panel.setFrameOrigin(origin)
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
      if state.attachmentDeck.hasContent {
        HStack(alignment: .bottom, spacing: 10) {
          if state.isAttachmentDeckExpanded {
            SessionFloatingAttachmentDeckView(deck: state.attachmentDeck)
              .transition(.move(edge: .top).combined(with: .opacity))
          } else {
            SessionFloatingCollapsedAttachmentPill(deck: state.attachmentDeck)
              .transition(.scale(scale: 0.98).combined(with: .opacity))
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

      recordingPill
    }
    .frame(
      width: state.barContentWidth
        + CepessaSessionFloatingBarController.Constants.panelHorizontalPadding
    )
    .padding(.vertical, 10)
    .background(Color.clear)
    .animation(barAnimation, value: state.noticeMessage)
    .animation(barAnimation, value: state.errorMessage)
    .animation(barAnimation, value: state.isRecording)
    .animation(barAnimation, value: state.isTranscribing)
    .animation(barAnimation, value: state.attachmentDeck)
    .animation(barAnimation, value: state.isAttachmentDeckExpanded)
  }

  private var recordingPill: some View {
    recordingPillContent
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(
        width: state.barContentWidth,
        height: CepessaSessionFloatingBarController.Constants.recordingPillHeight
      )
      .cepessaFloatingToolbarSurface()
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Floating recording controls")
      .accessibilityHint("Drag the waveform area to move the recording bar.")
  }

  private var recordingPillContent: some View {
    HStack(alignment: .center, spacing: 7) {
      SessionFloatingToolbarIconButton(
        icon: "xmark",
        title: "Hide floating recording bar",
        isDisabled: false,
        action: controller.dismissForCurrentRecording
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
        micLevel: state.micLevel,
        systemLevel: state.systemLevel,
        accent: waveformAccent
      )
      .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 42)

      SessionFloatingTimerPill(timerText: state.timerText)

      SessionFloatingStopButton(action: controller.stopRecording)
    }
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
    return state.noticeStyle == .error ? CepessaColors.warning : CepessaColors.textPrimary
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
        .fill(CepessaColors.backgroundSecondary.opacity(0.92))
        .overlay(
          Capsule()
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    )
    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 5)
  }

  private var summaryText: String {
    let count = deck.previews.count + deck.overflowCount
    return count == 1 ? "1 capture hidden" : "\(count) captures hidden"
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

private struct SessionFloatingLiveToken: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let accent: Color
  let isRecording: Bool
  let isTranscribing: Bool
  let timerText: String

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(accent)
        .frame(width: 8, height: 8)
      Text(timerText)
        .scaledFont(size: 11, weight: .semibold)
        .monospacedDigit()
        .foregroundStyle(CepessaColors.textPrimary)
      if isTranscribing {
        Text("Processing")
          .scaledFont(size: 10, weight: .medium)
          .foregroundStyle(CepessaColors.textTertiary)
      } else if isRecording {
        Text("Live")
          .scaledFont(size: 10, weight: .medium)
          .foregroundStyle(CepessaColors.textTertiary)
      }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 8)
    .background(CepessaColors.backgroundRaised.opacity(0.72))
    .clipShape(Capsule())
    .animation(
      reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: timerText)
  }
}

private struct SessionFloatingSignalIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let icon: String
  let label: String
  let value: Double
  let accent: Color

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: icon)
        .scaledFont(size: 10, weight: .semibold)
        .foregroundStyle(CepessaColors.textTertiary)

      VStack(alignment: .leading, spacing: 3) {
        Text(label)
          .scaledFont(size: 9.5, weight: .medium)
          .foregroundStyle(CepessaColors.textTertiary)

        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Capsule()
              .fill(CepessaColors.backgroundRaised.opacity(0.7))

            Capsule()
              .fill(accent.opacity(0.9))
              .frame(width: max(8, proxy.size.width * min(max(value, 0), 1)))
          }
        }
        .frame(width: 42, height: 5)
        .animation(
          reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: value)
      }

      Circle()
        .fill(accent)
        .frame(width: 6, height: 6)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(CepessaColors.backgroundRaised.opacity(0.62))
    .clipShape(Capsule())
  }
}

private struct SessionFloatingProcessingLane: View {
  let title: String
  let detail: String?
  let progress: Double?

  var body: some View {
    HStack(spacing: 10) {
      ProgressView(value: progress)
        .progressViewStyle(.linear)
        .frame(width: 84)
        .tint(CepessaColors.purplePrimary)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .scaledFont(size: 11, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)
        if let detail, !detail.isEmpty {
          Text(detail)
            .scaledFont(size: 10)
            .foregroundStyle(CepessaColors.textTertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(CepessaColors.backgroundRaised.opacity(0.66))
    .clipShape(Capsule())
  }
}

private struct SessionFloatingQueueRow: View {
  let item: CepessaSessionFloatingProcessingItem

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(item.sessionTitle)
          .scaledFont(size: 10.5, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)
          .lineLimit(1)

        Text(item.stageTitle)
          .scaledFont(size: 9.5, weight: .medium)
          .foregroundStyle(CepessaColors.textTertiary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      Text(item.phaseLabel)
        .scaledFont(size: 9.5, weight: .semibold)
        .foregroundStyle(CepessaColors.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(CepessaColors.backgroundRaised.opacity(0.58))
        .clipShape(Capsule())

      if let progress = item.progress {
        ProgressView(value: progress)
          .progressViewStyle(.linear)
          .frame(width: 54)
          .tint(CepessaColors.purplePrimary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(CepessaColors.backgroundRaised.opacity(0.54))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

private struct SessionFloatingToolbarIconButton: View {
  let icon: String
  let title: String
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .scaledFont(size: 12.5, weight: .medium)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(CepessaPressStyle(scale: 0.965, pressedBrightness: -0.02))
    .disabled(isDisabled)
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
        .background(CepessaColors.error.opacity(0.92), in: Capsule())
    }
    .buttonStyle(CepessaPressStyle(scale: 0.965, pressedBrightness: -0.02))
    .help("Stop the current recording session")
    .accessibilityLabel("Stop recording")
  }
}

private struct SessionFloatingWaveformDragRegion: View {
  let micLevel: Double
  let systemLevel: Double
  let accent: Color

  var body: some View {
    ZStack {
      SessionFloatingDragHandleView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      SessionFloatingAudioWaveform(
        micLevel: micLevel,
        systemLevel: systemLevel,
        accent: accent
      )
      .allowsHitTesting(false)
    }
    .contentShape(Capsule())
    .accessibilityLabel("Move floating recording bar")
    .accessibilityHint("Drag to reposition the recording controls.")
  }
}

private struct SessionFloatingAudioWaveform: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let micLevel: Double
  let systemLevel: Double
  let accent: Color

  private let pattern: [CGFloat] = [
    0.22, 0.52, 0.26, 0.62, 0.34, 0.74, 0.30, 0.42, 0.25, 0.54, 0.36, 0.92, 0.28,
    0.50, 0.24, 0.66, 0.32, 0.46, 0.24, 0.58, 0.38, 0.82, 0.30, 0.48, 0.26, 0.64,
    0.34, 0.56, 0.24, 0.44, 0.30, 0.78,
  ]

  var body: some View {
    HStack(alignment: .center, spacing: 6) {
      ForEach(pattern.indices, id: \.self) { index in
        Capsule()
          .fill(barColor(at: index))
          .frame(width: barWidth(at: index), height: barHeight(at: index))
      }
    }
    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
    .animation(
      reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.16),
      value: micLevel + systemLevel
    )
  }

  private var liveLevel: CGFloat {
    CGFloat(min(max(max(micLevel, systemLevel), 0), 1))
  }

  private func barHeight(at index: Int) -> CGFloat {
    let lift = 0.82 + (liveLevel * 0.34)
    let pulse = index.isMultiple(of: 11) ? 1.20 : 1
    return max(6, pattern[index] * 32 * lift * pulse)
  }

  private func barWidth(at index: Int) -> CGFloat {
    index.isMultiple(of: 11) ? 5 : 4
  }

  private func barColor(at index: Int) -> Color {
    let emphasis = index.isMultiple(of: 11) || index.isMultiple(of: 5)
    return accent.opacity(emphasis ? 0.78 : 0.46)
  }
}

private struct SessionFloatingActionCluster: View {
  let isDisabled: Bool
  let captureScreen: () -> Void
  let captureRegion: () -> Void
  let importFile: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      SessionFloatingActionButton(
        icon: "camera", title: "Capture screen", isDisabled: isDisabled, action: captureScreen)
      SessionFloatingActionButton(
        icon: "viewfinder", title: "Capture region", isDisabled: isDisabled, action: captureRegion)
      SessionFloatingActionButton(
        icon: "doc.badge.plus", title: "Attach file", isDisabled: isDisabled, action: importFile)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(CepessaColors.backgroundRaised.opacity(0.54))
    .clipShape(Capsule())
  }
}

private struct SessionFloatingActionButton: View {
  let icon: String
  let title: String
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .scaledFont(size: 11, weight: .semibold)
        .foregroundStyle(isDisabled ? CepessaColors.textTertiary : CepessaColors.textPrimary)
        .frame(width: 30, height: 30)
        .background(CepessaColors.backgroundSecondary.opacity(isDisabled ? 0.4 : 0.74))
        .clipShape(Circle())
    }
    .buttonStyle(SessionFloatingPressStyle())
    .disabled(isDisabled)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityHint(
      isDisabled ? "Start a session before using capture tools." : "Runs this capture action.")
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

private struct SessionFloatingDragHandle: View {
  var body: some View {
    ZStack {
      SessionFloatingDragHandleView()
        .frame(width: 30, height: 30)

      Image(systemName: "line.3.horizontal")
        .scaledFont(size: 10, weight: .semibold)
        .foregroundStyle(CepessaColors.textSecondary)
        .allowsHitTesting(false)
    }
    .background(CepessaColors.backgroundRaised.opacity(0.74))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.white.opacity(0.08), lineWidth: 1)
    )
    .accessibilityLabel("Move floating capture bar")
    .accessibilityHint("Drag to reposition the recording controls.")
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
