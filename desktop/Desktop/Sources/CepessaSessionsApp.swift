import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Cepessa Sessions is a floating-bar-first accessory app: no dock icon, no
/// window at launch. The floating bar and the status bar item are the app;
/// the sessions window and Settings open on demand from their menus.
@main
struct CepessaSessionsApp: App {
  @NSApplicationDelegateAdaptor(CepessaSessionsAppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      CepessaSessionsSettingsPage()
        .withFontScaling()
        .frame(minWidth: 520, minHeight: 440)
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          CepessaSessionsWindowController.shared.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
      }

      CommandMenu("Sessions") {
        Button("Browse All Sessions…") {
          CepessaSessionsWindowController.shared.showLibrary()
        }
        .keyboardShortcut("o", modifiers: .command)

        Button("Import Audio…") {
          CepessaSessionsWindowController.shared.importAudio()
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])

        Divider()

        Button("Show Clips") {
          CepessaSessionsWindowController.shared.show(destination: .clips)
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
      }
    }
  }
}

private final class CepessaSessionsAppDelegate: NSObject, NSApplicationDelegate {
  private var debugHookTimer: Timer?
  private var terminationPending = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    CepessaSessionFloatingBarPreferences.installDefaults()
    let model = CepessaSessionsStore.shared.model
    CepessaSessionStatusBarController.shared.connect(model: model)
    CepessaSessionFloatingBarController.shared.connect(model: model)
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
      await store.clipModel.finishCaptureForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Debug-only remote control for UI verification (agent test harnesses).
  /// Distributed notifications don't reach the app under the sandbox, so this
  /// watches for a marker file inside the app's own container instead. The
  /// path is printed at launch; writing the file toggles recording.
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

// MARK: - Session window (on demand)

enum CepessaSessionsWindowDestination {
  case sessions
  case clips
}

@MainActor
final class CepessaSessionsWindowState: ObservableObject {
  @Published var destination: CepessaSessionsWindowDestination = .sessions
}

@MainActor
final class CepessaSessionsWindowController: NSObject, NSWindowDelegate {
  static let shared = CepessaSessionsWindowController()

  let state = CepessaSessionsWindowState()

  private var window: NSWindow?
  private var readingToolbar: CepessaSessionReadingToolbar?

  func show(destination: CepessaSessionsWindowDestination? = nil) {
    if let destination {
      state.destination = destination
    }
    ensureWindow()
    refreshWindowChrome()
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func showSession(id: UUID) {
    CepessaSessionsStore.shared.model.selectSession(id: id)
    show(destination: .sessions)
  }

  func showLibrary() {
    show(destination: .sessions)
    CepessaSessionsStore.shared.model.isSessionLibraryPresented = true
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
    panel.message = "Choose an audio file to normalize locally and transcribe on this Mac."

    guard panel.runModal() == .OK, let url = panel.url else { return }
    show(destination: .sessions)
    Task {
      await CepessaSessionsStore.shared.model.importExistingRecording(from: url)
    }
  }

  private func ensureWindow() {
    guard window == nil else { return }

    // Standard titled window: system title bar, traffic lights, toolbar and
    // resizing behave exactly as macOS users expect, and the window follows
    // the system appearance instead of being pinned to light.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Cepessa Sessions"
    window.titlebarAppearsTransparent = false
    window.titleVisibility = .visible
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 720, height: 520)
    window.center()
    window.setFrameAutosaveName("CepessaSessionsWindow")
    window.delegate = self

    let root = CepessaSessionsWindowRootView(state: state)
      .withFontScaling()
    window.contentView = NSHostingView(rootView: root)

    readingToolbar = CepessaSessionReadingToolbar(
      model: CepessaSessionsStore.shared.model, window: window)

    self.window = window
    refreshWindowChrome()
  }

  private func refreshWindowChrome() {
    let showsSessions = state.destination == .sessions
    window?.title = showsSessions ? "Cepessa Sessions" : "Cepessa Clips"
    readingToolbar?.setVisible(showsSessions)
  }

  /// SwiftUI's NavigationSplitView installs its own toolbar while Clips is
  /// visible. Restore the retained reader toolbar after that hierarchy has
  /// finished leaving the window, and only if Sessions is still selected.
  func restoreReadingToolbarAfterTransition() {
    guard state.destination == .sessions else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.state.destination == .sessions else { return }
      self.refreshWindowChrome()
    }
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
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Sessions Settings"
    window.titlebarAppearsTransparent = false
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 520, height: 440)
    window.center()
    window.setFrameAutosaveName("CepessaSessionsSettingsWindow")
    window.delegate = self
    window.contentView = NSHostingView(
      rootView: CepessaSessionsSettingsPage()
        .withFontScaling()
        .frame(minWidth: 520, minHeight: 440)
    )
    self.window = window
  }
}

private struct CepessaSessionsWindowRootView: View {
  @ObservedObject var state: CepessaSessionsWindowState

  var body: some View {
    Group {
      switch state.destination {
      case .sessions:
        CepessaSessionReadingView()
          .onAppear {
            CepessaSessionsWindowController.shared.restoreReadingToolbarAfterTransition()
          }
      case .clips:
        LocalClipsPage()
      }
    }
    .background(CepessaColors.backgroundPrimary)
  }
}
