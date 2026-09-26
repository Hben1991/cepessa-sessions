import SwiftUI

/// The strip along the top of the sessions window, where the title bar used
/// to be. It clears the traffic lights, drags the window like a title bar,
/// and holds at most a few quiet controls on each side.
struct SessionsTopBar<Leading: View, Trailing: View>: View {
  @ViewBuilder let leading: () -> Leading
  @ViewBuilder let trailing: () -> Trailing

  static var height: CGFloat { 52 }

  var body: some View {
    HStack(spacing: 10) {
      leading()
      Spacer(minLength: 12)
      trailing()
    }
    // The traffic lights own the first 78 points of the bar.
    .padding(.leading, 84)
    .padding(.trailing, 18)
    .frame(height: Self.height)
    .frame(maxWidth: .infinity)
    .background {
      Color.clear
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
    }
  }
}

/// A round window control with an icon, a tooltip and an accessibility label.
struct SessionsRoundIconButton: View {
  let symbol: String
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
    }
    .buttonStyle(SessionsRoundButtonStyle())
    .help(title)
    .accessibilityLabel(title)
  }
}

/// "‹ Sessions": the way back from a reading to the library.
struct SessionsBackButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: "chevron.left")
          .font(.system(size: 11, weight: .bold))
        Text(title)
      }
    }
    .buttonStyle(SessionsLinkButtonStyle(size: 13.5))
    .keyboardShortcut("[", modifiers: .command)
    .help("Back to \(title) (⌘[)")
    .accessibilityLabel("Back to \(title)")
  }
}

/// A small uppercase label: section heads, speaker names, the date line.
struct SessionsEyebrow: View {
  let text: String
  var color: Color = SessionsPalette.inkTertiary
  var size: CGFloat = 11

  var body: some View {
    Text(text.uppercased())
      .font(SessionsType.text(size, weight: .semibold))
      .tracking(size * 0.12)
      .foregroundStyle(color)
      .lineLimit(1)
  }
}
