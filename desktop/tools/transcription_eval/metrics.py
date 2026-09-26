"""Deterministic text, speaker, and identity metrics."""

from __future__ import annotations

from collections import defaultdict
from functools import lru_cache
from typing import Any, Sequence

from .normalization import normalized_character_stream, normalized_tokens


def _edit_counts(reference: Sequence[str], hypothesis: Sequence[str]) -> dict[str, int]:
    rows = len(reference) + 1
    columns = len(hypothesis) + 1
    table: list[list[tuple[int, int, int, int]]] = [
        [(0, 0, 0, 0) for _ in range(columns)] for _ in range(rows)
    ]
    for row in range(1, rows):
        table[row][0] = (row, 0, row, 0)
    for column in range(1, columns):
        table[0][column] = (column, 0, 0, column)

    def key(value: tuple[int, int, int, int]) -> tuple[int, int, int, int, int]:
        cost, substitutions, deletions, insertions = value
        return (cost, deletions + insertions, insertions, deletions, -substitutions)

    for row in range(1, rows):
        for column in range(1, columns):
            if reference[row - 1] == hypothesis[column - 1]:
                table[row][column] = table[row - 1][column - 1]
                continue
            diagonal = table[row - 1][column - 1]
            deletion = table[row - 1][column]
            insertion = table[row][column - 1]
            candidates = [
                (diagonal[0] + 1, diagonal[1] + 1, diagonal[2], diagonal[3]),
                (deletion[0] + 1, deletion[1], deletion[2] + 1, deletion[3]),
                (insertion[0] + 1, insertion[1], insertion[2], insertion[3] + 1),
            ]
            table[row][column] = min(candidates, key=key)

    cost, substitutions, deletions, insertions = table[-1][-1]
    return {
        "errors": cost,
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
    }


def error_metrics(reference_text: str, hypothesis_text: str) -> dict[str, Any]:
    reference_words = normalized_tokens(reference_text)
    hypothesis_words = normalized_tokens(hypothesis_text)
    word_counts = _edit_counts(reference_words, hypothesis_words)
    reference_characters = normalized_character_stream(reference_text)
    hypothesis_characters = normalized_character_stream(hypothesis_text)
    character_counts = _edit_counts(reference_characters, hypothesis_characters)

    reference_word_count = len(reference_words)
    reference_character_count = len(reference_characters)
    return {
        "reference_words": reference_word_count,
        "hypothesis_words": len(hypothesis_words),
        **word_counts,
        "wer": word_counts["errors"] / reference_word_count if reference_word_count else None,
        "deletion_rate": word_counts["deletions"] / reference_word_count if reference_word_count else None,
        "insertion_rate": word_counts["insertions"] / reference_word_count if reference_word_count else None,
        "reference_characters": reference_character_count,
        "hypothesis_characters": len(hypothesis_characters),
        "character_errors": character_counts["errors"],
        "character_substitutions": character_counts["substitutions"],
        "character_deletions": character_counts["deletions"],
        "character_insertions": character_counts["insertions"],
        "cer": (
            character_counts["errors"] / reference_character_count
            if reference_character_count
            else None
        ),
    }


def _subsequence_occurrences(tokens: Sequence[str], term: Sequence[str]) -> int:
    if not term or len(term) > len(tokens):
        return 0
    return sum(tokens[index : index + len(term)] == list(term) for index in range(len(tokens) - len(term) + 1))


def critical_term_metrics(
    reference_text: str,
    hypothesis_text: str,
    critical_terms: Sequence[str],
) -> dict[str, Any]:
    reference_tokens = normalized_tokens(reference_text)
    hypothesis_tokens = normalized_tokens(hypothesis_text)
    terms: list[dict[str, Any]] = []
    reference_occurrences = 0
    matched_occurrences = 0
    hallucinated_occurrences = 0

    for raw_term in critical_terms:
        term_tokens = normalized_tokens(raw_term)
        if not term_tokens:
            continue
        reference_count = _subsequence_occurrences(reference_tokens, term_tokens)
        hypothesis_count = _subsequence_occurrences(hypothesis_tokens, term_tokens)
        matched = min(reference_count, hypothesis_count)
        hallucinated = max(0, hypothesis_count - reference_count)
        reference_occurrences += reference_count
        matched_occurrences += matched
        hallucinated_occurrences += hallucinated
        terms.append(
            {
                "term": raw_term,
                "normalized": " ".join(term_tokens),
                "reference_occurrences": reference_count,
                "hypothesis_occurrences": hypothesis_count,
                "matched_occurrences": matched,
                "missed_occurrences": max(0, reference_count - hypothesis_count),
                "hallucinated_occurrences": hallucinated,
            }
        )

    predicted_occurrences = matched_occurrences + hallucinated_occurrences
    return {
        "terms": terms,
        "reference_occurrences": reference_occurrences,
        "matched_occurrences": matched_occurrences,
        "missed_occurrences": reference_occurrences - matched_occurrences,
        "hallucinated_occurrences": hallucinated_occurrences,
        "recall": matched_occurrences / reference_occurrences if reference_occurrences else None,
        "precision": matched_occurrences / predicted_occurrences if predicted_occurrences else None,
    }


def _segments(segments: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for segment in segments:
        start_ms = int(segment["start_ms"])
        end_ms = int(segment["end_ms"])
        speaker_id = str(segment["speaker_id"])
        if start_ms < 0 or end_ms <= start_ms:
            raise ValueError(f"Invalid speaker segment: {segment}")
        normalized.append({**segment, "start_ms": start_ms, "end_ms": end_ms, "speaker_id": speaker_id})
    return sorted(normalized, key=lambda segment: (segment["start_ms"], segment["end_ms"], segment["speaker_id"]))


def _coalesce_same_speaker_activity(
    segments: Sequence[dict[str, Any]],
) -> list[dict[str, Any]]:
    by_speaker: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for segment in segments:
        by_speaker[segment["speaker_id"]].append(segment)

    coalesced: list[dict[str, Any]] = []
    for speaker_id in sorted(by_speaker):
        ordered = sorted(
            by_speaker[speaker_id],
            key=lambda segment: (segment["start_ms"], segment["end_ms"]),
        )
        for segment in ordered:
            if (
                coalesced
                and coalesced[-1]["speaker_id"] == speaker_id
                and segment["start_ms"] <= coalesced[-1]["end_ms"]
            ):
                coalesced[-1]["end_ms"] = max(
                    coalesced[-1]["end_ms"],
                    segment["end_ms"],
                )
                continue
            coalesced.append(
                {
                    "start_ms": segment["start_ms"],
                    "end_ms": segment["end_ms"],
                    "speaker_id": speaker_id,
                }
            )
    return sorted(
        coalesced,
        key=lambda segment: (
            segment["start_ms"],
            segment["end_ms"],
            segment["speaker_id"],
        ),
    )


def _optimal_speaker_mapping(
    reference_segments: Sequence[dict[str, Any]],
    hypothesis_segments: Sequence[dict[str, Any]],
) -> dict[str, str]:
    reference_speakers = sorted({segment["speaker_id"] for segment in reference_segments})
    hypothesis_speakers = sorted({segment["speaker_id"] for segment in hypothesis_segments})
    if len(reference_speakers) > 12:
        raise ValueError("Speaker metric scaffold supports at most 12 reference speakers per clip.")
    overlap: dict[tuple[str, str], int] = defaultdict(int)
    for reference in reference_segments:
        for hypothesis in hypothesis_segments:
            duration = min(reference["end_ms"], hypothesis["end_ms"]) - max(
                reference["start_ms"], hypothesis["start_ms"]
            )
            if duration > 0:
                overlap[(hypothesis["speaker_id"], reference["speaker_id"])] += duration

    @lru_cache(maxsize=None)
    def assign(hypothesis_index: int, used_reference_mask: int) -> tuple[int, tuple[tuple[str, str], ...]]:
        if hypothesis_index >= len(hypothesis_speakers):
            return 0, ()
        hypothesis_speaker = hypothesis_speakers[hypothesis_index]
        best_score, best_pairs = assign(hypothesis_index + 1, used_reference_mask)
        for reference_index, reference_speaker in enumerate(reference_speakers):
            bit = 1 << reference_index
            if used_reference_mask & bit:
                continue
            suffix_score, suffix_pairs = assign(hypothesis_index + 1, used_reference_mask | bit)
            score = overlap[(hypothesis_speaker, reference_speaker)] + suffix_score
            pairs = ((hypothesis_speaker, reference_speaker),) + suffix_pairs
            if score > best_score or (score == best_score and pairs < best_pairs):
                best_score, best_pairs = score, pairs
        return best_score, best_pairs

    return dict(assign(0, 0)[1])


def _active_speakers(segments: Sequence[dict[str, Any]], start_ms: int, end_ms: int) -> set[str]:
    midpoint = start_ms + ((end_ms - start_ms) / 2)
    return {
        segment["speaker_id"]
        for segment in segments
        if segment["start_ms"] <= midpoint < segment["end_ms"]
    }


def _inside_reference_collar(
    midpoint_ms: float,
    reference_segments: Sequence[dict[str, Any]],
    collar_ms: int,
) -> bool:
    if collar_ms <= 0:
        return False
    boundaries = {
        boundary
        for segment in reference_segments
        for boundary in (segment["start_ms"], segment["end_ms"])
    }
    return any(abs(midpoint_ms - boundary) < collar_ms for boundary in boundaries)


def _scoring_boundaries(
    reference_segments: Sequence[dict[str, Any]],
    hypothesis_segments: Sequence[dict[str, Any]],
    collar_ms: int,
) -> list[int]:
    boundaries = {
        boundary
        for segment in list(reference_segments) + list(hypothesis_segments)
        for boundary in (segment["start_ms"], segment["end_ms"])
    }
    if collar_ms > 0:
        for segment in reference_segments:
            for boundary in (segment["start_ms"], segment["end_ms"]):
                boundaries.add(boundary - collar_ms)
                boundaries.add(boundary + collar_ms)
    return sorted(boundaries)


def _boundary_f1(
    reference_segments: Sequence[dict[str, Any]],
    hypothesis_segments: Sequence[dict[str, Any]],
    tolerance_ms: int,
) -> dict[str, Any]:
    reference_boundaries = sorted({segment["start_ms"] for segment in reference_segments})
    hypothesis_boundaries = sorted({segment["start_ms"] for segment in hypothesis_segments})
    if reference_boundaries:
        reference_boundaries = reference_boundaries[1:]
    if hypothesis_boundaries:
        hypothesis_boundaries = hypothesis_boundaries[1:]

    used: set[int] = set()
    matches = 0
    for reference_boundary in reference_boundaries:
        candidates = [
            (abs(reference_boundary - hypothesis_boundary), index)
            for index, hypothesis_boundary in enumerate(hypothesis_boundaries)
            if index not in used and abs(reference_boundary - hypothesis_boundary) <= tolerance_ms
        ]
        if candidates:
            _, matched_index = min(candidates)
            used.add(matched_index)
            matches += 1

    precision = matches / len(hypothesis_boundaries) if hypothesis_boundaries else None
    recall = matches / len(reference_boundaries) if reference_boundaries else None
    f1 = None
    if precision is not None and recall is not None and precision + recall > 0:
        f1 = 2 * precision * recall / (precision + recall)
    return {
        "reference_boundaries": len(reference_boundaries),
        "hypothesis_boundaries": len(hypothesis_boundaries),
        "matched_boundaries": matches,
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "tolerance_ms": tolerance_ms,
    }


def speaker_metrics(
    reference_segments: Sequence[dict[str, Any]],
    hypothesis_segments: Sequence[dict[str, Any]],
    *,
    collar_ms: int = 250,
    turn_tolerance_ms: int = 500,
) -> dict[str, Any]:
    reference = _coalesce_same_speaker_activity(_segments(reference_segments))
    hypothesis = _coalesce_same_speaker_activity(_segments(hypothesis_segments))
    mapping = _optimal_speaker_mapping(reference, hypothesis)
    boundaries = _scoring_boundaries(reference, hypothesis, collar_ms)
    reference_speaker_ms = 0
    missed_speaker_ms = 0
    false_alarm_speaker_ms = 0
    confused_speaker_ms = 0

    for start_ms, end_ms in zip(boundaries, boundaries[1:]):
        if end_ms <= start_ms:
            continue
        midpoint_ms = start_ms + ((end_ms - start_ms) / 2)
        if _inside_reference_collar(midpoint_ms, reference, collar_ms):
            continue
        duration_ms = end_ms - start_ms
        active_reference = _active_speakers(reference, start_ms, end_ms)
        active_hypothesis = _active_speakers(hypothesis, start_ms, end_ms)
        mapped_hypothesis = {mapping.get(speaker, f"__unmapped__:{speaker}") for speaker in active_hypothesis}
        reference_speaker_ms += len(active_reference) * duration_ms
        missed_speaker_ms += max(0, len(active_reference) - len(active_hypothesis)) * duration_ms
        false_alarm_speaker_ms += max(0, len(active_hypothesis) - len(active_reference)) * duration_ms
        paired_count = min(len(active_reference), len(active_hypothesis))
        correct_count = len(active_reference & mapped_hypothesis)
        confused_speaker_ms += max(0, paired_count - correct_count) * duration_ms

    diarization_error_ms = missed_speaker_ms + false_alarm_speaker_ms + confused_speaker_ms
    reference_speakers = {segment["speaker_id"] for segment in reference}
    hypothesis_speakers = {segment["speaker_id"] for segment in hypothesis}
    return {
        "reference_speaker_count": len(reference_speakers),
        "hypothesis_speaker_count": len(hypothesis_speakers),
        "speaker_count_exact": len(reference_speakers) == len(hypothesis_speakers),
        "mapping": mapping,
        "reference_speaker_ms": reference_speaker_ms,
        "missed_speaker_ms": missed_speaker_ms,
        "false_alarm_speaker_ms": false_alarm_speaker_ms,
        "confused_speaker_ms": confused_speaker_ms,
        "diarization_error_ms": diarization_error_ms,
        "der": diarization_error_ms / reference_speaker_ms if reference_speaker_ms else None,
        "collar_ms": collar_ms,
        "turn_boundaries": _boundary_f1(reference, hypothesis, turn_tolerance_ms),
    }


def identity_metrics(identity_pairs: Sequence[dict[str, Any]]) -> dict[str, Any]:
    total_reference_identities = 0
    named_predictions = 0
    correct_predictions = 0
    false_predictions = 0
    abstentions = 0

    for pair in identity_pairs:
        reference_person_id = pair.get("reference_person_id")
        predicted_person_id = pair.get("predicted_person_id")
        if reference_person_id is not None:
            total_reference_identities += 1
        if predicted_person_id is None:
            abstentions += 1
            continue
        named_predictions += 1
        if reference_person_id == predicted_person_id:
            correct_predictions += 1
        else:
            false_predictions += 1

    return {
        "samples": len(identity_pairs),
        "reference_identities": total_reference_identities,
        "named_predictions": named_predictions,
        "correct_predictions": correct_predictions,
        "false_predictions": false_predictions,
        "abstentions": abstentions,
        "precision": correct_predictions / named_predictions if named_predictions else None,
        "recall": (
            correct_predictions / total_reference_identities
            if total_reference_identities
            else None
        ),
        "false_confident_name_rate": false_predictions / named_predictions if named_predictions else None,
        "abstention_rate": abstentions / len(identity_pairs) if identity_pairs else None,
    }
