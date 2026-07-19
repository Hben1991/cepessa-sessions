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
        .tint(CepessaColors.capture)
        .frame(minWidth: 560, minHeight: 480)
    }
  }
}

private final class CepessaSessionsAppDelegate: NSObject, NSApplicationDelegate {
  private var debugHookTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    CepessaSessionFloatingBarPreferences.installDefaults()
    let model = CepessaSessionsStore.shared.model
    CepessaSessionStatusBarController.shared.connect(model: model)
    CepessaSessionFloatingBarController.shared.connect(model: model)
    installDebugHooks()
  }

  /// Debug-only remote control for UI verification (agent test harnesses).
  /// Distributed notifications don't reach the app under the sandbox, so this
  /// watches for a marker file inside the app's own container instead. The
  /// path is printed at launch; writing the file toggles recording.
  private func installDebugHooks() {
    #if DEBUG
      let marker = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("debug-toggle-recording")
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
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func showSession(id: UUID) {
    CepessaSessionsStore.shared.model.selectSession(id: id)
    show(destination: .sessions)
  }

  func openSettings() {
    NSApp.activate(ignoringOtherApps: true)
    let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    if !opened {
      EnvironmentValues().openSettings()
    }
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
    Task {
      await CepessaSessionsStore.shared.model.importExistingRecording(from: url)
    }
  }

  private func ensureWindow() {
    guard window == nil else { return }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Cepessa Sessions"
    window.appearance = NSAppearance(named: .aqua)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 720, height: 520)
    window.center()
    window.setFrameAutosaveName("CepessaSessionsWindow")
    window.delegate = self

    let root = CepessaSessionsWindowRootView(state: state)
      .withFontScaling()
      .tint(CepessaColors.capture)
    window.contentView = NSHostingView(rootView: root)

    readingToolbar = CepessaSessionReadingToolbar(
      model: CepessaSessionsStore.shared.model, window: window)

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
      case .clips:
        LocalClipsPage()
          .ignoresSafeArea()
      }
    }
    .background(CepessaColors.backgroundPrimary)
  }
}
