import Foundation

struct LocalSessionInsightSpan: Equatable, Sendable, Identifiable {
  var id: String
  var segmentID: UUID
  var segmentIndex: Int
  var speaker: String
  var speakerID: String?
  var text: String
  var range: LocalSessionInsightTextRange
  var startOffsetSeconds: Double
  var endOffsetSeconds: Double?
}

struct LocalSessionInsightWindow: Equatable, Sendable, Identifiable {
  var id: String
  var focal: [LocalSessionInsightSpan]
  var preceding: [LocalSessionInsightSpan]
  var following: [LocalSessionInsightSpan]
}

struct LocalSessionInsightWindowPlan: Equatable, Sendable {
  var spans: [LocalSessionInsightSpan]
  var windows: [LocalSessionInsightWindow]
  var omittedSpanIDs: [String]
  var omittedReasons: [String: String]
}

enum LocalSessionInsightWindowBuilder {
  static func plan(
    session: LocalSession,
    maxFocalCharacters: Int = LocalSessionInsightPolicy.maxFocalCharacters,
    maxFocalsPerWindow: Int = LocalSessionInsightPolicy.maxFocalsPerWindow,
    contextSpanCount: Int = LocalSessionInsightPolicy.contextSpanCount,
    maxEstimatedInputCharacters: Int = LocalSessionInsightPolicy.maxEstimatedInputCharacters
  ) -> LocalSessionInsightWindowPlan {
    var omitted: [String: String] = [:]
    let spans = session.transcriptSegments.enumerated().flatMap {
      index, segment -> [LocalSessionInsightSpan] in
      splitSegment(
        segment,
        sessionStart: session.startedAt,
        segmentIndex: index,
        maxFocalCharacters: maxFocalCharacters,
        omitted: &omitted
      )
    }

    var windows: [LocalSessionInsightWindow] = []
    var current: [LocalSessionInsightSpan] = []
    var currentChars = 0

    func flush() {
      guard !current.isEmpty else { return }
      let firstIndex = current[0].id
      let lastIndex = current[current.count - 1].id
      windows.append(
        makeWindow(
          id: "window:\(firstIndex):\(lastIndex)",
          focals: current,
          allSpans: spans,
          contextSpanCount: contextSpanCount
        )
      )
      current = []
      currentChars = 0
    }

    for span in spans {
      let spanCost = estimatedCharacters(for: span)
      if spanCost > maxEstimatedInputCharacters {
        omitted[span.id] = "span exceeds the provider input budget"
        continue
      }
      let wouldExceedCount = current.count >= maxFocalsPerWindow
      let wouldExceedChars =
        !current.isEmpty && (currentChars + spanCost) > maxEstimatedInputCharacters / 3
      if wouldExceedCount || wouldExceedChars {
        flush()
      }
      current.append(span)
      currentChars += spanCost
    }
    flush()

    return LocalSessionInsightWindowPlan(
      spans: spans,
      windows: windows,
      omittedSpanIDs: omitted.keys.sorted(),
      omittedReasons: omitted
    )
  }

  static func evidence(
    for span: LocalSessionInsightSpan,
    sessionID: UUID
  ) -> LocalSessionInsightEvidence {
    LocalSessionInsightEvidence(
      sessionID: sessionID,
      spans: [LocalSessionInsightEvidenceSpan(segmentID: span.segmentID, range: span.range)],
      sourceSubstring: span.text,
      startOffsetSeconds: span.startOffsetSeconds,
      endOffsetSeconds: span.endOffsetSeconds
    )
  }

  static func extract(
    range: LocalSessionInsightTextRange,
    from text: String
  ) -> String? {
    guard range.isValid(in: text) else { return nil }
    let start = text.utf16.index(text.utf16.startIndex, offsetBy: range.utf16Start)
    let end = text.utf16.index(start, offsetBy: range.utf16Length)
    return String(text.utf16[start..<end])
  }

  static func validateEvidence(
    _ evidence: LocalSessionInsightEvidence,
    in session: LocalSession
  ) -> Bool {
    guard evidence.sessionID == session.id else { return false }
    guard !evidence.sourceSubstring.isEmpty else { return false }
    var reconstructed = ""
    for span in evidence.spans {
      guard let segment = session.transcriptSegments.first(where: { $0.id == span.segmentID })
      else {
        return false
      }
      guard let slice = extract(range: span.range, from: segment.text) else { return false }
      reconstructed += slice
    }
    return reconstructed == evidence.sourceSubstring
  }

  private static func splitSegment(
    _ segment: LocalSessionTranscriptSegment,
    sessionStart: Date,
    segmentIndex: Int,
    maxFocalCharacters: Int,
    omitted: inout [String: String]
  ) -> [LocalSessionInsightSpan] {
    let text = segment.text
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let startOffset = LocalSessionInsightPolicy.offsetSeconds(
      from: sessionStart, to: segment.timestamp)
    let endOffset = segment.endTimestamp.map {
      LocalSessionInsightPolicy.offsetSeconds(from: sessionStart, to: $0)
    }

    var spans: [LocalSessionInsightSpan] = []
    var currentStart = 0
    var utf16Offset = 0
    let scalars = Array(text.unicodeScalars)

    func emit(until utf16End: Int) {
      let length = utf16End - currentStart
      guard length > 0 else { return }
      guard
        let slice = extract(
          range: LocalSessionInsightTextRange(utf16Start: currentStart, utf16Length: length),
          from: text)
      else { return }
      if slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        currentStart = utf16End
        return
      }
      spans.append(
        contentsOf: chunk(
          text: slice,
          utf16Start: currentStart,
          segment: segment,
          segmentIndex: segmentIndex,
          startOffset: startOffset,
          endOffset: endOffset,
          maxFocalCharacters: maxFocalCharacters,
          omitted: &omitted
        )
      )
      currentStart = utf16End
    }

    for (index, scalar) in scalars.enumerated() {
      let width = String(scalar).utf16.count
      let nextIsDigit: Bool = {
        guard index + 1 < scalars.count else { return false }
        return scalars[index + 1].properties.numericType != nil
      }()
      if isSentenceTerminator(scalar) && !(scalar == "." && nextIsDigit) {
        utf16Offset += width
        emit(until: utf16Offset)
        continue
      }
      utf16Offset += width
    }
    emit(until: utf16Offset)
    return spans
  }

  private static func chunk(
    text: String,
    utf16Start: Int,
    segment: LocalSessionTranscriptSegment,
    segmentIndex: Int,
    startOffset: Double,
    endOffset: Double?,
    maxFocalCharacters: Int,
    omitted: inout [String: String]
  ) -> [LocalSessionInsightSpan] {
    let utf16Count = text.utf16.count
    if utf16Count <= maxFocalCharacters {
      return [
        makeSpan(
          segment: segment,
          segmentIndex: segmentIndex,
          text: text,
          utf16Start: utf16Start,
          utf16Length: utf16Count,
          startOffset: startOffset,
          endOffset: endOffset
        )
      ]
    }

    var result: [LocalSessionInsightSpan] = []
    var cursor = 0
    while cursor < utf16Count {
      var proposedEnd = min(cursor + maxFocalCharacters, utf16Count)
      if proposedEnd < utf16Count, let breakAt = lastWhitespaceUTF16(in: text, from: cursor, to: proposedEnd)
      {
        proposedEnd = breakAt
      }
      let length = proposedEnd - cursor
      if length <= 0 {
        let id = spanID(segmentID: segment.id, start: utf16Start + cursor, length: utf16Count - cursor)
        omitted[id] = "could not split an oversized span on a character boundary"
        break
      }
      guard
        let slice = extract(
          range: LocalSessionInsightTextRange(utf16Start: cursor, utf16Length: length),
          from: text)
      else {
        break
      }
      result.append(
        makeSpan(
          segment: segment,
          segmentIndex: segmentIndex,
          text: slice,
          utf16Start: utf16Start + cursor,
          utf16Length: length,
          startOffset: startOffset,
          endOffset: endOffset
        )
      )
      cursor = proposedEnd
    }
    return result
  }

  private static func makeWindow(
    id: String,
    focals: [LocalSessionInsightSpan],
    allSpans: [LocalSessionInsightSpan],
    contextSpanCount: Int
  ) -> LocalSessionInsightWindow {
    guard let first = focals.first, let last = focals.last,
      let firstIndex = allSpans.firstIndex(where: { $0.id == first.id }),
      let lastIndex = allSpans.firstIndex(where: { $0.id == last.id })
    else {
      return LocalSessionInsightWindow(id: id, focal: focals, preceding: [], following: [])
    }
    let precedingStart = max(0, firstIndex - contextSpanCount)
    let followingEnd = min(allSpans.count, lastIndex + 1 + contextSpanCount)
    return LocalSessionInsightWindow(
      id: id,
      focal: focals,
      preceding: Array(allSpans[precedingStart..<firstIndex]),
      following: Array(allSpans[(lastIndex + 1)..<followingEnd])
    )
  }

  private static func makeSpan(
    segment: LocalSessionTranscriptSegment,
    segmentIndex: Int,
    text: String,
    utf16Start: Int,
    utf16Length: Int,
    startOffset: Double,
    endOffset: Double?
  ) -> LocalSessionInsightSpan {
    LocalSessionInsightSpan(
      id: spanID(segmentID: segment.id, start: utf16Start, length: utf16Length),
      segmentID: segment.id,
      segmentIndex: segmentIndex,
      speaker: segment.speaker,
      speakerID: segment.speakerID,
      text: text,
      range: LocalSessionInsightTextRange(utf16Start: utf16Start, utf16Length: utf16Length),
      startOffsetSeconds: startOffset,
      endOffsetSeconds: endOffset
    )
  }

  private static func spanID(segmentID: UUID, start: Int, length: Int) -> String {
    "\(segmentID.uuidString):\(start):\(length)"
  }

  private static func estimatedCharacters(for span: LocalSessionInsightSpan) -> Int {
    span.text.utf16.count + span.speaker.utf16.count + 48
  }

  private static func isSentenceTerminator(_ scalar: UnicodeScalar) -> Bool {
    switch scalar {
    case ".", "?", "!", "\n", "\u{05C3}", ";", "。", "؟":
      return true
    default:
      return false
    }
  }

  private static func lastWhitespaceUTF16(in text: String, from start: Int, to end: Int) -> Int? {
    guard
      let slice = extract(
        range: LocalSessionInsightTextRange(utf16Start: start, utf16Length: end - start),
        from: text)
    else { return nil }
    var offset = slice.utf16.count
    var index = slice.endIndex
    while index > slice.startIndex {
      index = slice.index(before: index)
      offset -= String(slice[index]).utf16.count
      if slice[index].isWhitespace {
        let absolute = start + offset + String(slice[index]).utf16.count
        return absolute > start ? absolute : nil
      }
    }
    return nil
  }
}
