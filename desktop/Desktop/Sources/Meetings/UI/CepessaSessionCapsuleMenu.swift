import AppKit
import SwiftUI

/// One entry in the capsule's menu.
struct CepessaSessionCapsuleMenuItem: Identifiable {
  enum Kind {
    case action(symbol: String?, title: String, detail: String?, isEnabled: Bool, handler: () -> Void)
    case header(String)
    case separator
    /// What Sessions is doing, at the top of the menu-bar menu.
    case status(title: String, detail: String?, progress: Double?, tone: StatusTone)
  }

  enum StatusTone {
    case quiet, recording, working, attention
  }

  /// Stable for an action (its title), so a menu rebuilt while open — the
  /// menu-bar menu, every timer tick — keeps the highlighted row.
  let id: String
  let kind: Kind

  private init(kind: Kind, id: String = UUID().uuidString) {
    self.kind = kind
    self.id = id
  }

  /// `key` tells apart rows that can share a title, such as two sessions.
  static func action(
    _ title: String, symbol: String? = nil, detail: String? = nil, isEnabled: Bool = true,
    key: String? = nil, handler: @escaping () -> Void
  ) -> Self {
    Self(
      kind: .action(symbol: symbol, title: title, detail: detail, isEnabled: isEnabled, handler: handler),
      id: "action:\(key ?? title)")
  }

  static func status(
    _ title: String, detail: String?, progress: Double? = nil, tone: StatusTone
  ) -> Self {
    Self(kind: .status(title: title, detail: detail, progress: progress, tone: tone), id: "status")
  }

  static func header(_ title: String) -> Self { Self(kind: .header(title), id: "header:\(title)") }
  /// A new one each time: every row, separators included, needs its own id.
  static var separator: Self { Self(kind: .separator) }

  var isSelectable: Bool {
    if case .action(_, _, _, let isEnabled, _) = kind { return isEnabled }
    return false
  }
}

/// The capsule's menu, made of the same night as the capsule: a dark glass
/// sheet that hangs from it, rows lit with the orb's gold on hover, and full
/// keyboard control (↑ ↓ Return Esc). It closes on a choice, on Escape, on a
/// click anywhere else, or when the app steps back.
@MainActor
final class CepessaSessionCapsuleMenuController {
  static let shared = CepessaSessionCapsuleMenuController()

  private var panel: CepessaSessionCapsuleMenuPanel?
  private var hosting: NSHostingView<CepessaSessionCapsuleMenuView>?
  private var onClose: (() -> Void)?
  private var outsideClickMonitor: Any?
  private var localClickMonitor: Any?

  private var closedByClickAt = Date.distantPast

  var isOpen: Bool { panel?.isVisible == true }
  var currentPanel: NSPanel? { panel }

  /// A click outside closes the menu before the control under it sees the
  /// click. When that control is the one that opened the menu, the click
  /// meant "close", not "open again".
  var wasJustClosedByClick: Bool {
    Date().timeIntervalSince(closedByClickAt) < 0.4
  }

  /// Opens the menu under (or, near the bottom of a screen, over) `anchor`,
  /// a rectangle in screen coordinates — normally the capsule.
  func open(
    items: [CepessaSessionCapsuleMenuItem], below anchor: NSRect, alignLeading: Bool = false,
    onClose: (() -> Void)? = nil
  ) {
    close()

    let panel = CepessaSessionCapsuleMenuPanel(
      contentRect: NSRect(x: 0, y: 0, width: CepessaSessionCapsuleMenuView.width, height: 10),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

    let hosting = NSHostingView(
      rootView: CepessaSessionCapsuleMenuView(items: items) { [weak self] in self?.close() })
    let size = hosting.fittingSize
    panel.contentView = hosting
    self.hosting = hosting
    self.onClose = onClose

    let screen =
      NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
      ?? NSScreen.screens.first
    let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -400, dy: -400)
    var origin = NSPoint(
      x: alignLeading ? anchor.minX : anchor.maxX - size.width,
      y: anchor.minY - 6 - size.height)
    if origin.y < visible.minY {
      origin.y = anchor.maxY + 6
    }
    origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
    panel.setFrame(NSRect(origin: origin, size: size), display: true)

    panel.onResignKey = { [weak self] in self?.close() }
    self.panel = panel
    panel.alphaValue = 0
    panel.makeKeyAndOrderFront(nil)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
      panel.animator().alphaValue = 1
    }

    // Each close is for this menu only: a click that opens the next menu
    // (a right-click on the capsule) must not be closed by this one's
    // queued close.
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self, weak panel] _ in
      Task { @MainActor in self?.closeAfterClick(panel) }
    }
    localClickMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self, weak panel] event in
      if event.window !== panel {
        self?.closedByClickAt = Date()
        Task { @MainActor in self?.closeAfterClick(panel) }
      }
      return event
    }
  }

  func closeAfterClick(_ opened: NSPanel?) {
    guard let opened, opened === panel, isOpen else { return }
    closedByClickAt = Date()
    close()
  }

  /// Replaces the open menu's rows in place, keeping its top edge.
  func update(items: [CepessaSessionCapsuleMenuItem]) {
    guard let panel, let hosting else { return }
    hosting.rootView = CepessaSessionCapsuleMenuView(items: items) { [weak self] in self?.close() }
    let size = hosting.fittingSize
    guard size.height != panel.frame.height else { return }
    panel.setFrame(
      NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height),
      display: true)
  }

  func close() {
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    outsideClickMonitor = nil
    localClickMonitor = nil
    guard let panel else { return }
    self.panel = nil
    hosting = nil
    panel.onResignKey = nil
    panel.orderOut(nil)
    let onClose = self.onClose
    self.onClose = nil
    onClose?()
  }
}

final class CepessaSessionCapsuleMenuPanel: NSPanel {
  var onResignKey: (() -> Void)?

  override var canBecomeKey: Bool { true }

  override func resignKey() {
    super.resignKey()
    onResignKey?()
  }
}

struct CepessaSessionCapsuleMenuView: View {
  static let width: CGFloat = 300

  let items: [CepessaSessionCapsuleMenuItem]
  let dismiss: () -> Void

  @State private var highlighted: String?
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(items) { item in
        row(item)
      }
    }
    .padding(6)
    .frame(width: Self.width)
    .sessionsNightGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .padding(.horizontal, 0)
    .environment(\.colorScheme, .dark)
    .focusable()
    .focusEffectDisabled()
    .focused($isFocused)
    .onAppear { isFocused = true }
    .onKeyPress(.downArrow) { move(1); return .handled }
    .onKeyPress(.upArrow) { move(-1); return .handled }
    .onKeyPress(.return) { activateHighlighted(); return .handled }
    .onKeyPress(.escape) { dismiss(); return .handled }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
    .accessibilityLabel("Sessions menu")
  }

  @ViewBuilder
  private func row(_ item: CepessaSessionCapsuleMenuItem) -> some View {
    switch item.kind {
    case .separator:
      Rectangle()
        .fill(SessionsNight.hairline)
        .frame(height: 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .accessibilityHidden(true)
    case .status(let title, let detail, let progress, let tone):
      SessionsMenuStatusRow(title: title, detail: detail, progress: progress, tone: tone)
    case .header(let title):
      Text(title.uppercased())
        .font(SessionsType.text(10.5, weight: .semibold))
        .tracking(1.2)
        .foregroundStyle(SessionsNight.inkQuiet)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .accessibilityAddTraits(.isHeader)
    case .action(let symbol, let title, let detail, let isEnabled, let handler):
      let isLit = highlighted == item.id && isEnabled
      Button {
        dismiss()
        handler()
      } label: {
        HStack(spacing: 10) {
          Image(systemName: symbol ?? "circle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isLit ? SessionsPalette.sunriseGold : SessionsNight.inkSecondary)
            .frame(width: 18)
            .opacity(symbol == nil ? 0 : 1)
          Text(LocalTranscriptTextDirection.displayText(title))
            .font(SessionsType.text(13.5, weight: .medium))
            .foregroundStyle(isEnabled ? SessionsNight.ink : SessionsNight.inkQuiet)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 8)
          if let detail {
            Text(detail)
              .font(SessionsType.figure(11.5))
              .foregroundStyle(SessionsNight.inkQuiet)
          }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isLit ? SessionsPalette.sunriseGold.opacity(0.16) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      .buttonStyle(.plain)
      .disabled(!isEnabled)
      .onHover { inside in
        if inside { highlighted = item.id } else if highlighted == item.id { highlighted = nil }
      }
      .animation(SessionsMotion.hover, value: isLit)
      .accessibilityLabel(title)
    }
  }

  private func move(_ step: Int) {
    let selectable = items.filter(\.isSelectable)
    guard !selectable.isEmpty else { return }
    let index = selectable.firstIndex { $0.id == highlighted }
    let next: Int
    if let index {
      next = (index + step + selectable.count) % selectable.count
    } else {
      next = step > 0 ? 0 : selectable.count - 1
    }
    highlighted = selectable[next].id
  }

  private func activateHighlighted() {
    guard let item = items.first(where: { $0.id == highlighted }),
      case .action(_, _, _, let isEnabled, let handler) = item.kind, isEnabled
    else { return }
    dismiss()
    handler()
  }
}

/// The top of the menu-bar menu: what Sessions is doing, in a sentence, with
/// its signal light and, while transcribing, the real progress.
private struct SessionsMenuStatusRow: View {
  let title: String
  let detail: String?
  let progress: Double?
  let tone: CepessaSessionCapsuleMenuItem.StatusTone

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Circle()
        .fill(light)
        .frame(width: 7, height: 7)
        .shadow(color: light.opacity(tone == .quiet ? 0 : 0.8), radius: 4)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text(LocalTranscriptTextDirection.displayText(title))
          .font(SessionsType.text(13.5, weight: .semibold))
          .foregroundStyle(SessionsNight.ink)
          .monospacedDigit()
        if let detail, !detail.isEmpty {
          Text(LocalTranscriptTextDirection.displayText(detail))
            .font(SessionsType.text(11.5, weight: .medium))
            .foregroundStyle(SessionsNight.inkSecondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let progress {
          GeometryReader { proxy in
            ZStack(alignment: .leading) {
              Capsule().fill(SessionsNight.hairline)
              Capsule()
                .fill(SessionsPalette.sunriseGold)
                .frame(width: proxy.size.width * CGFloat(min(max(progress, 0.02), 1)))
                .shadow(color: SessionsPalette.sunriseGold.opacity(0.6), radius: 3)
            }
          }
          .frame(height: 3)
          .padding(.top, 5)
          .animation(.easeOut(duration: 0.3), value: progress)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.top, 9)
    .padding(.bottom, 7)
    .accessibilityElement(children: .combine)
  }

  private var light: Color {
    switch tone {
    case .quiet: return SessionsNight.inkQuiet
    case .recording: return SessionsPalette.recording
    case .working: return SessionsPalette.sunriseGold
    case .attention: return SessionsPalette.attention
    }
  }
}
