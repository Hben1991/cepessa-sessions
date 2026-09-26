import SwiftUI

/// Every recording on this Mac, by day. Search reaches titles and transcripts.
struct CepessaSessionLibraryView: View {
  @ObservedObject var model: LocalMeetingAppModel
  let open: (UUID) -> Void

  @State private var query = ""
  @FocusState private var isSearchFocused: Bool

  private let measure: CGFloat = 760

  var body: some View {
    VStack(spacing: 0) {
      SessionsTopBar {
        EmptyView()
      } trailing: {
        SessionsRoundIconButton(
          symbol: "square.and.arrow.down", title: "Import Audio…",
          action: CepessaSessionsWindowController.shared.importAudio)
        SessionsRoundIconButton(
          symbol: "gearshape", title: "Settings…",
          action: CepessaSessionsWindowController.shared.openSettings)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          header
            .padding(.bottom, 28)

          if model.sessions.isEmpty {
            emptyLibrary
          } else if groups.isEmpty {
            noMatches
          } else {
            LazyVStack(alignment: .leading, spacing: 30) {
              ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                daySection(group, order: index)
              }
            }
          }
        }
        .frame(maxWidth: measure, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .padding(.bottom, 64)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.automatic)
    }
    .background {
      // ⌘F: into the search field, from anywhere in the library.
      Button("") { isSearchFocused = true }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .accessibilityHidden(true)
    }
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 18) {
      SessionsRevealedLine(
        text: "Sessions",
        font: SessionsType.display(52),
        tracking: 52 * -0.018
      )
      .accessibilityAddTraits(.isHeader)

      HStack(spacing: 14) {
        searchField
        Text(countLine)
          .font(SessionsType.text(13, weight: .medium))
          .foregroundStyle(SessionsPalette.inkTertiary)
          .monospacedDigit()
          .sessionsArrival(1)
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(SessionsPalette.inkTertiary)
      TextField("Search titles and transcripts", text: $query)
        .textFieldStyle(.plain)
        .font(SessionsType.text(14))
        .foregroundStyle(SessionsPalette.ink)
        .focused($isSearchFocused)
        .focusEffectDisabled()
        .accessibilityLabel("Search sessions")
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(SessionsPalette.inkTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 14)
    .frame(width: 340, height: 36)
    .sessionsRaised(radius: 18, isHighlighted: isSearchFocused)
    .sessionsArrival(0)
  }

  private var countLine: String {
    let total = model.sessions.count
    let noun = total == 1 ? "recording" : "recordings"
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "\(total) \(noun) on this Mac" }
    let found = groups.reduce(0) { $0 + $1.sessions.count }
    return "\(found) of \(total)"
  }

  // MARK: Days

  private struct DayGroup: Identifiable {
    let id: Date
    let title: String
    let sessions: [LocalSession]
  }

  private var matches: [LocalSession] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.sessions }
    return model.sessions.filter {
      $0.displayTitle.localizedCaseInsensitiveContains(query)
        || $0.transcriptText.localizedCaseInsensitiveContains(query)
    }
  }

  private var groups: [DayGroup] {
    let calendar = Calendar.current
    let byDay = Dictionary(grouping: matches) { calendar.startOfDay(for: $0.startedAt) }
    return byDay.keys.sorted(by: >).map { day in
      DayGroup(
        id: day,
        title: Self.dayTitle(for: day, calendar: calendar),
        sessions: (byDay[day] ?? []).sorted { $0.startedAt > $1.startedAt }
      )
    }
  }

  static func dayTitle(for day: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
    if calendar.isDate(day, inSameDayAs: now) { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(day, inSameDayAs: yesterday)
    {
      return "Yesterday"
    }
    let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
    return day.formatted(
      sameYear
        ? .dateTime.weekday(.wide).day().month(.wide)
        : .dateTime.weekday(.wide).day().month(.wide).year())
  }

  private func daySection(_ group: DayGroup, order: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(group.title)
        .font(SessionsType.display(22))
        .tracking(22 * -0.01)
        .foregroundStyle(SessionsPalette.inkSecondary)
        .padding(.leading, 14)
        .accessibilityAddTraits(.isHeader)
      VStack(spacing: 2) {
        ForEach(group.sessions) { session in
          LibraryRow(session: session, stage: model.processingSnapshot(for: session.id)) {
            open(session.id)
          }
        }
      }
    }
    .sessionsArrival(order + 2)
  }

  // MARK: Empty states

  private var emptyLibrary: some View {
    VStack(alignment: .leading, spacing: 14) {
      SessionsRevealedLine(
        text: "Nothing recorded yet.",
        font: SessionsType.display(30),
        color: SessionsPalette.inkSecondary,
        delay: 0.2)
      Text("Click the orb on the recorder to begin, or import a recording you already have.")
        .font(SessionsType.text(15))
        .foregroundStyle(SessionsPalette.inkTertiary)
        .sessionsArrival(1, after: 0.3)
      Button("Import Audio…", action: CepessaSessionsWindowController.shared.importAudio)
        .buttonStyle(SessionsCapsuleButtonStyle())
        .padding(.top, 6)
        .sessionsArrival(2, after: 0.3)
    }
    .padding(.top, 40)
  }

  private var noMatches: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Nothing matches “\(query)”.")
        .font(SessionsType.display(26))
        .foregroundStyle(SessionsPalette.inkSecondary)
      Text("Search looks through every title and transcript on this Mac.")
        .font(SessionsType.text(14))
        .foregroundStyle(SessionsPalette.inkTertiary)
    }
    .padding(.top, 32)
  }
}

/// One recording: when, what it is called, the first words of it, and — only
/// while something is happening or wrong — a point of light saying so.
private struct LibraryRow: View {
  let session: LocalSession
  let stage: LocalSessionProcessingSnapshot?
  let open: () -> Void

  @State private var isHovered = false

  private var status: CepessaStatusStyle { CepessaStatusStyle.resolve(session.status) }

  private var isRTL: Bool {
    LocalTranscriptTextDirection.isRightToLeft(session.displayTitle + " " + (detail ?? ""))
  }

  var body: some View {
    Button(action: open) {
      HStack(alignment: .firstTextBaseline, spacing: 18) {
        Text(session.startedAt.formatted(date: .omitted, time: .shortened))
          .font(SessionsType.figure(13))
          .foregroundStyle(SessionsPalette.inkTertiary)
          .frame(width: 58, alignment: .leading)

        // A Hebrew recording reads from the right, inside its column; the
        // time stays where every row keeps it.
        VStack(alignment: isRTL ? .trailing : .leading, spacing: 4) {
          Text(LocalTranscriptTextDirection.displayText(session.displayTitle))
            .font(SessionsType.text(17, weight: .medium))
            .foregroundStyle(SessionsPalette.ink)
            .lineLimit(1)
          if let detail {
            Text(LocalTranscriptTextDirection.displayText(detail))
              .font(SessionsType.text(13))
              .foregroundStyle(SessionsPalette.inkTertiary)
              .lineLimit(1)
          }
        }
        .multilineTextAlignment(isRTL ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)

        if status != .ready {
          HStack(spacing: 7) {
            SessionsStatusLight(style: status)
            Text(statusText)
              .font(SessionsType.text(12, weight: .medium))
              .foregroundStyle(SessionsPalette.inkSecondary)
          }
          .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(isHovered ? SessionsPalette.raised : .clear)
      )
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(SessionsPressStyle(scale: 0.99))
    .onHover { isHovered = $0 }
    .animation(SessionsMotion.hover, value: isHovered)
    .contextMenu {
      Button("Open", action: open)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(accessibilityText)
  }

  private var statusText: String {
    if status == .working, let progress = stage?.progress {
      return "Transcribing \(Int((progress * 100).rounded()))%"
    }
    return status.label
  }

  /// The first words, when there are any: a transcript is recognised by what
  /// was said, not by its timestamp.
  private var detail: String? {
    let text = session.transcriptSegments
      .lazy
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
    guard let text else { return nil }
    return text.count > 160 ? String(text.prefix(160)) + "…" : text
  }

  private var accessibilityText: String {
    var parts = [
      session.displayTitle,
      session.startedAt.formatted(date: .abbreviated, time: .shortened),
    ]
    if status != .ready { parts.append(statusText) }
    if let detail { parts.append(detail) }
    return parts.joined(separator: ", ")
  }
}
