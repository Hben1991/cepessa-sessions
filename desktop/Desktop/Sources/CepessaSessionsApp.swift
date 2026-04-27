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
          CepessaColors.backgroundSecondary.opacity(0.96),
          CepessaColors.backgroundPrimary.opacity(0.92),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Cepessa Sessions")
            .scaledFont(size: 26, weight: .semibold)
            .foregroundStyle(CepessaColors.textPrimary)

          Text("A local workspace for recording, transcribing, and structuring sessions.")
            .scaledFont(size: 12)
            .foregroundStyle(CepessaColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)

        VStack(spacing: 10) {
          ForEach(CepessaDestination.allCases) { destination in
            sidebarButton(destination)
          }
        }

        Spacer(minLength: 0)

        VStack(alignment: .leading, spacing: 10) {
          Text("Local-first")
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(CepessaColors.textSecondary)

          Text(
            "Audio, transcript, recap, and attachments stay on this Mac unless you explicitly export them."
          )
          .scaledFont(size: 11)
          .foregroundStyle(CepessaColors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .cepessaPanel(
          fill: CepessaColors.backgroundSecondary.opacity(0.75),
          radius: 8,
          stroke: CepessaColors.border.opacity(0.45),
          shadowOpacity: 0,
          shadowRadius: 0,
          shadowY: 0
        )
      }
      .padding(18)
    }
    .frame(minWidth: 280, idealWidth: 320)
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

        VStack(alignment: .leading, spacing: 2) {
          Text(destination.title)
            .scaledFont(size: 13, weight: .semibold)
          Text(destination.subtitle)
            .scaledFont(size: 11)
            .foregroundStyle(CepessaColors.textSecondary)
        }

        Spacer(minLength: 0)

        if isSelected {
          Circle()
            .fill(Color.accentColor.opacity(0.74))
            .frame(width: 6, height: 6)
            .transition(.opacity.combined(with: .scale(scale: 0.86)))
        }
      }
      .foregroundStyle(isSelected ? CepessaColors.textPrimary : CepessaColors.textSecondary)
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(
            isSelected
              ? Color.accentColor.opacity(0.14)
              : (isHovered ? CepessaColors.backgroundRaised.opacity(0.48) : Color.clear))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(
            isSelected
              ? Color.accentColor.opacity(0.22)
              : (isHovered ? CepessaColors.border.opacity(0.18) : Color.clear),
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
