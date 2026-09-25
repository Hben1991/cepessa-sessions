import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Cepessa Sessions is a recorder first: no Dock icon, no window at launch.
/// The floating capsule and the menu-bar item are the app; the sessions
/// window and Settings open on demand from their menus.
@main
struct CepessaSessionsApp: App {
  @NSApplicationDelegateAdaptor(CepessaSessionsAppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      CepessaSessionsSettingsPage()
        .frame(width: 560, height: 620)
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          CepessaSessionsWindowController.shared.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
      }

      CommandMenu("Sessions") {
        Button("All Sessions") {
          CepessaSessionsWindowController.shared.showLibrary()
        }
        .keyboardShortcut("o", modifiers: .command)

        Button("Import Audio…") {
          CepessaSessionsWindowController.shared.importAudio()
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])

        Divider()

        Button("Export Transcript…") {
          CepessaSessionsWindowController.shared.exportSelectedTranscript()
        }
        .keyboardShortcut("e", modifiers: .command)
      }
    }
  }
}

private final class CepessaSessionsAppDelegate: NSObject, NSApplicationDelegate {
  private var debugHookTimer: Timer?
  private var terminationPending = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    SessionsType.registerBundledFonts()
    CepessaSessionFloatingBarPreferences.installDefaults()
    let model = CepessaSessionsStore.shared.model
    CepessaSessionStatusBarController.shared.connect(model: model)
    CepessaSessionFloatingBarController.shared.connect(model: model)
    // Install the Hebrew speech model up front when no usable transcription model exists, so
    // the first recording can be transcribed. A model already on disk is verified, not fetched.
    let transcriptionModels = model.transcriptionModelProvisioner
    if !transcriptionModels.hasUsableModel {
      transcriptionModels.prepareIfNeeded()
    }
    installDebugHooks()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    CepessaSessionsStore.shared.model.refreshLibraryIfIdle()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let store = CepessaSessionsStore.shared
    guard store.captureLifecycle.isBusy else { return .terminateNow }
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    Task { @MainActor in
      await store.model.finishCaptureForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Debug-only remote control for UI verification (agent test harnesses).
  /// Writing the marker file toggles recording; the path is printed at launch.
  private func installDebugHooks() {
    #if DEBUG
      let configuredMarker = ProcessInfo.processInfo.environment[
        "CEPESSA_SESSIONS_DEBUG_TOGGLE_MARKER"
      ]?.trimmingCharacters(in: .whitespacesAndNewlines)
      let marker =
        if let configuredMarker, !configuredMarker.isEmpty {
          URL(fileURLWithPath: configuredMarker)
        } else {
          URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("debug-toggle-recording")
        }
      NSLog("[cepessa-debug] toggle recording by touching: \(marker.path)")

      debugHookTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.removeItem(at: marker)
        Task { @MainActor in
          CepessaSessionsStore.shared.model.toggleRecording()
        }
      }
    #endif
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    if !flag {
      CepessaSessionsWindowController.shared.show()
    }
    return true
  }
}

// MARK: - Sessions window (on demand)

/// Where the sessions window is: the library of every recording, or one
/// recording being read.
@MainActor
final class CepessaSessionsWindowState: ObservableObject {
  enum Place: Equatable {
    case library
    case session
  }

  @Published var place: Place = .library
}

@MainActor
final class CepessaSessionsWindowController: NSObject, NSWindowDelegate {
  static let shared = CepessaSessionsWindowController()

  let state = CepessaSessionsWindowState()

  private var window: NSWindow?
  private let exporter = LocalSessionRecapExporter()

  func show() {
    ensureWindow()
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func showSession(id: UUID) {
    CepessaSessionsStore.shared.model.selectSession(id: id)
    state.place = .session
    show()
  }

  func showLibrary() {
    state.place = .library
    show()
    CepessaSessionsStore.shared.model.refreshLibraryIfIdle()
  }

  func openSettings() {
    CepessaSessionsSettingsWindowController.shared.show()
  }

  func importAudio() {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.audio]
    panel.prompt = "Transcribe"
    panel.message = "Choose a recording to transcribe on this Mac."

    guard panel.runModal() == .OK, let url = panel.url else { return }
    state.place = .session
    show()
    Task {
      await CepessaSessionsStore.shared.model.importExistingRecording(from: url)
    }
  }

  /// Saves the open session's transcript as Markdown.
  func exportSelectedTranscript() {
    guard state.place == .session,
      let session = CepessaSessionsStore.shared.model.selectedSession,
      !session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      NSSound.beep()
      return
    }
    show()
    guard let window else { return }

    let panel = NSSavePanel()
    panel.title = "Export Transcript"
    panel.nameFieldStringValue =
      LocalSessionRecapMarkdownDocument.title(for: session, language: .english) + " Transcript.md"
    if let markdownType = UTType(filenameExtension: "md") {
      panel.allowedContentTypes = [markdownType]
    }

    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let destination = panel.url, let self else { return }
      do {
        _ = try self.exporter.exportTranscriptMarkdown(session: session, toFile: destination)
      } catch {
        let alert = NSAlert(error: error)
        alert.messageText = "The transcript could not be exported"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
      }
    }
  }

  private func ensureWindow() {
    guard window == nil else { return }

    // Full-size content with a transparent title bar: the atmosphere runs to
    // the top edge and the traffic lights sit on it, while resizing, full
    // screen and the window menu behave exactly as macOS users expect.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Cepessa Sessions"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 760, height: 560)
    window.center()
    window.setFrameAutosaveName("CepessaSessionsWindow")
    window.delegate = self
    window.backgroundColor = .windowBackgroundColor

    window.contentView = NSHostingView(
      rootView: CepessaSessionsWindowRootView(
        state: state, model: CepessaSessionsStore.shared.model))

    self.window = window
  }
}

@MainActor
final class CepessaSessionsSettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = CepessaSessionsSettingsWindowController()

  private var window: NSWindow?

  func show() {
    ensureWindow()
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  private func ensureWindow() {
    guard window == nil else { return }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Sessions Settings"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameAutosaveName("CepessaSessionsSettingsWindow")
    window.delegate = self
    window.contentView = NSHostingView(rootView: CepessaSessionsSettingsPage())
    self.window = window
  }
}

private struct CepessaSessionsWindowRootView: View {
  @ObservedObject var state: CepessaSessionsWindowState
  @ObservedObject var model: LocalMeetingAppModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      SessionsAtmosphere()

      Group {
        switch resolvedPlace {
        case .library:
          CepessaSessionLibraryView(model: model) { id in
            model.selectSession(id: id)
            state.place = .session
          }
          .transition(.sessionsRecede(reduceMotion: reduceMotion))
        case .session:
          CepessaSessionReadingView(model: model) {
            state.place = .library
          }
          .transition(.sessionsRecede(reduceMotion: reduceMotion))
        }
      }
      .animation(reduceMotion ? nil : SessionsMotion.depart, value: resolvedPlace)
    }
    .frame(minWidth: 760, minHeight: 560)
    .onChange(of: model.isSessionLibraryPresented) { _, isPresented in
      // The toolbar-era flag still arrives from older call sites.
      guard isPresented else { return }
      state.place = .library
      model.isSessionLibraryPresented = false
    }
  }

  /// A reader with nothing selected has nothing to read; the library is the
  /// honest place to be.
  private var resolvedPlace: CepessaSessionsWindowState.Place {
    if state.place == .session, model.selectedSession != nil { return .session }
    return .library
  }
}
