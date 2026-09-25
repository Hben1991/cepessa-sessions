import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Decisions, commitments and open questions a cloud model proposed for this
/// transcript — only ever proposals until the owner confirms them, and each
/// one a click away from the words it came from.
struct LocalSessionInsightsView: View {
  @ObservedObject var model: LocalMeetingAppModel
  let session: LocalSession

  /// Analysis needs words; a saved analysis stays visible either way.
  static func isShown(for session: LocalSession, model: LocalMeetingAppModel) -> Bool {
    model.insightRecord(for: session.id) != nil
      || model.insightMalformedSessionIDs.contains(session.id)
      || !session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    let record = model.insightRecord(for: session.id)
    VStack(alignment: .leading, spacing: 12) {
      header(record)
      statusLine(record)
      if let record, let meeting = record.meetingJudgments {
        meetingSection(meeting)
      }
      if let record, !record.items.isEmpty {
        itemGroup(title: "Decisions", kind: .decision, record: record)
        itemGroup(title: "Commitments", kind: .commitment, record: record)
        itemGroup(title: "Open questions", kind: .openQuestion, record: record)
      } else if record != nil, record?.meetingJudgments == nil {
        emptyLine(record)
      }
    }
    .padding(18)
    .sessionsRaised(radius: 18)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Decisions, commitments, and open questions")
  }

  private func header(_ record: LocalSessionInsightRecord?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      SessionsEyebrow(text: "Decisions", color: SessionsPalette.ink)
      Text(LocalSessionInsightPolicy.experimentalLabel)
        .font(SessionsType.text(11, weight: .medium))
        .foregroundStyle(SessionsPalette.inkTertiary)
      Spacer()
      if record?.status == .running {
        Button("Cancel") { model.cancelInsightAnalysis(for: session.id) }
          .buttonStyle(SessionsLinkButtonStyle(size: 12.5))
          .accessibilityLabel("Cancel analysis")
      } else {
        Button(record == nil ? "Analyze with TypeSafe" : "Analyze Again") {
          model.requestInsightAnalysis(for: session.id)
        }
        .buttonStyle(SessionsLinkButtonStyle(size: 12.5, color: SessionsPalette.accent))
        .disabled(session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel("Analyze transcript with TypeSafe")
      }
      if record != nil {
        Button("Export") { exportInsights() }
          .buttonStyle(SessionsLinkButtonStyle(size: 12.5))
          .accessibilityLabel("Export analysis as Markdown")
      }
    }
  }

  @ViewBuilder
  private func statusLine(_ record: LocalSessionInsightRecord?) -> some View {
    if model.insightMalformedSessionIDs.contains(session.id) {
      Text("A saved analysis file is unreadable. The recording and transcript are unchanged.")
        .font(SessionsType.text(12.5))
        .foregroundStyle(SessionsPalette.attention)
    } else if let record {
      Text(coverageCopy(record))
        .font(SessionsType.text(12.5))
        .foregroundStyle(SessionsPalette.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      Text("Off until you start it for this transcript. Only the transcript text is sent.")
        .font(SessionsType.text(12.5))
        .foregroundStyle(SessionsPalette.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .help(LocalSessionInsightPolicy.cloudDisclosure)
    }
  }

  private func emptyLine(_ record: LocalSessionInsightRecord?) -> some View {
    Text(emptyCopy(record))
      .font(SessionsType.text(14))
      .foregroundStyle(SessionsPalette.inkSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func meetingSection(_ judgments: LocalSessionInsightMeetingJudgments) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SessionsEyebrow(text: "Meeting")
      if let type = judgments.meetingTypeLabel ?? judgments.meetingType {
        meetingRow(title: "Meeting type", value: type)
      }
      if let noul = judgments.decisionMadeNoul {
        meetingRow(
          title: "Decision made",
          value: noul >= LocalSessionInsightPolicy.decisionNoulThreshold ? "Yes" : "No")
      }
      if let label = judgments.actionItemClarityLabel {
        meetingRow(title: "Action item clarity", value: label)
      }
      if let label = judgments.unresolvedFollowUpLabel {
        meetingRow(title: "Still open", value: label)
      }
      if let label = judgments.tensionLabel {
        meetingRow(title: "Tension", value: label)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Meeting judgments")
  }

  private func meetingRow(title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title)
        .font(SessionsType.text(12.5))
        .foregroundStyle(SessionsPalette.inkTertiary)
        .frame(width: 128, alignment: .leading)
      Text(value)
        .font(SessionsType.text(14))
        .foregroundStyle(SessionsPalette.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title). \(value)")
  }

  private func itemGroup(
    title: String, kind: LocalSessionInsightKind, record: LocalSessionInsightRecord
  ) -> some View {
    let items = record.items.filter { $0.kind == kind }
    return VStack(alignment: .leading, spacing: 8) {
      SessionsEyebrow(text: title)
      if items.isEmpty {
        Text("None in the analyzed coverage.")
          .font(SessionsType.text(12.5))
          .foregroundStyle(SessionsPalette.inkQuiet)
      } else {
        ForEach(items) { item in
          insightRow(item)
        }
      }
    }
  }

  private func insightRow(_ item: LocalSessionInsightItem) -> some View {
    let isRTL = LocalTranscriptTextDirection.isRightToLeft(item.proposalText)
    return VStack(alignment: isRTL ? .trailing : .leading, spacing: 6) {
      HStack(spacing: 8) {
        reviewBadge(item.reviewState)
        lifecycleBadge(item)
        Spacer()
        Text(timeLabel(item.evidence.startOffsetSeconds))
          .font(SessionsType.figure(11.5))
          .foregroundStyle(SessionsPalette.inkTertiary)
      }
      Text(LocalTranscriptTextDirection.displayText(item.proposalText))
        .font(SessionsType.text(15))
        .foregroundStyle(item.reviewState == .dismissed ? SessionsPalette.inkTertiary : SessionsPalette.ink)
        .strikethrough(item.reviewState == .dismissed, color: SessionsPalette.inkQuiet)
        .lineSpacing(4)
        .multilineTextAlignment(isRTL ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
        .textSelection(.enabled)
        .accessibilityLabel(accessibilityLabel(for: item))
      HStack(spacing: 14) {
        Text(speakerLabel(item))
          .font(SessionsType.text(12))
          .foregroundStyle(SessionsPalette.speakerColor(for: item.speaker))
        Button("Show in transcript") {
          model.revealInsightSource(item)
        }
        .buttonStyle(SessionsLinkButtonStyle(size: 12))
        .accessibilityLabel("Show transcript source")
        if item.reviewState != .confirmed {
          Button("Confirm") { model.reviewInsight(item, state: .confirmed) }
            .buttonStyle(SessionsLinkButtonStyle(size: 12))
            .accessibilityLabel("Confirm proposal")
        }
        if item.reviewState != .dismissed {
          Button("Dismiss") { model.reviewInsight(item, state: .dismissed) }
            .buttonStyle(SessionsLinkButtonStyle(size: 12))
            .accessibilityLabel("Dismiss proposal")
        }
      }
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
  }

  /// Confirmed is lit with the orb's light, not painted success-green; a
  /// proposal is outlined; a dismissal is quiet.
  private func reviewBadge(_ state: LocalSessionInsightReviewState) -> some View {
    let label = state == .unreviewed ? "Proposal" : state == .confirmed ? "Confirmed" : "Dismissed"
    return Text(label)
      .font(SessionsType.text(10.5, weight: .semibold))
      .foregroundStyle(state == .confirmed ? SessionsPalette.inkInverse : SessionsPalette.inkSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(
        Capsule().fill(state == .confirmed ? SessionsPalette.accent : Color.clear)
      )
      .overlay(
        Capsule().strokeBorder(
          state == .confirmed ? Color.clear : SessionsPalette.hairline, lineWidth: 1)
      )
  }

  private func lifecycleBadge(_ item: LocalSessionInsightItem) -> some View {
    let label: String? = {
      switch item.lifecycle {
      case .conditional: return "Conditional"
      case .retracted: return "Retracted"
      case .superseded: return "Superseded"
      case .unresolved: return "Unresolved"
      case .proposed: return item.isProvisional ? "Provisional" : nil
      }
    }()
    return Group {
      if let label {
        Text(label)
          .font(SessionsType.text(11, weight: .medium))
          .foregroundStyle(SessionsPalette.inkTertiary)
      }
    }
  }

  private func coverageCopy(_ record: LocalSessionInsightRecord) -> String {
    switch record.status {
    case .running:
      return "Analyzing \(record.coverage.coveredSpanIDs.count) of \(record.coverage.totalSpans) spans."
    case .partial:
      return "Partial analysis: \(record.coverage.coveredSpanIDs.count)/\(record.coverage.totalSpans) spans covered. This is not a complete reading of the transcript."
    case .stale:
      return "The transcript changed after this analysis. Confirmations were not moved onto the new text."
    case .failed:
      return record.failureMessage ?? "Analysis failed. The transcript was not changed."
    case .cancelled:
      return "Analysis was cancelled. Anything already sent cannot be recalled."
    case .complete:
      return "Analyzed \(record.coverage.totalSpans) spans. Machine labels stay proposals until you confirm them."
    case .notAnalyzed:
      return "Not analyzed."
    }
  }

  private func emptyCopy(_ record: LocalSessionInsightRecord?) -> String {
    guard let record else {
      return "No analysis yet."
    }
    switch record.status {
    case .running:
      return "Looking for binding decisions, commitments, and issues still open after the meeting."
    case .failed, .cancelled:
      return record.failureMessage ?? "No items."
    default:
      return "No items found in the analyzed coverage."
    }
  }

  private func speakerLabel(_ item: LocalSessionInsightItem) -> String {
    let speaker = item.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
    return speaker.isEmpty ? "Unidentified speaker" : speaker
  }

  private func timeLabel(_ offset: TimeInterval) -> String {
    let total = max(0, Int(offset.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  private func accessibilityLabel(for item: LocalSessionInsightItem) -> String {
    "\(item.kind.rawValue) proposal. \(speakerLabel(item)). \(item.proposalText). \(item.reviewState.rawValue)."
  }

  private func exportInsights() {
    let panel = NSSavePanel()
    panel.title = "Export analysis"
    panel.nameFieldStringValue = "\(session.displayTitle) Insights.md"
    if let markdownType = UTType(filenameExtension: "md") {
      panel.allowedContentTypes = [markdownType]
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    _ = try? model.exportInsightsMarkdown(for: session, to: url)
  }
}

struct CloudAnalysisSettingsSection: View {
  @AppStorage(LocalSessionInsightPolicy.featureEnabledDefaultsKey) private var featureEnabled =
    false
  @State private var apiKey = ""
  @State private var hasStoredKey = false
  @State private var statusMessage: String?

  var body: some View {
    Section {
      Toggle("Allow TypeSafe analysis", isOn: $featureEnabled)
      SecureField("TypeSafe API key", text: $apiKey)
      HStack {
        Button("Save key") { saveKey() }
          .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Remove key", role: .destructive) { removeKey() }
          .disabled(!hasStoredKey)
      }
      if let statusMessage {
        Text(statusMessage)
          .font(SessionsType.text(12))
          .foregroundStyle(SessionsPalette.inkTertiary)
      } else {
        Text(hasStoredKey ? "A key is stored in Keychain on this Mac." : "No key stored.")
          .font(SessionsType.text(12))
          .foregroundStyle(SessionsPalette.inkTertiary)
      }
    } header: {
      Text("Cloud Analysis")
    } footer: {
      Text(
        "Off by default. Analysis sends only the selected transcript text to TypeSafe (Jev). Audio, screenshots, attachments, and other sessions stay on this Mac. Machine labels stay proposals until you confirm them."
      )
    }
    .onAppear(perform: refreshKeyState)
    .onChange(of: featureEnabled) { _, enabled in
      if !enabled {
        CepessaSessionsStore.shared.model.cancelAllInsightAnalysis()
      }
    }
  }

  private func refreshKeyState() {
    hasStoredKey = (try? LocalSessionInsightCredentialStore().load()) != nil
  }

  private func saveKey() {
    do {
      try LocalSessionInsightCredentialStore().save(apiKey)
      apiKey = ""
      statusMessage = "Key saved in Keychain."
      refreshKeyState()
    } catch {
      statusMessage = "The key could not be saved."
    }
  }

  private func removeKey() {
    do {
      try LocalSessionInsightCredentialStore().delete()
      apiKey = ""
      statusMessage = "Key removed."
      refreshKeyState()
    } catch {
      statusMessage = "The key could not be removed."
    }
  }
}
