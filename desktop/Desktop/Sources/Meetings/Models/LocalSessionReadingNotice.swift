import Foundation

struct LocalSessionReadingNotice: Codable, Equatable {
  let title: String
  let detail: String
  let needsReview: Bool

  static func resolve(_ session: LocalSession) -> Self {
    let hasText = !session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if session.status == .recording {
      return .init(
        title: "Recording", detail: "The transcript will follow when recording stops.",
        needsReview: false)
    }
    if session.status == .transcribing {
      return .init(
        title: "Transcribing", detail: "Processing the recording on this Mac.", needsReview: false)
    }
    if session.status == .failed || session.transcriptionEvidence?.isComplete == false || !hasText {
      return .init(
        title: hasText ? "Transcript needs review" : "Transcript not ready",
        detail: session.processingError ?? session.transcriptionEvidence?.issues.first
          ?? (hasText
            ? "Some of the recording may be missing. Listen to the audio before relying on this text."
            : "Use Transcribe to try the saved audio again."),
        needsReview: true)
    }
    if session.transcriptionEvidence?.isComplete != true {
      return .init(
        title: "Saved transcript",
        detail:
          "This older transcript has no completeness check. The audio is the source of truth.",
        needsReview: false)
    }
    return .init(
      title: "Transcript ready", detail: "Source timing and detected speech coverage were checked.",
      needsReview: false)
  }
}
