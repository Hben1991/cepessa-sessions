import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CepessaStorageSettingsModel: ObservableObject {
  @Published private(set) var sessionsBytes: Int64 = 0
  @Published private(set) var cleanupMessage: String?

  private let fileManager: FileManager
  let sessionsRoot: URL

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let storageRoot = LocalSessionStorageRoot.defaultBaseDirectory
    self.sessionsRoot = storageRoot.appendingPathComponent("Sessions", isDirectory: true)
    refresh()
  }

  var sessionsSizeText: String { Self.byteCountFormatter.string(fromByteCount: sessionsBytes) }

  func refresh() {
    sessionsBytes = directorySize(at: sessionsRoot)
  }

  func clearSessions() {
    clearContents(of: sessionsRoot, label: "sessions")
  }

  func reportCleanupBlocked() {
    cleanupMessage =
      "Finish active capture and local processing before deleting stored recordings."
  }

  private func clearContents(of directory: URL, label: String) {
    do {
      guard fileManager.fileExists(atPath: directory.path) else {
        cleanupMessage = "No \(label) storage to clear."
        refresh()
        return
      }
      let children = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
      for child in children {
        try fileManager.removeItem(at: child)
      }
      cleanupMessage = "Cleared \(label) storage."
    } catch {
      cleanupMessage = "Could not clear \(label): \(error.localizedDescription)"
    }
    refresh()
  }

  private func directorySize(at root: URL) -> Int64 {
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        values.isRegularFile == true
      else {
        continue
      }
      total += Int64(values.fileSize ?? 0)
    }
    return total
  }

  private static let byteCountFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter
  }()
}

/// Which irreversible storage action the user has asked for. Clearing local
/// recordings is the only destructive thing this app can do, so it never
/// happens on a single click — the button arms a confirmation dialog that
/// names exactly what is about to be deleted.
private enum CepessaStorageCleanupRequest: String, Identifiable {
  case sessions

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sessions: return "Delete all local sessions?"
    }
  }

  var message: String {
    switch self {
    case .sessions:
      return
        "Every recording, transcript, and attachment in the Sessions folder is removed from this Mac. This cannot be undone."
    }
  }

  var confirmTitle: String {
    switch self {
    case .sessions: return "Delete Sessions"
    }
  }
}

/// Settings: a native grouped form — real pickers, toggles and keyboard
/// behaviour — set on the same sky as the sessions window, under one line
/// in the display face.
struct CepessaSessionsSettingsPage: View {
  @StateObject private var storageModel = CepessaStorageSettingsModel()
  @ObservedObject private var sessionModel = CepessaSessionsStore.shared.model
  @ObservedObject private var speakerModels =
    CepessaSessionsStore.shared.model.speakerModelProvisioner
  @ObservedObject private var transcriptionModels =
    CepessaSessionsStore.shared.model.transcriptionModelProvisioner
  @ObservedObject private var captureLifecycle = CepessaSessionsStore.shared.captureLifecycle
  @AppStorage("cepessa.sessions.preferredTranscriptLanguage") private var transcriptLanguage =
    "Mixed"
  @AppStorage("cepessa.sessions.transcriptionSpeedMode") private var transcriptionSpeedMode =
    "Balanced"
  @AppStorage(CepessaSessionFloatingBarPreferences.enabledKey) private var floatingBarEnabled =
    true
  @State private var cleanupRequest: CepessaStorageCleanupRequest?
  @State private var microphonePermissionGranted =
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  @State private var screenRecordingPermissionGranted = CGPreflightScreenCaptureAccess()

  var body: some View {
    ZStack(alignment: .top) {
      SessionsAtmosphere()
      VStack(alignment: .leading, spacing: 0) {
        SessionsRevealedLine(
          text: "Settings",
          font: SessionsType.display(34),
          tracking: 34 * -0.018
        )
        .padding(.horizontal, 28)
        .padding(.top, 46)
        .accessibilityAddTraits(.isHeader)

        Form {
          captureSection
          transcriptionSection
          speakerRecognitionSection
          cloudAnalysisSection
          permissionsSection
          storageSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
      }
    }
    .onAppear {
      CepessaSessionFloatingBarController.shared.connect(model: CepessaSessionsStore.shared.model)
      CepessaSessionStatusBarController.shared.connect(model: CepessaSessionsStore.shared.model)
      storageModel.refresh()
      transcriptionModels.refreshState()
      refreshPermissions()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in
      refreshPermissions()
    }
    .onChange(of: transcriptLanguage) { _, _ in transcriptionModels.refreshState() }
    .onChange(of: transcriptionSpeedMode) { _, _ in transcriptionModels.refreshState() }
    .onChange(of: floatingBarEnabled) { _, _ in
      CepessaSessionFloatingBarController.shared.connect(model: CepessaSessionsStore.shared.model)
    }
    .confirmationDialog(
      cleanupRequest?.title ?? "",
      isPresented: Binding(
        get: { cleanupRequest != nil },
        set: { if !$0 { cleanupRequest = nil } }
      ),
      presenting: cleanupRequest
    ) { request in
      Button(request.confirmTitle, role: .destructive) { performCleanup(request) }
      Button("Cancel", role: .cancel) {}
    } message: { request in
      Text(request.message)
    }
  }

  // MARK: - Sections

  private var captureSection: some View {
    Section {
      Picker("Transcript language", selection: $transcriptLanguage) {
        Text("Mixed").tag("Mixed")
        Text("Hebrew-first").tag("Hebrew-first")
        Text("English-first").tag("English-first")
      }

      Picker("Transcription speed", selection: $transcriptionSpeedMode) {
        Text("Fast draft").tag("Fast draft")
        Text("Balanced").tag("Balanced")
        Text("Most accurate").tag("Most accurate")
      }

      Toggle("Show the floating recorder", isOn: $floatingBarEnabled)
    } header: {
      Text("Capture")
    } footer: {
      Text(
        "Fast draft uses lighter local models when available. A language choice adds a hint while keeping bilingual detection on. The menu bar always shows recording and transcription progress, even with the recorder hidden."
      )
    }
  }

  private var cloudAnalysisSection: some View {
    CloudAnalysisSettingsSection()
  }

  private var permissionsSection: some View {
    Section("Permissions") {
      permissionRow(
        title: "Microphone",
        isGranted: microphonePermissionGranted,
        openAnchor: "Privacy_Microphone"
      )
      permissionRow(
        title: "Screen Recording",
        isGranted: screenRecordingPermissionGranted,
        openAnchor: "Privacy_ScreenCapture"
      )
    }
  }

  private var transcriptionSection: some View {
    Section {
      LabeledContent("Hebrew speech model") {
        HStack(spacing: 8) {
          if case .downloading(let progress) = transcriptionModels.state {
            ProgressView(value: progress)
              .frame(width: 92)
            Text("Downloading · \(Int((progress * 100).rounded()))%")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          } else {
            Text(hebrewModelStatus)
              .foregroundStyle(.secondary)
          }

          if canInstallHebrewModel {
            Button("Install") { transcriptionModels.installHebrewModel() }
          } else if case .failed = transcriptionModels.state {
            Button("Retry") { transcriptionModels.retry() }
          }
        }
      }

      if let activeModel = transcriptionModels.activeModel, activeModel.kind == .other {
        Text("Transcribing with \(activeModel.displayName) on this Mac.")
          .font(SessionsType.text(12))
          .foregroundStyle(SessionsPalette.inkTertiary)
      }

      if case .failed(let message) = transcriptionModels.state {
        Text(message)
          .font(SessionsType.text(12))
          .foregroundStyle(SessionsPalette.attention)
      }
    } header: {
      Text("Transcription")
    } footer: {
      Text(
        "Installs automatically the first time it’s needed (about 1.6 GB, once). Transcription runs on this Mac; audio never leaves it."
      )
    }
  }

  private var hebrewModelStatus: String {
    switch transcriptionModels.state {
    case .notInstalled: return "Not installed"
    case .downloading: return "Downloading"
    case .verifying: return "Verifying"
    case .ready:
      return transcriptionModels.isHebrewModelInstalled ? "Ready on this Mac" : "Not installed"
    case .failed: return "Needs attention"
    }
  }

  /// Install stays available while another model does the transcribing.
  private var canInstallHebrewModel: Bool {
    switch transcriptionModels.state {
    case .notInstalled: return true
    case .ready: return !transcriptionModels.isHebrewModelInstalled
    case .downloading, .verifying, .failed: return false
    }
  }

  private var speakerRecognitionSection: some View {
    Section {
      LabeledContent("Local models") {
        HStack(spacing: 8) {
          if case .downloading(let progress) = speakerModels.state {
            ProgressView(value: progress)
              .frame(width: 92)
            Text("\(Int((progress * 100).rounded()))%")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          } else {
            Text(speakerModelStatus)
              .foregroundStyle(.secondary)
          }

          switch speakerModels.state {
          case .notInstalled:
            Button("Install") { speakerModels.prepareIfNeeded() }
          case .failed:
            Button("Retry") { speakerModels.retry() }
          case .downloading, .verifying, .ready:
            EmptyView()
          }
        }
      }

      if case .failed(let message) = speakerModels.state {
        Text(message)
          .font(SessionsType.text(12))
          .foregroundStyle(SessionsPalette.attention)
      }
    } header: {
      Text("Speaker Separation")
    } footer: {
      Text(
        "Download the models once to separate speakers on this Mac. Your recording stays local."
      )
    }
  }

  private var speakerModelStatus: String {
    switch speakerModels.state {
    case .notInstalled: return "Not installed"
    case .downloading: return "Downloading"
    case .verifying: return "Verifying"
    case .ready: return "Ready on this Mac"
    case .failed: return "Needs attention"
    }
  }

  private var storageSection: some View {
    Section {
      storageRow(
        title: "Sessions", path: storageModel.sessionsRoot, size: storageModel.sessionsSizeText)
      storageRow(title: "Models", path: modelsRoot, size: nil)

      Button("Recalculate") { storageModel.refresh() }

      if let cleanupMessage = storageModel.cleanupMessage {
        Text(cleanupMessage)
          .font(SessionsType.text(12))
          .foregroundStyle(SessionsPalette.inkTertiary)
      }

      // Destructive actions live below a divider, are red, and are the only
      // controls in the pane that open a confirmation.
      Button("Delete All Sessions…", role: .destructive) { cleanupRequest = .sessions }
        .disabled(isStorageCleanupBlocked)
        .help(
          isStorageCleanupBlocked
            ? "Finish active capture and local processing before deleting sessions."
            : "Delete every local session after confirmation."
        )
    } header: {
      Text("Local Storage")
    } footer: {
      Text("Recordings, transcripts, and attachments stay on this Mac.")
    }
  }

  // MARK: - Rows

  private func permissionRow(title: String, isGranted: Bool, openAnchor: String) -> some View {
    LabeledContent(title) {
      HStack(spacing: 8) {
        if isGranted {
          Text("Granted")
            .foregroundStyle(.secondary)
        } else {
          Label {
            Text("Not granted")
              .foregroundStyle(SessionsPalette.ink)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(SessionsPalette.attention)
          }
        }

        Button("Open…") { openSystemSettings(anchor: openAnchor) }
          .accessibilityLabel("Open \(title) privacy settings")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityValue(isGranted ? "Granted" : "Not granted")
  }

  private func storageRow(title: String, path: URL, size: String?) -> some View {
    LabeledContent {
      HStack(spacing: 8) {
        if let size {
          Text(size)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([path])
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help(path.path)
        .accessibilityLabel("Reveal \(title) folder in Finder")
      }
    } label: {
      Text(title)
    }
    .accessibilityElement(children: .contain)
  }

  // MARK: - Actions

  private func performCleanup(_ request: CepessaStorageCleanupRequest) {
    guard !isStorageCleanupBlocked else {
      storageModel.reportCleanupBlocked()
      cleanupRequest = nil
      return
    }

    switch request {
    case .sessions:
      storageModel.clearSessions()
      CepessaSessionsStore.shared.model.loadStoredSessions()
    }
    cleanupRequest = nil
  }

  private var modelsRoot: URL {
    fileLayout.modelsDirectory
  }

  private var isStorageCleanupBlocked: Bool {
    captureLifecycle.isBusy
      || sessionModel.isTranscribing
      || !sessionModel.processingSnapshots.isEmpty
  }

  private var fileLayout: LocalMeetingFileLayout {
    LocalMeetingFileLayout(baseDirectory: LocalSessionStorageRoot.defaultBaseDirectory)
  }

  private func openSystemSettings(anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func refreshPermissions() {
    microphonePermissionGranted =
      AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    screenRecordingPermissionGranted = CGPreflightScreenCaptureAccess()
  }
}
