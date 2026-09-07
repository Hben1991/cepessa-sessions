import AVFoundation
import AVKit
import AppKit
import SwiftUI

struct LocalSessionReadingNotice: Equatable {
  let title: String
  let detail: String
  let needsReview: Bool

  static func resolve(_ session: LocalSession) -> Self {
    let hasText = !session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if session.status == .recording {
      return .init(
        title: "Recording", detail: "The transcript will follow when recording stops.",
        needsReview: false)
    }
    if session.status == .transcribing {
      return .init(
        title: "Transcribing", detail: "Processing the recording on this Mac.", needsReview: false)
    }
    if session.status == .failed || session.transcriptionEvidence?.isComplete == false || !hasText {
      return .init(
        title: hasText ? "Transcript needs review" : "Transcript not ready",
        detail: session.processingError ?? session.transcriptionEvidence?.issues.first
          ?? (hasText
            ? "Some of the recording may be missing. Listen to the audio before relying on this text."
            : "Use Transcribe to try the saved audio again."),
        needsReview: true)
    }
    if session.transcriptionEvidence?.isComplete != true {
      return .init(
        title: "Saved transcript",
        detail:
          "This older transcript has no completeness check. The audio is the source of truth.",
        needsReview: false)
    }
    return .init(
      title: "Transcript ready", detail: "Source timing and detected speech coverage were checked.",
      needsReview: false)
  }
}

/// A compact audio transport keeps the recording next to the words it produced.
@MainActor
final class LocalSessionAudioPlayback: ObservableObject {
  @Published private(set) var isPlaying = false
  @Published private(set) var duration: Double = 0
  @Published private(set) var currentTime: Double = 0
  @Published private(set) var errorMessage: String?
  private var player: AVPlayer?
  private var observer: Any?
  private var endObserver: NSObjectProtocol?
  private var generation = UUID()

  func load(_ url: URL) async {
    stop()
    let generation = UUID()
    self.generation = generation
    let asset = AVURLAsset(url: url)
    do {
      let loadedDuration = try await asset.load(.duration).seconds
      guard self.generation == generation else { return }
      guard loadedDuration.isFinite, loadedDuration > 0 else {
        errorMessage = "This audio file could not be played."
        return
      }
      let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      self.player = player
      duration = loadedDuration
      observer = player.addPeriodicTimeObserver(
        forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
      ) { [weak self] time in
        Task { @MainActor in
          guard let self, self.generation == generation else { return }
          self.currentTime = time.seconds.isFinite ? time.seconds : 0
        }
      }
      endObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.generation == generation else { return }
          self.isPlaying = false
        }
      }
    } catch {
      guard self.generation == generation else { return }
      errorMessage = "The recording could not be opened for playback."
    }
  }

  func toggle() {
    guard let player else { return }
    if isPlaying {
      player.pause()
    } else {
      if currentTime >= duration - 0.1 { seek(to: 0) }
      player.play()
    }
    isPlaying.toggle()
  }

  func seek(to time: Double) {
    guard time.isFinite else { return }
    currentTime = min(duration, max(0, time))
    player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
  }

  func stop() {
    generation = UUID()
    player?.pause()
    if let observer { player?.removeTimeObserver(observer) }
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    observer = nil
    endObserver = nil
    player = nil
    duration = 0
    currentTime = 0
    isPlaying = false
    errorMessage = nil
  }
}

struct LocalSessionAudioPlayer: View {
  let url: URL
  @StateObject private var playback = LocalSessionAudioPlayback()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Button(action: playback.toggle) {
          Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .disabled(playback.duration == 0)
        .accessibilityLabel(playback.isPlaying ? "Pause recording playback" : "Play recording")
        Slider(
          value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
          in: 0...max(1, playback.duration)
        )
        .disabled(playback.duration == 0)
        .accessibilityLabel("Recording playback position")
        Text("\(stamp(playback.currentTime)) / \(stamp(playback.duration))")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      if let error = playback.errorMessage {
        Text(error).font(.caption).foregroundStyle(.secondary)
      }
    }
    .task(id: url) { await playback.load(url) }
    .onDisappear { playback.stop() }
  }

  private func stamp(_ seconds: Double) -> String {
    let seconds = Int(max(0, seconds.isFinite ? seconds : 0))
    return seconds >= 3600
      ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
      : String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

struct LocalSessionAttachmentsView: View {
  let session: LocalSession
  let folder: URL?
  @State private var expanded = true
  @State private var errorMessage: String?

  var body: some View {
    DisclosureGroup("Attachments (\(session.attachments.count))", isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(session.attachments) { attachment in
          Button {
            guard let url = localURL(for: attachment),
              FileManager.default.fileExists(atPath: url.path), NSWorkspace.shared.open(url)
            else {
              errorMessage = "This attachment is no longer at its saved location."
              return
            }
          } label: {
            Label(
              attachment.title,
              systemImage: attachment.kind == .image || attachment.kind == .capture
                ? "photo" : "doc"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Open attachment \(attachment.title)")
        }
        if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
      }
      .padding(.top, 10)
    }
    .font(.callout)
  }

  private func localURL(for attachment: LocalSessionAttachment) -> URL? {
    if let name = attachment.fileName, name == URL(fileURLWithPath: name).lastPathComponent,
      let folder
    {
      let url = folder.appendingPathComponent("Attachments").appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) { return url }
      let lowercaseURL = folder.appendingPathComponent("attachments").appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: lowercaseURL.path) { return lowercaseURL }
    }
    guard let path = attachment.urlString else { return nil }
    if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
    if let url = URL(string: path), url.isFileURL { return url }
    return nil
  }
}

struct LocalSessionLibrarySheet: View {
  @ObservedObject var model: LocalMeetingAppModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var selection: UUID?

  private var matches: [LocalSession] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty
      ? model.sessions
      : model.sessions.filter {
        $0.title.localizedCaseInsensitiveContains(query)
          || $0.transcriptText.localizedCaseInsensitiveContains(query)
      }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Sessions").font(.title3.weight(.semibold))
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(20)
      TextField("Search titles and transcripts", text: $query)
        .textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.bottom, 12)
        .accessibilityLabel("Search sessions")
      List(selection: $selection) {
        ForEach(matches) { session in
          VStack(alignment: .leading, spacing: 4) {
            Text(session.displayTitle).lineLimit(2)
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
              .font(.caption).foregroundStyle(.secondary)
          }
          .tag(session.id)
          .contextMenu {
            Button("Open") { open(session.id) }
          }
          .onTapGesture(count: 2) { open(session.id) }
        }
      }
      .overlay {
        if matches.isEmpty { ContentUnavailableView.search(text: query) }
      }
      HStack {
        Text("\(matches.count) \(matches.count == 1 ? "session" : "sessions")")
          .font(.caption).foregroundStyle(.secondary)
        Button("Reload") { model.refreshLibraryIfIdle() }
          .disabled(model.captureLifecycle.isBusy || model.isTranscribing)
        Spacer()
        Button("Open Session") { if let selection { open(selection) } }
          .keyboardShortcut(.defaultAction).disabled(selection == nil)
      }.padding(20)
    }
    .frame(width: 520, height: 480)
    .onAppear {
      model.refreshLibraryIfIdle()
      selection = model.selectedSessionID
    }
    .onChange(of: query) { _, _ in
      if !matches.contains(where: { $0.id == selection }) { selection = nil }
    }
  }

  private func open(_ id: UUID) {
    model.selectSession(id: id)
    dismiss()
  }
}
