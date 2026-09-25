import AppKit
import SwiftUI

/// One entry in the capsule's menu.
struct CepessaSessionCapsuleMenuItem: Identifiable {
  enum Kind {
    case action(symbol: String?, title: String, detail: String?, isEnabled: Bool, handler: () -> Void)
    case header(String)
    case separator
  }

  let id = UUID()
  let kind: Kind

  static func action(
    _ title: String, symbol: String? = nil, detail: String? = nil, isEnabled: Bool = true,
    handler: @escaping () -> Void
  ) -> Self {
    Self(kind: .action(symbol: symbol, title: title, detail: detail, isEnabled: isEnabled, handler: handler))
  }

  static func header(_ title: String) -> Self { Self(kind: .header(title)) }
  static let separator = Self(kind: .separator)

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
  private var outsideClickMonitor: Any?
  private var localClickMonitor: Any?

  private var closedByClickAt = Date.distantPast

  var isOpen: Bool { panel?.isVisible == true }

  /// A click outside closes the menu before the control under it sees the
  /// click. When that control is the one that opened the menu, the click
  /// meant "close", not "open again".
  var wasJustClosedByClick: Bool {
    Date().timeIntervalSince(closedByClickAt) < 0.4
  }

  /// Opens the menu under (or, near the bottom of a screen, over) `anchor`,
  /// a rectangle in screen coordinates — normally the capsule.
  func open(items: [CepessaSessionCapsuleMenuItem], below anchor: NSRect, alignLeading: Bool = false) {
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

    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      Task { @MainActor in self?.closeAfterClick() }
    }
    localClickMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
      if event.window !== self?.panel {
        self?.closedByClickAt = Date()
        Task { @MainActor in self?.closeAfterClick() }
      }
      return event
    }
  }

  private func closeAfterClick() {
    guard isOpen else { return }
    closedByClickAt = Date()
    close()
  }

  func close() {
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    outsideClickMonitor = nil
    localClickMonitor = nil
    guard let panel else { return }
    self.panel = nil
    panel.onResignKey = nil
    panel.orderOut(nil)
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

  @State private var highlighted: UUID?
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
