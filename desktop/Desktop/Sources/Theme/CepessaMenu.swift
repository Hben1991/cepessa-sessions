import SwiftUI

struct CepessaToolbarMenu<Label: View, Content: View>: View {
  @Binding var isOpen: Bool
  let alignment: CepessaToolbarMenuAlignment
  @ViewBuilder var label: () -> Label
  @ViewBuilder var content: () -> Content

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
        isOpen.toggle()
      }
    } label: {
      label()
    }
    .buttonStyle(CepessaPressStyle(scale: 0.965, pressedBrightness: -0.02))
    .overlay(alignment: alignment.overlayAlignment) {
      if isOpen {
        menuPanel
          .offset(y: -40)
          .transition(
            .opacity.combined(
              with: .scale(scale: 0.98, anchor: alignment.transitionAnchor)
            )
          )
      }
    }
    .zIndex(isOpen ? 40 : 0)
  }

  private var menuPanel: some View {
    content()
      .padding(8)
      .background {
        if #available(macOS 26.0, *) {
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.36))
            .glassEffect(
              .regular.tint(Color(hex: 0xF3DA9A).opacity(0.08)).interactive(),
              in: .rect(cornerRadius: 22)
            )

          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.64))
        } else {
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.ultraThinMaterial)

          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.90))
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .stroke(Color.white.opacity(0.82), lineWidth: 0.8)
      }
      .overlay {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .stroke(Color(hex: 0xF0C45A).opacity(0.32), lineWidth: 0.8)
          .padding(0.5)
      }
      .shadow(color: CepessaColors.warmShadow.opacity(0.18), radius: 30, x: 0, y: 16)
      .shadow(color: .white.opacity(0.34), radius: 1, x: 0, y: -1)
  }
}

enum CepessaToolbarMenuAlignment {
  case leading
  case center
  case trailing

  var overlayAlignment: Alignment {
    switch self {
    case .leading:
      return .bottomLeading
    case .center:
      return .bottom
    case .trailing:
      return .bottomTrailing
    }
  }

  var transitionAnchor: UnitPoint {
    switch self {
    case .leading:
      return .bottomLeading
    case .center:
      return .bottom
    case .trailing:
      return .bottomTrailing
    }
  }
}
