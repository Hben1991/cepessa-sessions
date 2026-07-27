import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The on-demand session window is a pure reading surface: nothing but the
/// transcript text in a centered column. Every control (which session, the
/// document language, export, transcribe) lives in the native window toolbar,
/// so the content area stays clean. Opened from the floating bar's menu.
struct CepessaSessionReadingView: View {
  @ObservedObject private var model = CepessaSessionsStore.shared.model

  /// Reading-only text zoom (⌘+ / ⌘- / ⌘0 or trackpad pinch).
  @AppStorage("cepessa.reading.textScale") private var textScale: Double = 1.0
  @GestureState private var pinch: CGFloat = 1
  @State private var enlargedImage: NSImage?
  @State private var renameTarget: LocalSessionTranscriptSegment?
  @State private var proposedSpeakerName = ""

  private let inlineImageMaxHeight: CGFloat = 320

  /// Base column width at 1× zoom. Grows with the zoom factor so the number of
  /// words per line stays roughly constant as the reader zooms in.
  private let baseColumnWidth: CGFloat = 620
  private let minScale = 0.7
  private let maxScale = 2.2

  private var zoom: CGFloat { CGFloat(textScale) * pinch }

  private func sz(_ base: CGFloat) -> CGFloat {
    round(base * zoom)
  }

  private func columnWidth(available: CGFloat) -> CGFloat {
    min(baseColumnWidth * zoom, max(320, available - 64))
  }

  var body: some View {
    Group {
      if let session = model.selectedSession {
        content(for: session)
      } else {
        emptyState(
          title: "No Session Open",
          message: "Choose a session from the toolbar to read its transcript.",
          symbol: "rectangle.stack"
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Long-form text always sits on an opaque reading surface — never glass.
    .background(CepessaColors.readingSurface)
    .gesture(
      MagnifyGesture()
        .updating($pinch) { value, state, _ in
          state = value.magnification
        }
        .onEnded { value in
          setScale(textScale * Double(value.magnification))
        }
    )
    .background(zoomShortcuts)
    .overlay {
      if let enlargedImage {
        enlargedOverlay(enlargedImage)
      }
    }
    .alert(
      "Rename speaker",
      isPresented: Binding(
        get: { renameTarget != nil },
        set: { if !$0 { renameTarget = nil } }
      ),
      presenting: renameTarget
    ) { segment in
      TextField("Speaker name", text: $proposedSpeakerName)
      Button("Cancel", role: .cancel) {
        renameTarget = nil
      }
      Button("Save") {
        if let speakerID = segment.speakerID {
          _ = model.renameSpeaker(speakerID: speakerID, to: proposedSpeakerName)
        }
        renameTarget = nil
      }
      .disabled(proposedSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: { _ in
      Text("This adds a local correction without changing the original transcript evidence.")
    }
  }

  /// Image lightbox. The scrim is a system material so it follows appearance
  /// and Reduce Transparency instead of a fixed black wash, and the dismiss
  /// control is the standard hierarchical close glyph.
  private func enlargedOverlay(_ image: NSImage) -> some View {
    ZStack {
      Rectangle()
        .fill(.regularMaterial)
        .ignoresSafeArea()

      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .padding(CepessaChrome.Space.xxl)

      VStack {
        HStack {
          Spacer()
          Button {
            enlargedImage = nil
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 20))
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Close image")
          .padding(CepessaChrome.Space.l)
        }
        Spacer()
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { enlargedImage = nil }
    .transition(.opacity)
  }

  @ViewBuilder
  private func content(for session: LocalSession) -> some View {
    let items = session.transcriptTimelineItems
    let hasText = !session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    if !hasText {
      let status = CepessaStatusStyle.resolve(session.status)
      emptyState(
        title: pendingTitle(for: status),
        message: pendingMessage(for: session, status: status),
        symbol: status == .ready ? "waveform" : status.symbol
      )
    } else {
      GeometryReader { proxy in
        let width = columnWidth(available: proxy.size.width)
        ScrollView {
          VStack(alignment: .leading, spacing: sz(24)) {
            ForEach(items) { item in
              transcriptBlock(item, in: session, width: width)
            }
          }
          .frame(width: width, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.top, 36)
          .padding(.bottom, 72)
        }
        .scrollIndicators(.hidden)
      }
    }
  }

  /// What to say when a session has no transcript text yet.
  ///
  /// The old copy told everyone to "Run Transcribe from the toolbar" — which
  /// is wrong advice while capture is still running and worse advice while the
  /// transcript is already being generated. Each state now says what is
  /// actually happening, in the same words the indicator and the menu-bar item
  /// use for it.
  private func pendingTitle(for status: CepessaStatusStyle) -> String {
    switch status {
    case .capturing: return "Recording"
    case .working: return "Transcribing"
    case .needsAttention: return "Needs Attention"
    case .ready: return "Transcript Not Ready"
    }
  }

  private func pendingMessage(for session: LocalSession, status: CepessaStatusStyle) -> String {
    switch status {
    case .capturing:
      return "This session is still being captured. The transcript appears once you stop."
    case .working:
      if let detail = model.processingStatusDetail?.trimmingCharacters(in: .whitespacesAndNewlines),
        !detail.isEmpty
      {
        return detail
      }
      return "Preparing the transcript on this Mac."
    case .needsAttention:
      if let error = model.recorderErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
        !error.isEmpty
      {
        return error
      }
      return "Processing stopped before a transcript was written. Try Transcribe from the toolbar."
    case .ready:
      return "The audio is saved. Run Transcribe from the toolbar to read it."
    }
  }

  private func transcriptBlock(
    _ item: LocalSessionTranscriptTimelineItem, in session: LocalSession, width: CGFloat
  ) -> some View {
    let segment = item.segment
    let images = timelineImages(for: item, in: session)

    return VStack(alignment: .leading, spacing: sz(7)) {
      HStack(spacing: 8) {
        if !segment.speaker.trimmingCharacters(in: .whitespaces).isEmpty {
          Text(segment.speaker.uppercased())
            .font(.system(size: sz(11), weight: .semibold))
            .foregroundColor(CepessaColors.textTertiary)
            .tracking(0.4)
        }

        Text(timestampLabel(for: segment, in: session))
          .font(.system(size: sz(11), weight: .medium).monospacedDigit())
          .foregroundColor(CepessaColors.textQuaternary)
      }

      Text(segment.text)
        .font(.system(size: sz(15)))
        .foregroundColor(CepessaColors.textPrimary)
        .lineSpacing(sz(5))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
          if segment.speakerID != nil {
            Button("Rename \(segment.speaker)") {
              proposedSpeakerName = segment.speaker
              renameTarget = segment
            }
            Button("Undo latest speaker rename") {
              if let speakerID = segment.speakerID {
                _ = model.undoLatestSpeakerRename(speakerID: speakerID)
              }
            }
          }
        }

      if !images.isEmpty {
        VStack(alignment: .leading, spacing: sz(8)) {
          ForEach(images, id: \.0) { _, title, image in
            Button {
              enlargedImage = image
            } label: {
              Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: width, maxHeight: inlineImageMaxHeight, alignment: .leading)
                .clipShape(
                  RoundedRectangle(cornerRadius: CepessaChrome.cardRadius, style: .continuous)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: CepessaChrome.cardRadius, style: .continuous)
                    .strokeBorder(CepessaColors.border, lineWidth: 1)
                )
                .contentShape(
                  RoundedRectangle(cornerRadius: CepessaChrome.cardRadius, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .help("Open \(title)")
            .accessibilityLabel("Open attachment \(title)")
          }
        }
        .padding(.top, sz(4))
      }
    }
  }

  /// Screenshots and image attachments pinned to this transcript moment.
  private func timelineImages(
    for item: LocalSessionTranscriptTimelineItem, in session: LocalSession
  ) -> [(UUID, String, NSImage)] {
    var attachments = item.attachments
    let captureAttachmentIDs = Set(item.captureArtifacts.flatMap { $0.attachmentIDs })
    if !captureAttachmentIDs.isEmpty {
      attachments += session.attachments.filter { captureAttachmentIDs.contains($0.id) }
    }

    var seen = Set<UUID>()
    return attachments.compactMap { attachment in
      guard !seen.contains(attachment.id), let image = attachmentImage(for: attachment) else {
        return nil
      }
      seen.insert(attachment.id)
      return (attachment.id, attachment.title, image)
    }
  }

  private func attachmentImage(for attachment: LocalSessionAttachment) -> NSImage? {
    guard attachment.kind == .image || attachment.kind == .capture else { return nil }
    guard let urlString = attachment.urlString else { return nil }
    if urlString.hasPrefix("/") {
      return NSImage(contentsOfFile: urlString)
    }
    if let url = URL(string: urlString), url.isFileURL {
      return NSImage(contentsOf: url)
    }
    return nil
  }

  private func timestampLabel(for segment: LocalSessionTranscriptSegment, in session: LocalSession)
    -> String
  {
    let offset = max(0, segment.timestamp.timeIntervalSince(session.startedAt))
    let total = Int(offset.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%d:%02d", m, s)
  }

  // MARK: Zoom

  private func setScale(_ value: Double) {
    textScale = min(max(value, minScale), maxScale)
  }

  private var zoomShortcuts: some View {
    ZStack {
      Button("") { setScale(textScale + 0.1) }
        .keyboardShortcut("+", modifiers: .command)
      Button("") { setScale(textScale + 0.1) }
        .keyboardShortcut("=", modifiers: .command)
      Button("") { setScale(textScale - 0.1) }
        .keyboardShortcut("-", modifiers: .command)
      Button("") { setScale(1.0) }
        .keyboardShortcut("0", modifiers: .command)
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  /// The system empty state — correct metrics, typography and VoiceOver
  /// grouping for free, instead of a hand-rolled stack of labels.
  private func emptyState(title: String, message: String, symbol: String) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: symbol)
    } description: {
      Text(message)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Native window toolbar

/// Owns the reading window's toolbar: the session picker, export and transcribe
/// controls. Keeping these in the titlebar leaves the content pure.
@MainActor
final class CepessaSessionReadingToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
  private weak var model: LocalMeetingAppModel?
  private weak var window: NSWindow?
  private var cancellables: Set<AnyCancellable> = []
  private let exporter = LocalSessionRecapExporter()

  private let sessionItemID = NSToolbarItem.Identifier("cepessa.reading.session")
  private let exportItemID = NSToolbarItem.Identifier("cepessa.reading.export")
  private let transcribeItemID = NSToolbarItem.Identifier("cepessa.reading.transcribe")

  init(model: LocalMeetingAppModel, window: NSWindow) {
    self.model = model
    self.window = window
    super.init()

    let toolbar = NSToolbar(identifier: "cepessa.reading.toolbar")
    toolbar.delegate = self
    toolbar.displayMode = .default
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.toolbarStyle = .unified

    // Refresh titles/validation when the selected session or list changes.
    let publishers: [AnyPublisher<Void, Never>] = [
      model.$selectedSessionID.map { _ in () }.eraseToAnyPublisher(),
      model.$sessions.map { _ in () }.eraseToAnyPublisher(),
    ]
    Publishers.MergeMany(publishers)
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak window] in
        self?.refreshTitles()
        window?.toolbar?.validateVisibleItems()
      }
      .store(in: &cancellables)
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [sessionItemID, .flexibleSpace, transcribeItemID, exportItemID]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch identifier {
    case sessionItemID:
      let item = NSMenuToolbarItem(itemIdentifier: identifier)
      item.title = currentSessionTitle
      item.image = NSImage(
        systemSymbolName: "rectangle.stack", accessibilityDescription: "Sessions")
      item.menu = sessionMenu()
      item.showsIndicator = true
      return item

    case transcribeItemID:
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = "Transcribe"
      item.image = NSImage(
        systemSymbolName: "waveform.badge.magnifyingglass", accessibilityDescription: "Transcribe")
      item.target = self
      item.action = #selector(transcribeAction)
      item.toolTip = "Run a fresh local transcript"
      return item

    case exportItemID:
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = "Export"
      item.image = NSImage(
        systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
      item.target = self
      item.action = #selector(exportAction)
      item.toolTip = "Save the transcript as Markdown"
      return item

    default:
      return nil
    }
  }

  // MARK: Menus

  private func sessionMenu() -> NSMenu {
    let menu = NSMenu()
    let sessions = model?.sessions ?? []
    if sessions.isEmpty {
      let empty = NSMenuItem(title: "No sessions yet", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
      return menu
    }
    for session in sessions {
      let item = NSMenuItem(
        title: session.displayTitle, action: #selector(selectSessionAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = session.id
      item.state = (session.id == model?.selectedSessionID) ? .on : .off
      menu.addItem(item)
    }
    return menu
  }

  // MARK: Actions

  @objc private func selectSessionAction(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    model?.selectSession(id: id)
  }

  @objc private func transcribeAction() {
    guard let id = model?.selectedSessionID else { return }
    model?.retranscribeSession(id: id)
  }

  @objc private func exportAction() {
    guard let session = model?.selectedSession, let window else { return }

    let panel = NSSavePanel()
    panel.title = "Export Transcript"
    panel.nameFieldStringValue =
      LocalSessionRecapMarkdownDocument.title(for: session, language: .english) + " Transcript.md"
    if let markdownType = UTType(filenameExtension: "md") {
      panel.allowedContentTypes = [markdownType]
    }

    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let directory = panel.directoryURL, let self else { return }
      do {
        _ = try self.exporter.exportTranscriptMarkdown(session: session, to: directory)
      } catch {
        let alert = NSAlert(error: error)
        alert.messageText = "The transcript could not be exported"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
      }
    }
  }

  // MARK: Validation & titles

  nonisolated func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    MainActor.assumeIsolated {
      switch item.itemIdentifier {
      case transcribeItemID:
        guard let session = model?.selectedSession else { return false }
        return model?.canRetranscribe(session) ?? false
      case exportItemID:
        guard let session = model?.selectedSession else { return false }
        return !session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      default:
        return true
      }
    }
  }

  private var currentSessionTitle: String {
    model?.selectedSession?.displayTitle ?? "Sessions"
  }

  private func refreshTitles() {
    guard let items = window?.toolbar?.items else { return }
    for item in items {
      if item.itemIdentifier == sessionItemID, let menuItem = item as? NSMenuToolbarItem {
        menuItem.title = currentSessionTitle
        menuItem.menu = sessionMenu()
      }
    }
  }

  func setVisible(_ isVisible: Bool) {
    window?.toolbar?.isVisible = isVisible
  }
}
