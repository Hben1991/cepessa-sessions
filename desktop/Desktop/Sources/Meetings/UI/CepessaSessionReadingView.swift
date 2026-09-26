import AppKit
import SwiftUI

/// One recording, read. The title is said in the display face; the transcript
/// is set for reading — one measure, generous leading, each speaker's turn in
/// its own light — with the recording and pinned screenshots kept next to the
/// words they belong to.
///
/// Long text is read, not watched: only the header and the first few turns
/// arrive with motion, and they arrive in well under a second.
struct CepessaSessionReadingView: View {
  /// Turns that arrive with the staggered reveal when a session opens.
  static let arrivingTurns = 6

  @ObservedObject var model: LocalMeetingAppModel
  let back: () -> Void

  /// Reading-only text zoom (⌘+ / ⌘- / ⌘0 or trackpad pinch).
  @AppStorage("cepessa.reading.textScale") private var textScale: Double = 1.0
  @GestureState private var pinch: CGFloat = 1
  @State private var enlargedImage: NSImage?
  // Each rename remembers its session when it begins: starting a recording
  // or pinning a screenshot while the alert is open changes the selection.
  @State private var renameTarget: (segment: LocalSessionTranscriptSegment, sessionID: UUID)?
  @State private var proposedSpeakerName = ""
  @State private var renamingSessionID: UUID?
  @State private var proposedTitle = ""
  @State private var editError: String?
  @State private var isTitleHovered = false

  private let baseMeasure: CGFloat = 680
  private let minScale = 0.8
  private let maxScale = 1.8

  private var zoom: CGFloat { CGFloat(textScale) * pinch }

  var body: some View {
    VStack(spacing: 0) {
      topBar
      if let session = model.selectedSession {
        content(for: session)
          .id(session.id)
      }
    }
    .gesture(
      MagnifyGesture()
        .updating($pinch) { value, state, _ in
          state = min(max(value.magnification, 0.7), 1.6)
        }
        .onEnded { value in
          setScale(textScale * Double(value.magnification))
        }
    )
    .background(zoomShortcuts)
    .overlay {
      if let enlargedImage {
        lightbox(enlargedImage)
      }
    }
    .alert(
      "Rename session",
      isPresented: Binding(
        get: { renamingSessionID != nil },
        set: { if !$0 { renamingSessionID = nil } }
      ),
      presenting: renamingSessionID
    ) { sessionID in
      TextField("Session title", text: $proposedTitle)
      Button("Cancel", role: .cancel) { renamingSessionID = nil }
      Button("Save") {
        editError =
          model.updateSessionTitle(proposedTitle, for: sessionID)
          ? nil : model.recorderErrorMessage ?? "The session title could not be saved."
        renamingSessionID = nil
      }
      .disabled(proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .alert(
      "Rename speaker",
      isPresented: Binding(
        get: { renameTarget != nil },
        set: { if !$0 { renameTarget = nil } }
      ),
      presenting: renameTarget
    ) { target in
      TextField("Speaker name", text: $proposedSpeakerName)
      Button("Cancel", role: .cancel) { renameTarget = nil }
      Button("Save") {
        if let speakerID = target.segment.speakerID {
          editError =
            model.renameSpeaker(
              speakerID: speakerID, to: proposedSpeakerName, in: target.sessionID)
            ? nil : model.recorderErrorMessage ?? "The speaker name could not be saved."
        }
        renameTarget = nil
      }
      .disabled(proposedSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: { _ in
      Text("This adds a local correction without changing the original transcript evidence.")
    }
  }

  // MARK: Top bar

  private var topBar: some View {
    SessionsTopBar {
      SessionsBackButton(title: "Sessions", action: back)
    } trailing: {
      if let session = model.selectedSession {
        SessionsRoundIconButton(
          symbol: "arrow.clockwise", title: "Transcribe Again"
        ) {
          model.retranscribeSession(id: session.id)
        }
        .disabled(!model.canRetranscribe(session))

        SessionsRoundIconButton(
          symbol: "square.and.arrow.up", title: "Export Transcript…",
          action: CepessaSessionsWindowController.shared.exportSelectedTranscript
        )
        .disabled(!hasText(session))
      }
    }
  }

  // MARK: Content

  private func content(for session: LocalSession) -> some View {
    let status = CepessaStatusStyle.resolve(session.status)
    let isRTL = LocalTranscriptTextDirection.isRightToLeft(session.displayTitle)

    return GeometryReader { geometry in
      let measure = min(baseMeasure * zoom, max(360, geometry.size.width - 96))
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          header(session, isRTL: isRTL)
            .padding(.bottom, 34)

          if let audioURL = model.audioPlaybackURL(for: session), session.status != .recording {
            LocalSessionAudioPlayer(url: audioURL)
              .sessionsArrival(2)
              .padding(.bottom, 30)
          }

          if !session.attachments.isEmpty {
            LocalSessionAttachmentsStrip(
              session: session, folder: model.sessionFolderURL(for: session.id)
            ) { image in
              enlargedImage = image
            }
            .sessionsArrival(3)
            .padding(.bottom, 34)
          }

          if hasText(session) {
            transcript(session, measure: measure)
            transcriptEnd(session)
              .padding(.top, 56)
          } else {
            pendingState(session, status: status)
          }
        }
        .frame(width: measure, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 120)
      }
      .scrollIndicators(.automatic)
      // Words fade under the top strip and into the bottom edge instead of
      // being cut by them.
      .mask {
        VStack(spacing: 0) {
          LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            .frame(height: 28)
          Color.black
          LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 44)
        }
      }
    }
  }

  // MARK: Header

  private func header(_ session: LocalSession, isRTL: Bool) -> some View {
    let notice = LocalSessionReadingNotice.resolve(session)
    let progress = model.processingSnapshot(for: session.id)
    let saveError = model.sessionSaveErrors[session.id]
    let titleSize = 48 * min(zoom, 1.3)
    let edge: Alignment = isRTL ? .trailing : .leading

    return VStack(alignment: isRTL ? .trailing : .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        if isRTL {
          Spacer(minLength: 0)
          renameButton(session)
        }
        SessionsRevealedLine(
          // Isolated in the direction it is aligned to, so "Q3 סיכום" reads
          // right to left like its alignment says.
          text: LocalTranscriptTextDirection.displayText(session.displayTitle),
          font: SessionsType.display(titleSize),
          alignment: isRTL ? .trailing : .leading,
          tracking: titleSize * -0.02
        )
        .onTapGesture(count: 2) { beginRename(session) }
        .contextMenu {
          Button("Rename…") { beginRename(session) }
        }
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: "Rename") { beginRename(session) }
        if !isRTL {
          renameButton(session)
          Spacer(minLength: 0)
        }
      }
      .onHover { isTitleHovered = $0 }

      Text(metaLine(for: session))
        .font(SessionsType.text(14))
        .foregroundStyle(SessionsPalette.inkTertiary)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: edge)
        .sessionsArrival(1)

      // Only what changes how the words should be trusted earns a line here:
      // work in progress, a transcript that needs review, a failed save.
      if saveError != nil || progress != nil || (notice.needsReview && hasText(session)) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: saveError != nil || notice.needsReview ? "exclamationmark.triangle.fill" : "waveform")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(
              saveError != nil || notice.needsReview ? SessionsPalette.attention : SessionsPalette.accent)
          VStack(alignment: .leading, spacing: 3) {
            Text(saveError != nil ? "Changes not saved" : progress?.title ?? notice.title)
              .font(SessionsType.text(14, weight: .semibold))
              .foregroundStyle(SessionsPalette.ink)
            Text(saveError ?? progress?.detail ?? notice.detail)
              .font(SessionsType.text(13))
              .foregroundStyle(SessionsPalette.inkSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .sessionsArrival(2)
      }

      if let fraction = progress?.progress {
        SessionsLightProgress(fraction: fraction)
          .frame(height: 3)
          .padding(.top, 4)
          .accessibilityLabel("Transcription progress")
          .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
      }

      if saveError == nil, let editError {
        Label(editError, systemImage: "exclamationmark.triangle.fill")
          .font(SessionsType.text(13))
          .foregroundStyle(SessionsPalette.attention)
      }
    }
  }

  /// A pencil that appears beside the title on hover. Double-click and the
  /// context menu rename too; this makes the action findable.
  private func renameButton(_ session: LocalSession) -> some View {
    Button {
      beginRename(session)
    } label: {
      Image(systemName: "pencil")
        .font(.system(size: 13, weight: .semibold))
    }
    .buttonStyle(SessionsRoundButtonStyle(diameter: 28))
    .opacity(isTitleHovered ? 1 : 0)
    .animation(SessionsMotion.hover, value: isTitleHovered)
    .help("Rename")
    .accessibilityLabel("Rename session")
  }

  /// When it was, and who was there: one quiet line under the title.
  private func metaLine(for session: LocalSession) -> String {
    let day = session.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide))
    let time = session.startedAt.formatted(date: .omitted, time: .shortened)
    var parts = [day, time]
    let speakers = Set(session.transcriptSegments.map(\.speaker).filter { !$0.isEmpty })
    if speakers.count > 1 {
      parts.append("\(speakers.count) speakers")
    }
    if !session.attachments.isEmpty {
      parts.append("\(session.attachments.count) pinned")
    }
    return parts.joined(separator: "  ·  ")
  }

  /// The close of a transcript: a point of light, and — for a transcript made
  /// before completeness checks existed — the honest footnote.
  private func transcriptEnd(_ session: LocalSession) -> some View {
    let notice = LocalSessionReadingNotice.resolve(session)
    let isLegacy = !notice.needsReview && session.transcriptionEvidence?.isComplete != true
    return VStack(spacing: 12) {
      Circle()
        .fill(SessionsPalette.sunriseGold)
        .frame(width: 5, height: 5)
        .shadow(color: SessionsPalette.sunriseGold.opacity(0.8), radius: 6)
      Text("End of transcript")
        .font(SessionsType.text(12.5, weight: .medium))
        .foregroundStyle(SessionsPalette.inkQuiet)
      if isLegacy {
        Text(notice.detail)
          .font(SessionsType.text(12.5))
          .foregroundStyle(SessionsPalette.inkQuiet)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  private func beginRename(_ session: LocalSession) {
    proposedTitle = session.title
    renamingSessionID = session.id
  }

  // MARK: Transcript

  private func hasText(_ session: LocalSession) -> Bool {
    !session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func transcript(_ session: LocalSession, measure: CGFloat) -> some View {
    let turns = SessionTranscriptTurn.group(session.transcriptTimelineItems)
    let voices = SessionTranscriptTurn.voiceOrder(session.transcriptSegments)
    return LazyVStack(alignment: .leading, spacing: 30 * zoom) {
      ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
        turnView(turn, in: session, measure: measure, voices: voices)
          .modifier(SessionsTurnHighlight())
          // Only the opening turns arrive; later ones are simply there when
          // scrolled to, never blank while a delayed reveal catches up.
          .sessionsArrival(index + 4, isEnabled: index < Self.arrivingTurns)
      }
    }
  }

  private func turnView(
    _ turn: SessionTranscriptTurn, in session: LocalSession, measure: CGFloat,
    voices: [String: Int]
  ) -> some View {
    let isRTL = LocalTranscriptTextDirection.isRightToLeft(
      turn.items.map(\.segment.text).joined(separator: " "))
    let alignment: HorizontalAlignment = isRTL ? .trailing : .leading

    return VStack(alignment: alignment, spacing: 10 * zoom) {
      turnLabel(turn, in: session, voices: voices, isRTL: isRTL)
        .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)

      ForEach(turn.items) { item in
        VStack(alignment: alignment, spacing: 14 * zoom) {
          Text(LocalTranscriptTextDirection.displayText(item.segment.text))
            .font(SessionsType.text(18 * zoom))
            .foregroundStyle(SessionsPalette.ink)
            .lineSpacing(18 * zoom * 0.5)
            .textSelection(.enabled)
            .multilineTextAlignment(isRTL ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
            .accessibilityLabel(item.segment.text)

          let images = timelineImages(for: item, in: session)
          if !images.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(images, id: \.0) { _, title, image in
                inlineImage(image, title: title, measure: measure)
              }
            }
          }
        }
        .id(item.segment.id)
      }
    }
  }

  private func turnLabel(
    _ turn: SessionTranscriptTurn, in session: LocalSession, voices: [String: Int],
    isRTL: Bool
  ) -> some View {
    let segment = turn.items[0].segment
    let speaker = segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
    let color = SessionsPalette.speakerColor(
      at: voices[SessionTranscriptTurn.speakerKey(segment)] ?? 0)

    return HStack(spacing: 9) {
      // The voice's own light, then its name.
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
        .shadow(color: color.opacity(0.75), radius: 5)
        .accessibilityHidden(true)
      if !speaker.isEmpty {
        if let speakerID = segment.speakerID, session.transcriptionEvidence != nil {
          Menu {
            Button("Rename Speaker…") {
              proposedSpeakerName = speaker
              renameTarget = (segment, session.id)
            }
            if segment.identityStatus == .confirmed {
              Button("Undo Latest Rename") {
                if !model.undoLatestSpeakerRename(speakerID: speakerID, in: session.id) {
                  editError =
                    model.recorderErrorMessage ?? "There is no saved speaker rename to undo."
                }
              }
            }
          } label: {
            SessionsEyebrow(text: speaker, color: color, size: 12 * min(zoom, 1.3))
          }
          .menuStyle(.button)
          .buttonStyle(.plain)
          .menuIndicator(.hidden)
          .fixedSize()
          .accessibilityLabel("Speaker actions for \(speaker)")
        } else {
          SessionsEyebrow(text: speaker, color: color, size: 12 * min(zoom, 1.3))
        }
      }

      Text(timestampLabel(for: segment, in: session))
        .font(SessionsType.figure(12 * min(zoom, 1.3)))
        .foregroundStyle(SessionsPalette.inkQuiet)
    }
    // Right-to-left turns read name-first from the right.
    .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
  }

  private func inlineImage(_ image: NSImage, title: String, measure: CGFloat) -> some View {
    Button {
      enlargedImage = image
    } label: {
      // The outline and shadow belong to the picture, not to the column, so
      // the picture is sized to fit exactly before they are drawn.
      Image(nsImage: image)
        .resizable()
        .frame(width: fitted(image, measure: measure).width, height: fitted(image, measure: measure).height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(SessionsPalette.imageOutline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(SessionsPressStyle(scale: 0.99))
    .help("Open \(title)")
    .accessibilityLabel("Open attachment \(title)")
  }

  private func fitted(_ image: NSImage, measure: CGFloat) -> CGSize {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return CGSize(width: measure, height: 200) }
    let scale = min(measure / size.width, 340 / size.height, 1)
    return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
  }

  /// Screenshots and image attachments pinned to this moment.
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
      guard !seen.contains(attachment.id),
        attachment.kind == .image || attachment.kind == .capture,
        let url = LocalSessionAttachmentResolver.localURL(
          for: attachment, in: model.sessionFolderURL(for: session.id)),
        let image = SessionsImageCache.image(at: url)
      else {
        return nil
      }
      seen.insert(attachment.id)
      return (attachment.id, attachment.title, image)
    }
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

  // MARK: Pending

  /// No words yet. Each state says what is actually happening, in the same
  /// words the recorder and the menu-bar item use.
  @ViewBuilder
  private func pendingState(_ session: LocalSession, status: CepessaStatusStyle) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      SessionsRevealedLine(
        text: pendingTitle(status),
        font: SessionsType.display(30),
        color: SessionsPalette.inkSecondary,
        delay: 0.25)
      Text(pendingMessage(for: session, status: status))
        .font(SessionsType.text(15))
        .foregroundStyle(SessionsPalette.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .sessionsArrival(4, after: 0.2)

      switch status {
      case .needsAttention, .ready:
        if model.canRetranscribe(session) {
          Button("Transcribe Again") { model.retranscribeSession(id: session.id) }
            .buttonStyle(SessionsCapsuleButtonStyle())
            .padding(.top, 8)
            .sessionsArrival(5, after: 0.2)
        } else if model.audioPlaybackURL(for: session) == nil {
          Button("Import Audio…", action: CepessaSessionsWindowController.shared.importAudio)
            .buttonStyle(SessionsCapsuleButtonStyle())
            .padding(.top, 8)
            .sessionsArrival(5, after: 0.2)
        }
      case .capturing, .working:
        EmptyView()
      }
    }
    .padding(.top, 18)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func pendingTitle(_ status: CepessaStatusStyle) -> String {
    switch status {
    case .capturing: return "Listening."
    case .working: return "Writing it down."
    case .needsAttention: return "The transcript didn’t finish."
    case .ready: return "Nothing to read yet."
    }
  }

  private func pendingMessage(for session: LocalSession, status: CepessaStatusStyle) -> String {
    switch status {
    case .capturing:
      return "This session is still being recorded. The transcript appears once you stop."
    case .working:
      if let detail = model.processingSnapshot(for: session.id)?.detail.trimmingCharacters(
        in: .whitespacesAndNewlines),
        !detail.isEmpty
      {
        return detail
      }
      return "Preparing the transcript on this Mac."
    case .needsAttention:
      let reason =
        session.processingError?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? session.transcriptionEvidence?.issues.first
      let base = reason.map { "\($0) " } ?? ""
      return model.audioPlaybackURL(for: session) != nil
        ? base + "The recording is saved; you can transcribe it again."
        : base + "Import the recording to try again."
    case .ready:
      return "The audio is saved. Transcribe it again to read it here."
    }
  }

  // MARK: Lightbox

  private func lightbox(_ image: NSImage) -> some View {
    ZStack {
      Rectangle()
        .fill(.ultraThinMaterial)
        .overlay(SessionsPalette.nightSkyTop.opacity(0.55))
        .ignoresSafeArea()

      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        .padding(56)

      VStack {
        HStack {
          Spacer()
          Button {
            enlargedImage = nil
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(SessionsRoundButtonStyle())
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Close image")
          .padding(20)
        }
        Spacer()
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { enlargedImage = nil }
    .transition(.opacity)
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
}

/// Consecutive transcript segments by the same speaker, read as one turn: the
/// name is said once, then the words follow. A long silence starts a new turn
/// even for the same voice, so a turn never hides a gap in the recording.
struct SessionTranscriptTurn: Identifiable, Equatable {
  let items: [LocalSessionTranscriptTimelineItem]

  var id: UUID { items[0].segment.id }

  static let maximumGap: TimeInterval = 90

  static func group(_ items: [LocalSessionTranscriptTimelineItem]) -> [SessionTranscriptTurn] {
    var turns: [[LocalSessionTranscriptTimelineItem]] = []
    for item in items {
      if let last = turns.last?.last,
        speakerKey(last.segment) == speakerKey(item.segment),
        !speakerKey(item.segment).isEmpty,
        item.segment.timestamp.timeIntervalSince(
          last.segment.endTimestamp ?? last.segment.timestamp) <= maximumGap
      {
        turns[turns.count - 1].append(item)
      } else {
        turns.append([item])
      }
    }
    return turns.map(SessionTranscriptTurn.init)
  }

  /// Each voice's place in the conversation, by first appearance, so the first
  /// speaker is always the gold one and two voices never share a colour
  /// until there are more voices than colours.
  static func voiceOrder(_ segments: [LocalSessionTranscriptSegment]) -> [String: Int] {
    var order: [String: Int] = [:]
    for segment in segments {
      let key = speakerKey(segment)
      if order[key] == nil { order[key] = order.count }
    }
    return order
  }

  static func speakerKey(_ segment: LocalSessionTranscriptSegment) -> String {
    segment.speakerID ?? segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// A turn lifts softly under the pointer, so the eye can hold its place in a
/// long transcript. The lift never changes layout.
struct SessionsTurnHighlight: ViewModifier {
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 18)
      .padding(.vertical, 14)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(isHovered ? SessionsPalette.raised.opacity(0.6) : .clear)
      )
      .padding(.horizontal, -18)
      .padding(.vertical, -14)
      .onHover { isHovered = $0 }
      .animation(SessionsMotion.hover, value: isHovered)
  }
}

/// A thin line of the orb's light that fills with real progress.
struct SessionsLightProgress: View {
  let fraction: Double

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(SessionsPalette.hairline)
        Capsule()
          .fill(
            LinearGradient(
              colors: [SessionsPalette.sunriseGold, SessionsPalette.cloudCoral],
              startPoint: .leading, endPoint: .trailing)
          )
          .frame(width: proxy.size.width * CGFloat(min(max(fraction, 0), 1)))
          .shadow(color: SessionsPalette.sunriseGold.opacity(0.5), radius: 4)
      }
    }
    .animation(.easeOut(duration: 0.4), value: fraction)
  }
}
