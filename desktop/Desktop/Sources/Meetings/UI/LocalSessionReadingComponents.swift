import AVFoundation
import AppKit
import SwiftUI

/// Keeps the recording next to the words it produced.
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
    currentTime = Self.resolvedSeek(time: time, duration: duration)
    player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
  }

  nonisolated static func resolvedSeek(time: Double, duration: Double) -> Double {
    guard time.isFinite else { return 0 }
    let boundedDuration = duration.isFinite ? max(0, duration) : 0
    return min(boundedDuration, max(0, time))
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

/// The recording as a line of light: play, a track that fills in the orb's
/// gold, and the time it has reached.
struct LocalSessionAudioPlayer: View {
  let url: URL
  var seekSeconds: Double? = nil
  var seekGeneration: UUID? = nil
  @StateObject private var playback = LocalSessionAudioPlayback()
  @State private var isScrubbing = false
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 14) {
      Button(action: playback.toggle) {
        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(SessionsPalette.inkInverse)
          .offset(x: playback.isPlaying ? 0 : 1)
          .frame(width: 34, height: 34)
          .background(Circle().fill(SessionsPalette.ink))
          .contentShape(Circle())
      }
      .buttonStyle(SessionsPressStyle(scale: 0.92))
      .disabled(playback.duration == 0)
      .keyboardShortcut(.space, modifiers: [])
      .accessibilityLabel(playback.isPlaying ? "Pause recording" : "Play recording")

      track

      Text("\(stamp(playback.currentTime)) / \(stamp(playback.duration))")
        .font(SessionsType.figure(12))
        .foregroundStyle(SessionsPalette.inkTertiary)
        .fixedSize()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .sessionsRaised(radius: 26)
    .overlay(alignment: .bottomLeading) {
      if let error = playback.errorMessage {
        Text(error)
          .font(SessionsType.text(12))
          .foregroundStyle(SessionsPalette.inkTertiary)
          .offset(y: 20)
      }
    }
    .task(id: url) { await playback.load(url) }
    .onChange(of: seekGeneration) { _, _ in
      guard let seekSeconds else { return }
      playback.seek(to: seekSeconds)
    }
    .onDisappear { playback.stop() }
  }

  private var track: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let fraction = playback.duration > 0 ? playback.currentTime / playback.duration : 0
      ZStack(alignment: .leading) {
        Capsule()
          .fill(SessionsPalette.hairline)
          .frame(height: isHovered || isScrubbing ? 6 : 4)
        Capsule()
          .fill(
            LinearGradient(
              colors: [SessionsPalette.sunriseGold, SessionsPalette.cloudCoral],
              startPoint: .leading, endPoint: .trailing)
          )
          .frame(width: max(0, width * fraction), height: isHovered || isScrubbing ? 6 : 4)
          .shadow(color: SessionsPalette.sunriseGold.opacity(0.45), radius: 4)
        Circle()
          .fill(SessionsPalette.lightCore)
          .frame(width: 12, height: 12)
          .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
          .offset(x: max(0, min(width - 12, width * fraction - 6)))
          .opacity(isHovered || isScrubbing ? 1 : 0)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            isScrubbing = true
            playback.seek(to: Double(max(0, min(1, value.location.x / width))) * playback.duration)
          }
          .onEnded { _ in isScrubbing = false }
      )
    }
    .frame(height: 24)
    .onHover { isHovered = $0 }
    .animation(SessionsMotion.hover, value: isHovered)
    .disabled(playback.duration == 0)
    .accessibilityElement()
    .accessibilityLabel("Recording position")
    .accessibilityValue("\(stamp(playback.currentTime)) of \(stamp(playback.duration))")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: playback.seek(to: playback.currentTime + 10)
      case .decrement: playback.seek(to: playback.currentTime - 10)
      @unknown default: break
      }
    }
  }

  private func stamp(_ seconds: Double) -> String {
    let seconds = Int(max(0, seconds.isFinite ? seconds : 0))
    return seconds >= 3600
      ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
      : String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

/// Everything pinned to the recording, in the order it was pinned: images as
/// thumbnails, files as named tiles. Both open the real thing.
struct LocalSessionAttachmentsStrip: View {
  let session: LocalSession
  let folder: URL?
  let enlarge: (NSImage) -> Void

  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SessionsEyebrow(text: "Pinned · \(session.attachments.count)")
      ScrollView(.horizontal) {
        HStack(spacing: 10) {
          ForEach(session.attachments) { attachment in
            tile(for: attachment)
          }
        }
        .padding(.vertical, 2)
      }
      .scrollIndicators(.hidden)
      if let errorMessage {
        Text(errorMessage)
          .font(SessionsType.text(12))
          .foregroundStyle(SessionsPalette.inkTertiary)
      }
    }
  }

  @ViewBuilder
  private func tile(for attachment: LocalSessionAttachment) -> some View {
    let url = LocalSessionAttachmentResolver.localURL(for: attachment, in: folder)
    let isImage = attachment.kind == .image || attachment.kind == .capture
    let image = isImage ? url.flatMap { SessionsImageCache.image(at: $0) } : nil

    Button {
      if let image {
        enlarge(image)
      } else if let url, FileManager.default.fileExists(atPath: url.path),
        NSWorkspace.shared.open(url)
      {
        errorMessage = nil
      } else {
        errorMessage = "This attachment is no longer at its saved location."
      }
    } label: {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 132, height: 84)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(SessionsPalette.hairline, lineWidth: 1))
      } else {
        HStack(spacing: 8) {
          Image(systemName: "doc.text")
            .foregroundStyle(SessionsPalette.accent)
          Text(attachment.title)
            .font(SessionsType.text(13, weight: .medium))
            .foregroundStyle(SessionsPalette.ink)
            .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .frame(width: 180, height: 84, alignment: .leading)
        .sessionsRaised(radius: 12)
      }
    }
    .buttonStyle(SessionsPressStyle(scale: 0.97))
    .help(attachment.title)
    .accessibilityLabel("Open attachment \(attachment.title)")
  }
}
