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
          title: "No session open",
          message: "Pick a session from the floating bar."
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(CepessaColors.backgroundPrimary)
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
  }

  private func enlargedOverlay(_ image: NSImage) -> some View {
    ZStack {
      Rectangle()
        .fill(Color.black.opacity(0.72))
        .ignoresSafeArea()

      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .padding(40)
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)

      VStack {
        HStack {
          Spacer()
          Button {
            enlargedImage = nil
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 13, weight: .bold))
              .foregroundColor(.white)
              .frame(width: 30, height: 30)
              .background(Color.white.opacity(0.16), in: Circle())
          }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .padding(20)
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
      emptyState(
        title: "Transcript not ready",
        message: "The raw audio is saved. Run Transcribe from the toolbar."
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

      if !images.isEmpty {
        VStack(alignment: .leading, spacing: sz(8)) {
          ForEach(images, id: \.0) { _, image in
            Image(nsImage: image)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: width, maxHeight: inlineImageMaxHeight, alignment: .leading)
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .stroke(CepessaColors.hairline.opacity(0.6), lineWidth: 1)
              )
              .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              .onTapGesture { enlargedImage = image }
              .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
              }
              .help("Click to enlarge")
          }
        }
        .padding(.top, sz(4))
      }
    }
  }

  /// Screenshots and image attachments pinned to this transcript moment.
  private func timelineImages(
    for item: LocalSessionTranscriptTimelineItem, in session: LocalSession
  ) -> [(UUID, NSImage)] {
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
      return (attachment.id, image)
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

  private func emptyState(title: String, message: String) -> some View {
    VStack(spacing: 8) {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(CepessaColors.textSecondary)
      Text(message)
        .font(.system(size: 13))
        .foregroundColor(CepessaColors.textTertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Native window toolbar

/// Owns the reading window's toolbar: the session picker, language, export and
/// transcribe controls. Keeping these in the titlebar leaves the content pure.
@MainActor
final class CepessaSessionReadingToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
  private weak var model: LocalMeetingAppModel?
  private weak var window: NSWindow?
  private var cancellables: Set<AnyCancellable> = []
  private let exporter = LocalSessionRecapExporter()

  private let sessionItemID = NSToolbarItem.Identifier("cepessa.reading.session")
  private let languageItemID = NSToolbarItem.Identifier("cepessa.reading.language")
  private let exportItemID = NSToolbarItem.Identifier("cepessa.reading.export")
  private let transcribeItemID = NSToolbarItem.Identifier("cepessa.reading.transcribe")

  init(model: LocalMeetingAppModel, window: NSWindow) {
    self.model = model
    self.window = window
    super.init()

    let toolbar = NSToolbar(identifier: "cepessa.reading.toolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
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
    [sessionItemID, .flexibleSpace, languageItemID, transcribeItemID, exportItemID]
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
      item.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Sessions")
      item.menu = sessionMenu()
      item.showsIndicator = true
      return item

    case languageItemID:
      let item = NSMenuToolbarItem(itemIdentifier: identifier)
      item.title = currentLanguage.shortTitle
      item.menu = languageMenu()
      item.showsIndicator = true
      item.toolTip = "Document language"
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

  private func languageMenu() -> NSMenu {
    let menu = NSMenu()
    for language in LocalSessionDocumentLanguage.allCases {
      let item = NSMenuItem(
        title: language.displayTitle, action: #selector(setLanguageAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = language.rawValue
      item.state = (language == currentLanguage) ? .on : .off
      menu.addItem(item)
    }
    return menu
  }

  // MARK: Actions

  @objc private func selectSessionAction(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    model?.selectSession(id: id)
  }

  @objc private func setLanguageAction(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String else { return }
    UserDefaults.standard.set(raw, forKey: "cepessa.sessions.documentLanguage")
    refreshTitles()
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
        NSSound.beep()
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

  private var currentLanguage: LocalSessionDocumentLanguage {
    LocalSessionDocumentLanguage(
      rawValue: UserDefaults.standard.string(forKey: "cepessa.sessions.documentLanguage") ?? "")
      ?? .hebrew
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
      if item.itemIdentifier == languageItemID, let menuItem = item as? NSMenuToolbarItem {
        menuItem.title = currentLanguage.shortTitle
        menuItem.menu = languageMenu()
      }
    }
  }
}
