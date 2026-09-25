import AppKit
import SwiftUI
import XCTest

@testable import CepessaSessions

/// Still renders of every surface for design review. Opt-in: set
/// `CEPESSA_RENDER_FIXTURES` to an output directory. Arrivals and reveals are
/// settled (`sessionsIsStill`), so a render shows the resting composition,
/// not a frame caught mid-motion. Nothing here reads real recordings.
@MainActor
final class SessionsFixtureRenderTests: XCTestCase {
  private var output: URL!
  private var root: URL!

  override func setUpWithError() throws {
    guard let path = ProcessInfo.processInfo.environment["CEPESSA_RENDER_FIXTURES"], !path.isEmpty
    else {
      throw XCTSkip("Set CEPESSA_RENDER_FIXTURES to render design fixtures.")
    }
    output = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SessionsFixtureRender-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = NSApplication.shared
    SessionsType.registerBundledFonts()
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testRenderCapsuleStates() throws {
    let controller = CepessaSessionFloatingBarController()
    func capsule(_ name: String, _ configure: (CepessaSessionFloatingBarState) -> Void) throws {
      let state = controller.state
      state.isRecording = false
      state.isTranscribing = false
      state.capturePhase = .idle
      state.errorMessage = nil
      state.noticeMessage = nil
      state.isCompact = false
      state.isMicrophoneMuted = false
      state.isMicrophoneCaptureActive = true
      state.isSystemAudioCaptureActive = true
      state.processingProgress = nil
      state.processingStage = nil
      configure(state)
      state.barContentSize = CepessaSessionCapsuleMetrics.contentSize(for: state.layout)
      state.panelContentSize = state.barContentSize
      let size = CepessaSessionCapsuleMetrics.panelSize(for: state.barContentSize)
      for (suffix, backdrop) in [("on-light", Color.white), ("on-dark", Color(hex: 0x2A2A2E))] {
        try render(
          ZStack {
            backdrop
            CepessaSessionCapsuleView(controller: controller, state: state)
          }
          .frame(width: size.width, height: size.height),
          size: size, name: "capsule-\(name)-\(suffix)")
      }
    }

    try capsule("idle") { _ in }
    try capsule("recording") {
      $0.isRecording = true
      $0.timerText = "00:12:41"
      $0.micLevel = 0.32
      $0.systemLevel = 0.12
    }
    try capsule("recording-muted") {
      $0.isRecording = true
      $0.timerText = "00:12:41"
      $0.isMicrophoneMuted = true
      $0.systemLevel = 0.2
    }
    try capsule("recording-folded") {
      $0.isRecording = true
      $0.isCompact = true
      $0.timerText = "01:02:09"
      $0.micLevel = 0.5
    }
    try capsule("recording-notice") {
      $0.isRecording = true
      $0.timerText = "00:04:07"
      $0.noticeMessage = "Region pinned at 04:07"
      $0.noticeStyle = .success
    }
    try capsule("processing") {
      $0.isTranscribing = true
      $0.processingProgress = 0.42
      $0.processingStage = "Separating speakers"
    }
    try capsule("attention") {
      $0.errorMessage = "The microphone is unavailable."
    }
  }

  func testRenderCapsuleMenu() throws {
    let items: [CepessaSessionCapsuleMenuItem] = [
      .header("Pin to this moment"),
      .action("Capture Whole Screen", symbol: "display") {},
      .action("Attach File…", symbol: "paperclip") {},
      .separator,
      .header("Recent"),
      .action("Product review with Dana", detail: "09:05") {},
      .action("סנכרון שבועי עם גילי", detail: "10:25") {},
      .separator,
      .action("All Sessions", symbol: "rectangle.stack", detail: "⌘O") {},
      .action("Import Audio…", symbol: "square.and.arrow.down") {},
      .separator,
      .action("Settings…", symbol: "gearshape", detail: "⌘,") {},
      .action("Hide Recorder", symbol: "eye.slash") {},
      .action("Quit Cepessa Sessions", symbol: "power") {},
    ]
    let view = CepessaSessionCapsuleMenuView(items: items) {}
      .padding(30)
      .background(Color.white)
    try render(view, size: CGSize(width: 330, height: 560), name: "capsule-menu")
  }

  func testRenderMenuBar() throws {
    let states: [(CepessaSessionStatusBarMode, Double?, String)] = [
      (.idle, nil, ""), (.recording, nil, " 12:41"), (.transcribing, 0.42, " 42%"),
      (.transcribing, nil, ""), (.failed, nil, ""),
    ]
    for (dark, name) in [(false, "light"), (true, "dark")] {
      let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
      let size = CGSize(width: 150, height: CGFloat(states.count) * 30 + 10)
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
      rep.size = size
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      appearance.performAsCurrentDrawingAppearance {
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, state) in states.enumerated() {
          let y = size.height - CGFloat(index + 1) * 30
          let glyph = CepessaSessionStatusBarGlyph.image(for: state.0, progress: state.1)
          let rect = NSRect(x: 12, y: y + 6, width: glyph.size.width, height: glyph.size.height)
          if glyph.isTemplate {
            let tinted = NSImage(size: glyph.size, flipped: false) { bounds in
              glyph.draw(in: bounds)
              NSColor.labelColor.set()
              bounds.fill(using: .sourceAtop)
              return true
            }
            tinted.draw(in: rect)
          } else {
            glyph.draw(in: rect)
          }
          NSAttributedString(
            string: state.2,
            attributes: [
              .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
              .foregroundColor: NSColor.labelColor,
            ]
          ).draw(at: NSPoint(x: rect.maxX + 2, y: y + 7))
        }
      }
      NSGraphicsContext.restoreGraphicsState()
      try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        .write(to: output.appendingPathComponent("menubar-\(name).png"))
    }

    let items: [CepessaSessionCapsuleMenuItem] = [
      .status(
        "Separating speakers", detail: "Session 25 Sep · the transcript is made on this Mac.",
        progress: 0.42, tone: .working),
      .separator,
      .action("Start Recording", symbol: "record.circle") {},
      .separator,
      .header("Recent"),
      .action("Product review with Dana", detail: "09:05") {},
      .action("סנכרון שבועי עם גילי", detail: "10:25") {},
      .separator,
      .action("All Sessions", symbol: "rectangle.stack", detail: "⌘O") {},
      .action("Import Audio…", symbol: "square.and.arrow.down") {},
      .separator,
      .action("Hide Recorder", symbol: "eye.slash") {},
      .action("Settings…", symbol: "gearshape", detail: "⌘,") {},
      .action("Quit Cepessa Sessions", symbol: "power") {},
    ]
    try render(
      CepessaSessionCapsuleMenuView(items: items) {}.padding(30).background(Color.white),
      size: CGSize(width: 360, height: 600), name: "menubar-menu")
  }

  func testRenderWindows() throws {
    let model = try fixtureModel()
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let suffix = appearance == .aqua ? "light" : "dark"
      try render(
        ZStack {
          SessionsAtmosphere()
          CepessaSessionLibraryView(model: model) { _ in }
        },
        size: CGSize(width: 1080, height: 780), name: "library-\(suffix)", appearance: appearance)

      for (index, session) in model.sessions.enumerated() {
        model.selectSession(id: session.id)
        try render(
          ZStack {
            SessionsAtmosphere()
            CepessaSessionReadingView(model: model) {}
          },
          size: CGSize(width: 1080, height: 900), name: "reader-\(index)-\(suffix)",
          appearance: appearance)
      }
    }
  }

  func testRenderSettings() throws {
    // The settings page reads the shared store; point it at an empty root
    // before anything creates it, so no real data is ever loaded.
    setenv("CEPESSA_SESSIONS_TEST_ROOT", root.path, 1)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      try render(
        CepessaSessionsSettingsPage(),
        size: CGSize(width: 560, height: 660),
        name: "settings-\(appearance == .aqua ? "light" : "dark")", appearance: appearance)
    }
  }

  // MARK: - Fixtures

  private func fixtureModel() throws -> LocalMeetingAppModel {
    let layout = LocalSessionFileLayout(baseDirectory: root)
    let model = LocalMeetingAppModel(store: LocalSessionStore(fileLayout: layout), fileLayout: layout)
    let now = Date()
    let calendar = Calendar.current
    let morning = calendar.date(bySettingHour: 9, minute: 5, second: 0, of: now) ?? now

    func segments(_ turns: [(String, String)], start: Date) -> [LocalSessionTranscriptSegment] {
      var time = start
      return turns.map { speaker, text in
        defer { time = time.addingTimeInterval(9) }
        return LocalSessionTranscriptSegment(
          id: UUID(), speaker: speaker, text: text, timestamp: time,
          endTimestamp: time.addingTimeInterval(7), speakerID: speaker)
      }
    }

    let english = LocalSession(
      id: UUID(), title: "Product review with Dana", startedAt: morning, status: .ready,
      transcriptSegments: segments(
        [
          (
            "Ben",
            "Okay, let's start with the recorder. The floating bar was too small; people didn't find the stop button during calls."
          ),
          (
            "Ben",
            "The new capsule keeps mute, capture and stop in one row while you record, and folds away when you don't need it."
          ),
          ("Dana", "I like that the orb actually reacts to the room. Is that real audio or decoration?"),
          ("Ben", "Real. It follows the measured microphone and system levels, nothing else."),
          ("Dana", "Good. Then let's ship it to the team on Monday and collect notes for a week."),
        ], start: morning),
      audioArtifacts: .empty)
    let hebrew = LocalSession(
      id: UUID(), title: "סנכרון שבועי עם גילי", startedAt: morning.addingTimeInterval(4800),
      status: .ready,
      transcriptSegments: segments(
        [
          ("בן", "בוא נתחיל מהלקוחות החדשים. יש לנו שלוש פגישות השבוע ואני רוצה שנגיע אליהן עם תמלולים מסודרים."),
          ("גילי", "מסכים. מה שחשוב לי זה שנוכל לחפש בתוך השיחות הקודמות לפני כל פגישה."),
          ("בן", "החיפוש כבר עובד על כל הכותרות והתמלולים. נשאר רק לחבר את זה לספסה."),
        ], start: morning.addingTimeInterval(4800)),
      audioArtifacts: .empty)
    var failed = LocalSession(
      id: UUID(), title: "Onboarding call",
      startedAt: calendar.date(byAdding: .day, value: -1, to: morning) ?? morning,
      status: .failed, transcriptSegments: [], audioArtifacts: .empty)
    failed.processingError = "The Hebrew speech model could not be loaded on this Mac."

    // The English session carries real audio and a pinned screenshot, so the
    // player and the attachments render with content.
    var withMedia = english
    try layout.ensureDirectories(for: withMedia.id)
    let writer = try LocalMeetingWaveFileWriter(fileURL: layout.micAudioURL(for: withMedia.id))
    try writer.append(samples: [Int16](repeating: 0, count: 16_000 * 42))
    try writer.close()
    withMedia.audioArtifacts = LocalSessionAudioArtifacts(
      micFileName: "mic.wav", systemFileName: nil, mixedFileName: nil)
    let iconURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Branding/AppIcon-1024.png")
    let screenshotURL = layout.attachmentsDirectory(for: withMedia.id)
      .appendingPathComponent("screen-demo.png")
    try FileManager.default.copyItem(at: iconURL, to: screenshotURL)
    let pinnedAt = morning.addingTimeInterval(10)
    let attachment = LocalSessionAttachment(
      id: UUID(), kind: .image, source: .floatingBar, title: "Screenshot", timestamp: pinnedAt,
      sessionOffset: 10, fileName: "screen-demo.png", mimeType: "image/png",
      urlString: screenshotURL.path, note: nil)
    withMedia.attachments = [attachment]
    withMedia.captureArtifacts = [
      LocalSessionCaptureArtifact(
        id: UUID(), kind: .screenCapture, title: "Screenshot", capturedAt: pinnedAt,
        sessionOffset: 10, attachmentIDs: [attachment.id], notes: nil)
    ]

    for session in [failed, withMedia, hebrew] {
      model.upsertSession(session)
    }
    return model
  }

  // MARK: - Rendering

  private func render<V: View>(
    _ view: V, size: CGSize, name: String, appearance: NSAppearance.Name = .aqua
  ) throws {
    let hosting = NSHostingView(
      rootView: view
        .environment(\.sessionsIsStill, true)
        .frame(width: size.width, height: size.height))
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentView = hosting
    window.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    hosting.layoutSubtreeIfNeeded()

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      return XCTFail("no bitmap for \(name)")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    try data.write(to: output.appendingPathComponent("\(name).png"))
  }
}
