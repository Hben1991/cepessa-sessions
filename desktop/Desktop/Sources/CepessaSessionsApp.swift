import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum CepessaDestination: String, CaseIterable, Identifiable {
  case sessions
  case settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sessions: return "Sessions"
    case .settings: return "Settings"
    }
  }

  var subtitle: String {
    switch self {
    case .sessions: return "Capture and session library"
    case .settings: return "Permissions and local storage"
    }
  }

  var symbol: String {
    switch self {
    case .sessions: return "rectangle.stack"
    case .settings: return "gearshape"
    }
  }
}

@main
struct CepessaSessionsApp: App {
  @NSApplicationDelegateAdaptor(CepessaSessionsAppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup("Sessions") {
      CepessaSessionsRootView()
        .withFontScaling()
        .tint(CepessaColors.capture)
        .frame(minWidth: 980, minHeight: 680)
    }
    .defaultSize(width: 1460, height: 920)
    .windowStyle(.hiddenTitleBar)
  }
}

private final class CepessaSessionsAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    CepessaSessionFloatingBarPreferences.installDefaults()
    CepessaSessionStatusBarController.shared.connect(model: CepessaSessionsStore.shared.model)
  }
}

private struct CepessaSessionsRootView: View {
  @ObservedObject private var model = CepessaSessionsStore.shared.model
  @State private var selection: CepessaDestination? = .sessions
  @State private var hoveredDestination: CepessaDestination?
  @AppStorage("cepessa.sessions.documentLanguage") private var documentLanguage =
    LocalSessionDocumentLanguage.english.rawValue
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
      sidebarSurface
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 22) {
        sessionsMenuButton

        Spacer(minLength: 0)

        sidebarButton(.settings)
      }
      .padding(.horizontal, 22)
      .padding(.top, 54)
      .padding(.bottom, 24)
    }
    .frame(minWidth: 286, idealWidth: 306, maxWidth: 326)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredDestination)
  }

  private var sidebarSurface: some View {
    ZStack {
      Color.white.opacity(0.72)

      LinearGradient(
        colors: [
          Color(hex: 0xF8FBFF).opacity(0.94),
          Color(hex: 0xEEF5FC).opacity(0.78),
          Color.white.opacity(0.88),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      Rectangle()
        .fill(.ultraThinMaterial)
        .opacity(0.42)
    }
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(CepessaColors.border.opacity(0.34))
        .frame(width: 1)
    }
  }

  private var sessionsMenuButton: some View {
    let isSelected = selection == .sessions

    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button {
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            selection = .sessions
          }
        } label: {
          HStack(spacing: 13) {
            Image(systemName: CepessaDestination.sessions.symbol)
              .scaledFont(size: 13, weight: .semibold)
              .frame(width: 18)

            Text("Sessions")
              .scaledFont(size: 14, weight: .semibold, design: .rounded)

            Spacer(minLength: 0)
          }
          .foregroundStyle(isSelected ? CepessaColors.textPrimary : CepessaColors.textSecondary)
          .padding(.horizontal, 17)
          .frame(height: 52)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Capsule())
        }
        .buttonStyle(CepessaPressStyle(scale: 0.985))
        .accessibilityLabel("Sessions")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])

        Button {
          selection = .sessions
          importRecording()
        } label: {
          Image(systemName: "arrow.down.to.line")
            .scaledFont(size: 14, weight: .medium)
            .frame(width: 38, height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(CepessaPressStyle(scale: 0.965))
        .foregroundStyle(CepessaColors.textPrimary)
        .help("Import audio")
        .accessibilityLabel("Import Audio")
      }
      .background {
        if #available(macOS 26.0, *) {
          Capsule()
            .fill(Color.white.opacity(isSelected ? 0.42 : 0.28))
            .glassEffect(
              .regular.tint(Color(hex: 0xECF4FF).opacity(0.08)).interactive(),
              in: .capsule
            )
        } else {
          Capsule()
            .fill(.ultraThinMaterial)
          Capsule()
            .fill(Color.white.opacity(isSelected ? 0.76 : 0.50))
        }
      }
      .overlay {
        Capsule()
          .stroke(Color.white.opacity(0.82), lineWidth: 0.8)
      }
      .overlay {
        Capsule()
          .stroke(CepessaColors.border.opacity(0.36), lineWidth: 0.7)
      }
      .shadow(color: CepessaColors.warmShadow.opacity(0.055), radius: 16, x: 0, y: 8)

      VStack(alignment: .leading, spacing: 18) {
        inlineNewRecordingButton

        if model.sessions.isEmpty {
          Text("No recordings yet")
            .scaledFont(size: 12, weight: .medium)
            .foregroundStyle(CepessaColors.textTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
              ForEach(model.sessions) { session in
                inlineSessionButton(session)
              }
            }
            .padding(.vertical, 2)
          }
          .scrollIndicators(.hidden)
          .frame(maxHeight: 520)
        }
      }
      .padding(.top, 18)
    }
  }

  private var inlineNewRecordingButton: some View {
    Button {
      selection = .sessions
      model.toggleRecording()
    } label: {
      Label(
        model.isRecording ? "Stop Recording" : "New Recording", systemImage: "record.circle.fill"
      )
      .scaledFont(size: 12.5, weight: .medium)
      .foregroundStyle(model.isRecording ? CepessaColors.error : CepessaColors.textPrimary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(model.isRecording ? "Stop Recording" : "New Recording")
  }

  private func inlineSessionButton(_ session: LocalMeetingSession) -> some View {
    let isSelected = model.selectedSessionID == session.id
    let documentTitle = LocalSessionRecapMarkdownDocument.title(
      for: session,
      language: selectedDocumentLanguage
    )

    return Button {
      selection = .sessions
      model.selectSession(id: session.id)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "waveform")
          .scaledFont(size: 10.5, weight: .medium)
          .foregroundStyle(CepessaColors.textTertiary)
          .frame(width: 14)

        VStack(alignment: .leading, spacing: 1) {
          Text(documentTitle)
            .scaledFont(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded)
            .lineLimit(1)

          Text(session.startedAt.formatted(date: .omitted, time: .shortened))
            .scaledFont(size: 10)
            .foregroundStyle(CepessaColors.textTertiary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        if isSelected {
          Image(systemName: "arrow.down")
            .scaledFont(size: 10, weight: .medium)
            .foregroundStyle(CepessaColors.textTertiary)
        }
      }
      .foregroundStyle(CepessaColors.textPrimary)
      .padding(.horizontal, 12)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected ? Color(hex: 0xDDE8F7).opacity(0.58) : Color.clear,
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(isSelected ? Color.white.opacity(0.55) : Color.clear, lineWidth: 0.8)
      )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private var selectedDocumentLanguage: LocalSessionDocumentLanguage {
    LocalSessionDocumentLanguage(rawValue: documentLanguage) ?? .english
  }

  private func importRecording() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.audio]
    panel.prompt = "Transcribe"
    panel.message = "Choose an audio file to normalize locally and transcribe on this Mac."

    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      await model.importExistingRecording(from: url)
    }
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
          .scaledFont(size: 15, weight: .medium, design: .rounded)

        Spacer(minLength: 0)

        Circle()
          .fill(isSelected ? CepessaColors.capture : Color.clear)
          .frame(width: 7, height: 7)
          .transition(.opacity.combined(with: .scale(scale: 0.86)))
      }
      .foregroundStyle(isSelected ? CepessaColors.captureDeep : CepessaColors.textPrimary)
      .padding(.horizontal, 16)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(
            isSelected
              ? Color.white
              : (isHovered ? Color.white.opacity(0.72) : Color.clear))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(
            isSelected
              ? CepessaColors.border.opacity(0.95)
              : (isHovered ? CepessaColors.border.opacity(0.7) : Color.clear),
            lineWidth: 0.8)
      )
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    case .settings:
      CepessaSessionsSettingsPage()
    }
  }
}
