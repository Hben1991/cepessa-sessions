import AppKit
import SwiftUI

private enum CepessaDestination: String, CaseIterable, Identifiable {
  case sessions
  case library
  case settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sessions: return "Sessions"
    case .library: return "Library"
    case .settings: return "Settings"
    }
  }

  var subtitle: String {
    switch self {
    case .sessions: return "Live capture workspace"
    case .library: return "Transcript and recap archive"
    case .settings: return "Permissions and local storage"
    }
  }

  var symbol: String {
    switch self {
    case .sessions: return "record.circle"
    case .library: return "square.stack.3d.up"
    case .settings: return "slider.horizontal.3"
    }
  }
}

@main
struct CepessaSessionsApp: App {
  @NSApplicationDelegateAdaptor(CepessaSessionsAppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup("Cepessa Sessions") {
      CepessaSessionsRootView()
        .withFontScaling()
        .tint(CepessaColors.capture)
        .frame(minWidth: 980, minHeight: 680)
    }
    .defaultSize(width: 1460, height: 920)
    .windowStyle(.titleBar)
  }
}

private final class CepessaSessionsAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    let floatingBarEnabledKey = "cepessa.sessions.floatingBarEnabled"
    let floatingBarMigrationKey = "cepessa.sessions.floatingBarDefaultOffMigrated"
    let defaults = UserDefaults.standard

    UserDefaults.standard.register(defaults: [
      floatingBarEnabledKey: false,
      floatingBarMigrationKey: false,
    ])
    if !defaults.bool(forKey: floatingBarMigrationKey) {
      defaults.set(false, forKey: floatingBarEnabledKey)
      defaults.set(true, forKey: floatingBarMigrationKey)
    }
    CepessaSessionStatusBarController.shared.connect(model: CepessaSessionsStore.shared.model)
  }
}

private struct CepessaSessionsRootView: View {
  @State private var selection: CepessaDestination? = .sessions
  @State private var hoveredDestination: CepessaDestination?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .background(CepessaColors.backgroundPrimary)
  }

  private var sidebar: some View {
    ZStack {
      LinearGradient(
        colors: [
          CepessaColors.paperDeep.opacity(0.92),
          CepessaColors.paper.opacity(0.98),
          Color(hex: 0xF9F4FF).opacity(0.96),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 18) {
          ZStack {
            UnevenRoundedRectangle(
              topLeadingRadius: 16,
              bottomLeadingRadius: 20,
              bottomTrailingRadius: 7,
              topTrailingRadius: 20,
              style: .continuous
            )
            .fill(
              LinearGradient(
                colors: [Color.white.opacity(0.96), CepessaColors.capture.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .frame(width: 42, height: 42)
            .shadow(color: CepessaColors.capture.opacity(0.22), radius: 14, x: 0, y: 8)
            Text("C")
              .scaledFont(size: 24, weight: .bold, design: .rounded)
              .foregroundStyle(CepessaColors.capture)
          }

          Text("CEPESSA\nSESSIONS")
            .scaledFont(size: 12, weight: .semibold)
            .tracking(5)
            .lineSpacing(5)
            .foregroundStyle(CepessaColors.textPrimary)
        }
        .padding(.top, 20)

        VStack(spacing: 8) {
          ForEach(CepessaDestination.allCases) { destination in
            sidebarButton(destination)
          }
        }

        Spacer(minLength: 0)

        VStack(alignment: .leading, spacing: 16) {
          Rectangle()
            .fill(CepessaColors.graphiteLine.opacity(0.76))
            .frame(height: 1)

          Text("COLLECTIONS")
            .scaledFont(size: 10, weight: .semibold)
            .tracking(1.2)
            .foregroundStyle(CepessaColors.textTertiary)

          HStack(spacing: 9) {
            Circle()
              .fill(CepessaColors.error)
              .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
              Text("New Recording")
                .scaledFont(size: 13, weight: .medium)
            }
          }
          .foregroundStyle(CepessaColors.textPrimary)
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
          .background(Color.white.opacity(0.56))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.white.opacity(0.74), lineWidth: 1)
          )
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
    }
    .frame(minWidth: 224, idealWidth: 244)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredDestination)
  }

  private func sidebarButton(_ destination: CepessaDestination) -> some View {
    let isSelected = selection == destination
    let isHovered = hoveredDestination == destination

    return Button {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
        selection = destination
      }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: destination.symbol)
          .scaledFont(size: 14, weight: .semibold)
          .frame(width: 18)

        Text(destination.title)
          .scaledFont(size: 15, weight: .medium, design: .serif)

        Spacer(minLength: 0)

        if isSelected {
          Capsule()
            .fill(CepessaColors.capture)
            .frame(width: 3, height: 30)
            .transition(.opacity.combined(with: .scale(scale: 0.86)))
        }
      }
      .foregroundStyle(isSelected ? CepessaColors.captureDeep : CepessaColors.textPrimary)
      .padding(.horizontal, 16)
      .padding(.vertical, 15)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(
            isSelected
              ? CepessaColors.paper.opacity(0.09)
              : (isHovered ? Color.white.opacity(0.42) : Color.clear))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(
            isSelected
              ? CepessaColors.capture.opacity(0.28)
              : (isHovered ? Color.white.opacity(0.66) : Color.clear),
            lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .buttonStyle(CepessaPressStyle(scale: 0.985))
    .onHover { isInside in
      hoveredDestination = isInside ? destination : nil
    }
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  @ViewBuilder
  private var detail: some View {
    switch selection ?? .sessions {
    case .sessions:
      CepessaSessionsHomePage()
    case .library:
      CepessaSessionsLibraryPage()
    case .settings:
      CepessaSessionsSettingsPage()
    }
  }
}
