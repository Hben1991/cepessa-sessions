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
    title: "Cepessa ready",
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

    if model.isGeneratingRecap {
      return CepessaSessionStatusBarSnapshot(
        mode: .transcriptReady,
        title: "Transcript ready",
        detail: model.processingStatusDetail ?? "Generating recap in the background.",
        progress: model.processingProgress,
        canRetryLocal: model.selectedSession.map { model.canRetranscribe($0) } ?? false,
        queueCount: model.processingQueue.count
      )
    }

    return .idle
  }
}

@MainActor
final class CepessaSessionStatusBarState: ObservableObject {
  @Published var snapshot = CepessaSessionStatusBarSnapshot.idle
  @Published var queueItems: [LocalSessionProcessingSnapshot] = []
  @Published var selectedSessionTitle = "No session selected"
  @Published var activeLogEntries: [LocalSessionProcessingLogEntry] = []
}

@MainActor
final class CepessaSessionStatusBarController {
  static let shared = CepessaSessionStatusBarController()

  let state = CepessaSessionStatusBarState()

  private var statusItem: NSStatusItem?
  private var popover: NSPopover?
  private var statusTarget: StatusBarTarget?
  private weak var model: LocalMeetingAppModel?
  private var cancellables: Set<AnyCancellable> = []

  func connect(model: LocalMeetingAppModel) {
    if self.model !== model {
      self.model = model
      bind(to: model)
    }
    ensureStatusItem()
    refresh()
  }

  func togglePopover() {
    guard let statusItem else { return }
    ensurePopover()

    if popover?.isShown == true {
      popover?.performClose(nil)
    } else if let button = statusItem.button {
      NSApp.activate(ignoringOtherApps: true)
      popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
  }

  func toggleRecording() {
    model?.toggleRecording()
  }

  func openMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) ?? NSApp.windows.first {
      window.makeKeyAndOrderFront(nil)
    }
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
      model.$isGeneratingRecap.map { _ in () }.eraseToAnyPublisher(),
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
    let target = StatusBarTarget(controller: self)
    item.button?.target = target
    item.button?.action = #selector(StatusBarTarget.toggle(_:))
    statusTarget = target
    statusItem = item
  }

  private func ensurePopover() {
    guard popover == nil else { return }
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentSize = NSSize(width: 340, height: 420)
    popover.contentViewController = NSHostingController(
      rootView: CepessaSessionStatusBarPopoverView(controller: self, state: state)
    )
    self.popover = popover
  }

  private func refresh() {
    guard let model else { return }
    let snapshot = CepessaSessionStatusBarSnapshot.make(from: model)
    state.snapshot = snapshot
    state.queueItems = model.processingQueue
    state.selectedSessionTitle = model.selectedSession?.displayTitle ?? "No session selected"
    if let selectedSessionID = model.selectedSessionID,
      let logEntries = model.processingSnapshot(for: selectedSessionID)?.logEntries
    {
      state.activeLogEntries = logEntries
    } else {
      state.activeLogEntries = model.processingQueue.first?.logEntries ?? []
    }

    if let button = statusItem?.button {
      button.image = statusImage(for: snapshot.mode)
      button.title = titleSuffix(for: snapshot)
      button.toolTip = "\(snapshot.title) - \(snapshot.detail)"
    }
  }

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
      symbolNames = ["mic.circle.fill", "record.circle.fill"]
    case .transcribing:
      symbolNames = ["text.magnifyingglass", "waveform.badge.magnifyingglass", "waveform"]
    case .failed:
      symbolNames = ["exclamationmark.bubble.fill", "exclamationmark.triangle.fill"]
    case .transcriptReady:
      symbolNames = ["text.bubble.fill", "checkmark.circle.fill"]
    }

    let image = symbolNames.lazy.compactMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: "Cepessa Sessions")
    }.first
    image?.isTemplate = mode != .failed
    return image
  }

  private final class StatusBarTarget: NSObject {
    weak var controller: CepessaSessionStatusBarController?

    init(controller: CepessaSessionStatusBarController) {
      self.controller = controller
    }

    @MainActor
    @objc func toggle(_ sender: Any?) {
      controller?.togglePopover()
    }
  }
}

private struct CepessaSessionStatusBarPopoverView: View {
  let controller: CepessaSessionStatusBarController
  @ObservedObject var state: CepessaSessionStatusBarState

  var body: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: 14) {
        popoverContent
      }
      .padding(14)
      .frame(width: 360, alignment: .topLeading)
      .frame(minHeight: 382, alignment: .topLeading)
      .background {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .fill(CepessaColors.backgroundPrimary.opacity(0.18))
          .glassEffect(.regular.tint(accentColor.opacity(0.12)), in: .rect(cornerRadius: 28))
      }
    } else {
      popoverContent
        .padding(18)
        .frame(width: 340, alignment: .topLeading)
        .frame(minHeight: 360, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }
  }

  private var popoverContent: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 16) {
        header
        actionRow
        statusDivider
        queueSection
        logSection
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Circle()
          .fill(accentColor)
          .frame(width: 10, height: 10)
        Text(state.snapshot.title)
          .scaledFont(size: 18, weight: .semibold)
          .foregroundStyle(CepessaColors.textPrimary)
      }

      Text(state.snapshot.detail)
        .scaledFont(size: 12)
        .foregroundStyle(CepessaColors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      if let progress = state.snapshot.progress {
        ProgressView(value: progress)
          .progressViewStyle(.linear)
      }
    }
    .padding(14)
    .cepessaStatusGlass(cornerRadius: 18, tint: accentColor.opacity(0.10))
  }

  private var actionRow: some View {
    VStack(spacing: 8) {
      Button {
        controller.toggleRecording()
      } label: {
        Label(
          state.snapshot.mode == .recording ? "Stop recording" : "Start recording",
          systemImage: state.snapshot.mode == .recording ? "stop.fill" : "record.circle")
      }
      .cepessaStatusButtonStyle(prominent: true)
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 8) {
        Button("Open session") {
          controller.openMainWindow()
        }
        .cepessaStatusButtonStyle(prominent: false)

        Button("Retry local") {
          controller.retryLocalTranscription()
        }
        .cepessaStatusButtonStyle(prominent: false)
        .disabled(!state.snapshot.canRetryLocal)
      }
    }
  }

  private var statusDivider: some View {
    Rectangle()
      .fill(
        LinearGradient(
          colors: [
            .clear,
            accentColor.opacity(0.18),
            CepessaColors.border.opacity(0.22),
            .clear,
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .frame(height: 1)
      .padding(.horizontal, 4)
  }

  private var queueSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Processing queue")
        .scaledFont(size: 12, weight: .semibold)
        .foregroundStyle(CepessaColors.textSecondary)

      if state.queueItems.isEmpty {
        Text("No active transcription work.")
          .scaledFont(size: 12)
          .foregroundStyle(CepessaColors.textTertiary)
      } else {
        ForEach(state.queueItems.prefix(4)) { item in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(item.phase.label)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(CepessaColors.textPrimary)
              Spacer()
              if let progressLabel = item.progressLabel {
                Text(progressLabel)
                  .scaledFont(size: 11)
                  .foregroundStyle(CepessaColors.textSecondary)
              }
            }
            Text(item.title)
              .scaledFont(size: 12, weight: .semibold)
              .foregroundStyle(CepessaColors.textPrimary)
            Text(item.detail)
              .scaledFont(size: 11)
              .foregroundStyle(CepessaColors.textSecondary)
              .lineLimit(2)
          }
          .padding(10)
          .cepessaStatusGlass(cornerRadius: 14, tint: accentColor.opacity(0.07))
        }
      }
    }
  }

  private var logSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Live log")
          .scaledFont(size: 12, weight: .semibold)
          .foregroundStyle(CepessaColors.textSecondary)

        Spacer(minLength: 0)

        Text("\(state.activeLogEntries.count) entries")
          .scaledFont(size: 10.5, weight: .medium)
          .foregroundStyle(CepessaColors.textTertiary)
      }

      if state.activeLogEntries.isEmpty {
        Text("Waiting for the next processing event.")
          .scaledFont(size: 11)
          .foregroundStyle(CepessaColors.textTertiary)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(state.activeLogEntries.suffix(6).reversed()) { entry in
            HStack(alignment: .top, spacing: 8) {
              Text(Self.logTimestampFormatter.string(from: entry.timestamp))
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(CepessaColors.textTertiary)
                .monospacedDigit()

              Text(entry.message)
                .scaledFont(size: 11)
                .foregroundStyle(CepessaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)

              Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
          }
        }
      }
    }
    .padding(12)
    .cepessaStatusGlass(cornerRadius: 16, tint: accentColor.opacity(0.06))
  }

  private var accentColor: Color {
    switch state.snapshot.mode {
    case .idle:
      return CepessaColors.textTertiary
    case .recording:
      return CepessaColors.error
    case .transcribing:
      return CepessaColors.purplePrimary
    case .failed:
      return CepessaColors.warning
    case .transcriptReady:
      return CepessaColors.success
    }
  }

  private static let logTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeStyle = .medium
    formatter.dateStyle = .none
    return formatter
  }()
}

private extension View {
  @ViewBuilder
  func cepessaStatusGlass(cornerRadius: CGFloat, tint: Color) -> some View {
    if #available(macOS 26.0, *) {
      self
        .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
    } else {
      self
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(CepessaColors.border.opacity(0.22), lineWidth: 1)
        )
    }
  }

  @ViewBuilder
  func cepessaStatusButtonStyle(prominent: Bool) -> some View {
    if #available(macOS 26.0, *) {
      if prominent {
        self.buttonStyle(.glassProminent)
      } else {
        self.buttonStyle(.glass)
      }
    } else {
      if prominent {
        self.buttonStyle(.borderedProminent)
      } else {
        self.buttonStyle(.bordered)
      }
    }
  }
}
