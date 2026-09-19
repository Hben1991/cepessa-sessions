import Foundation

struct LocalSessionInsightExporter {
  func markdown(session: LocalSession, record: LocalSessionInsightRecord) -> String {
    var lines: [String] = []
    let title = session.displayTitle
    lines.append("# \(title) — Decisions and commitments")
    lines.append("")
    lines.append("Status: \(statusLabel(record.status))")
    lines.append("Coverage: \(record.coverage.coveredSpanIDs.count)/\(record.coverage.totalSpans) spans")
    if !record.coverage.omittedSpanIDs.isEmpty {
      lines.append(
        "Omitted spans: \(record.coverage.omittedSpanIDs.count). This is not a complete analysis of the transcript."
      )
    }
    lines.append("Provider: \(record.provider)")
    if let returned = record.returnedModel {
      lines.append("Returned model: \(returned)")
    } else {
      lines.append("Returned model: not supplied")
    }
    lines.append("Requested model: \(record.requestedModel)")
    lines.append("Policy: \(record.policyVersion) (\(LocalSessionInsightPolicy.experimentalLabel))")
    lines.append("")
    if let meeting = record.meetingJudgments {
      lines.append("## Meeting")
      lines.append("")
      if let type = meeting.meetingTypeLabel ?? meeting.meetingType {
        lines.append("- Meeting type: \(type)")
      }
      if let noul = meeting.decisionMadeNoul {
        let yes = noul >= LocalSessionInsightPolicy.decisionNoulThreshold
        lines.append("- Decision made: \(yes ? "Yes" : "No")")
      }
      if let label = meeting.actionItemClarityLabel {
        lines.append("- Action item clarity: \(label)")
      }
      if let label = meeting.unresolvedFollowUpLabel {
        lines.append("- Still open: \(label)")
      }
      if let label = meeting.tensionLabel {
        lines.append("- Tension: \(label)")
      }
      lines.append("")
    }

    let groups: [(LocalSessionInsightKind, String)] = [
      (.decision, "Decisions"),
      (.commitment, "Commitments"),
      (.openQuestion, "Open questions"),
    ]
    for (kind, heading) in groups {
      let items = record.items.filter { $0.kind == kind }
      lines.append("## \(heading)")
      lines.append("")
      if items.isEmpty {
        lines.append(
          record.status == .notAnalyzed
            ? "_Not analyzed._"
            : "_No items found in the analyzed coverage._"
        )
        lines.append("")
        continue
      }
      for item in items {
        let stamp = timeString(item.evidence.startOffsetSeconds)
        let speaker =
          item.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "Unidentified speaker" : item.speaker
        lines.append("- [\(stamp)] **\(speaker):** \"\(item.proposalText)\"")
        lines.append("  - Lifecycle: \(item.lifecycle.rawValue)")
        lines.append("  - Review: \(item.reviewState.rawValue)")
        if item.isProvisional {
          lines.append("  - Provisional: later context was not fully reconciled")
        }
        if let owner = item.ownerEvidence {
          lines.append("  - Owner evidence: \"\(owner)\"")
        }
        if let deadline = item.deadlineQuote {
          lines.append("  - Deadline quote: \"\(deadline)\"")
        }
      }
      lines.append("")
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }

  func export(
    session: LocalSession,
    record: LocalSessionInsightRecord,
    toFile url: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try markdown(session: session, record: record).write(
      to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func statusLabel(_ status: LocalSessionInsightStatus) -> String {
    switch status {
    case .notAnalyzed: return "not analyzed"
    case .running: return "running"
    case .complete: return "complete"
    case .partial: return "partial"
    case .failed: return "failed"
    case .cancelled: return "cancelled"
    case .stale: return "stale"
    }
  }

  private func timeString(_ offset: TimeInterval) -> String {
    let totalSeconds = max(0, Int(offset.rounded()))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
  }
}
