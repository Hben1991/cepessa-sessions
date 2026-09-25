#!/usr/bin/env python3
"""Score gold and hypothesis JSONL without exposing transcript content in the report."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.transcription_eval.metrics import (  # noqa: E402
    critical_term_metrics,
    error_metrics,
    identity_metrics,
    speaker_metrics,
)
from tools.transcription_eval.normalization import normalize_text  # noqa: E402

_PSEUDONYMIZATION_DOMAIN = "cepessa-transcription-report-v1"


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.expanduser().open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                value = json.loads(stripped)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {error}") from error
            if not isinstance(value, dict):
                raise ValueError(f"{path}:{line_number}: each JSONL record must be an object")
            records.append(value)
    return records


def _index_by_clip(records: Iterable[dict[str, Any]], source_name: str) -> dict[str, dict[str, Any]]:
    indexed: dict[str, dict[str, Any]] = {}
    for record in records:
        clip_id = record.get("clip_id")
        if not isinstance(clip_id, str) or not clip_id:
            raise ValueError(f"{source_name}: every record requires a non-empty clip_id")
        if clip_id in indexed:
            raise ValueError(f"{source_name}: duplicate clip_id detected")
        indexed[clip_id] = record
    return indexed


def _ordered_segments(record: dict[str, Any]) -> list[dict[str, Any]]:
    return sorted(
        (segment for segment in record.get("segments", []) if isinstance(segment, dict)),
        key=lambda segment: (
            int(segment.get("start_ms", 0)),
            int(segment.get("end_ms", 0)),
            str(segment.get("speaker_id", "")),
        ),
    )


def _transcript_text(record: dict[str, Any], source_name: str) -> str:
    top_level_text = record.get("text")
    if top_level_text is not None and not isinstance(top_level_text, str):
        raise ValueError(f"{source_name}: top-level text must be a string")

    ordered_segments = _ordered_segments(record)
    if any(not isinstance(segment.get("text"), str) for segment in ordered_segments):
        raise ValueError(f"{source_name}: every segment must contain string text")
    segment_text = " ".join(
        segment["text"].strip()
        for segment in ordered_segments
        if segment["text"].strip()
    ).strip()
    if isinstance(top_level_text, str) and segment_text:
        if normalize_text(top_level_text) != normalize_text(segment_text):
            raise ValueError(
                f"{source_name}: top-level text does not match canonical segment text"
            )
        return segment_text
    if segment_text:
        return segment_text
    return top_level_text.strip() if isinstance(top_level_text, str) else ""


def _speaker_segments(record: dict[str, Any]) -> list[dict[str, Any]]:
    segments: list[dict[str, Any]] = []
    for segment in _ordered_segments(record):
        if not all(key in segment for key in ("start_ms", "end_ms", "speaker_id")):
            continue
        segments.append(
            {
                "start_ms": segment["start_ms"],
                "end_ms": segment["end_ms"],
                "speaker_id": segment["speaker_id"],
            }
        )
    return segments


def _pseudonym(kind: str, value: str) -> str:
    encoded = f"{_PSEUDONYMIZATION_DOMAIN}\0{kind}\0{value}".encode("utf-8")
    digest = hashlib.sha256(encoded).hexdigest()[:20]
    return f"{kind}_{digest}"


def _public_speaker_metrics(metrics: dict[str, Any] | None) -> dict[str, Any] | None:
    if metrics is None:
        return None
    return {key: value for key, value in metrics.items() if key != "mapping"}


def _identity_pairs(
    gold_segments: list[dict[str, Any]],
    hypothesis_segments: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    pairs: list[dict[str, Any]] = []
    for gold_segment in gold_segments:
        reference_person_id = gold_segment.get("person_id")
        if reference_person_id is None:
            continue
        best_hypothesis: dict[str, Any] | None = None
        best_overlap = 0
        for hypothesis_segment in hypothesis_segments:
            overlap = min(gold_segment["end_ms"], hypothesis_segment["end_ms"]) - max(
                gold_segment["start_ms"], hypothesis_segment["start_ms"]
            )
            if overlap > best_overlap:
                best_overlap = overlap
                best_hypothesis = hypothesis_segment
        pairs.append(
            {
                "reference_person_id": reference_person_id,
                "predicted_person_id": (
                    best_hypothesis.get("person_id")
                    if best_hypothesis is not None and best_overlap > 0
                    else None
                ),
            }
        )
    return pairs


def _aggregate_error_counts(metrics: Iterable[dict[str, Any]]) -> dict[str, Any]:
    values = list(metrics)
    reference_words = sum(value["reference_words"] for value in values)
    hypothesis_words = sum(value["hypothesis_words"] for value in values)
    substitutions = sum(value["substitutions"] for value in values)
    deletions = sum(value["deletions"] for value in values)
    insertions = sum(value["insertions"] for value in values)
    reference_characters = sum(value["reference_characters"] for value in values)
    hypothesis_characters = sum(value["hypothesis_characters"] for value in values)
    character_errors = sum(value["character_errors"] for value in values)
    return {
        "clips": len(values),
        "reference_words": reference_words,
        "hypothesis_words": hypothesis_words,
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
        "errors": substitutions + deletions + insertions,
        "wer": (
            (substitutions + deletions + insertions) / reference_words
            if reference_words
            else None
        ),
        "deletion_rate": deletions / reference_words if reference_words else None,
        "insertion_rate": insertions / reference_words if reference_words else None,
        "reference_characters": reference_characters,
        "hypothesis_characters": hypothesis_characters,
        "character_errors": character_errors,
        "cer": character_errors / reference_characters if reference_characters else None,
    }


def _aggregate_critical(metrics: Iterable[dict[str, Any]]) -> dict[str, Any]:
    values = list(metrics)
    reference_occurrences = sum(value["reference_occurrences"] for value in values)
    matched_occurrences = sum(value["matched_occurrences"] for value in values)
    missed_occurrences = sum(value["missed_occurrences"] for value in values)
    hallucinated_occurrences = sum(value["hallucinated_occurrences"] for value in values)
    predicted_occurrences = matched_occurrences + hallucinated_occurrences
    return {
        "reference_occurrences": reference_occurrences,
        "matched_occurrences": matched_occurrences,
        "missed_occurrences": missed_occurrences,
        "hallucinated_occurrences": hallucinated_occurrences,
        "recall": matched_occurrences / reference_occurrences if reference_occurrences else None,
        "precision": matched_occurrences / predicted_occurrences if predicted_occurrences else None,
    }


def _aggregate_speakers(metrics: Iterable[dict[str, Any]]) -> dict[str, Any]:
    values = list(metrics)
    reference_speaker_ms = sum(value["reference_speaker_ms"] for value in values)
    missed_speaker_ms = sum(value["missed_speaker_ms"] for value in values)
    false_alarm_speaker_ms = sum(value["false_alarm_speaker_ms"] for value in values)
    confused_speaker_ms = sum(value["confused_speaker_ms"] for value in values)
    diarization_error_ms = missed_speaker_ms + false_alarm_speaker_ms + confused_speaker_ms
    return {
        "scored_clips": len(values),
        "speaker_count_exact_clips": sum(value["speaker_count_exact"] for value in values),
        "reference_speaker_ms": reference_speaker_ms,
        "missed_speaker_ms": missed_speaker_ms,
        "false_alarm_speaker_ms": false_alarm_speaker_ms,
        "confused_speaker_ms": confused_speaker_ms,
        "diarization_error_ms": diarization_error_ms,
        "der": diarization_error_ms / reference_speaker_ms if reference_speaker_ms else None,
    }


def build_report(
    gold_records: Iterable[dict[str, Any]],
    hypothesis_records: Iterable[dict[str, Any]],
) -> dict[str, Any]:
    gold_by_clip = _index_by_clip(gold_records, "gold")
    hypothesis_by_clip = _index_by_clip(hypothesis_records, "hypothesis")
    missing_hypotheses = sorted(set(gold_by_clip) - set(hypothesis_by_clip))
    unexpected_hypotheses = sorted(set(hypothesis_by_clip) - set(gold_by_clip))
    if missing_hypotheses or unexpected_hypotheses:
        raise ValueError(
            "Clip sets differ; "
            f"missing_count={len(missing_hypotheses)}, "
            f"unexpected_count={len(unexpected_hypotheses)}"
        )

    clip_reports: list[dict[str, Any]] = []
    grouped_text: dict[str, list[dict[str, Any]]] = defaultdict(list)
    all_text_metrics: list[dict[str, Any]] = []
    all_critical_metrics: list[dict[str, Any]] = []
    all_speaker_metrics: list[dict[str, Any]] = []
    all_identity_pairs: list[dict[str, Any]] = []

    for clip_id in sorted(gold_by_clip):
        gold = gold_by_clip[clip_id]
        hypothesis = hypothesis_by_clip[clip_id]
        gold_text = _transcript_text(gold, "gold")
        hypothesis_text = _transcript_text(hypothesis, "hypothesis")
        text = error_metrics(gold_text, hypothesis_text)
        critical = critical_term_metrics(
            gold_text,
            hypothesis_text,
            gold.get("critical_terms", []),
        )
        gold_speakers = _speaker_segments(gold)
        hypothesis_speakers = _speaker_segments(hypothesis)
        speakers = (
            speaker_metrics(gold_speakers, hypothesis_speakers)
            if gold_speakers or hypothesis_speakers
            else None
        )
        identities = _identity_pairs(gold.get("segments", []), hypothesis.get("segments", []))

        split = str(gold.get("split", "unspecified"))
        track = str(gold.get("track", "unspecified"))
        grouped_text[_pseudonym("group", f"split\0{split}")].append(text)
        grouped_text[_pseudonym("group", f"track\0{track}")].append(text)
        all_text_metrics.append(text)
        all_critical_metrics.append(critical)
        if speakers is not None:
            all_speaker_metrics.append(speakers)
        all_identity_pairs.extend(identities)

        clip_reports.append(
            {
                "clip_id": _pseudonym("clip", clip_id),
                "split_id": _pseudonym("split", split),
                "track_id": _pseudonym("track", track),
                "text": text,
                "critical_terms": {
                    key: value for key, value in critical.items() if key != "terms"
                },
                "speakers": _public_speaker_metrics(speakers),
                "identity_samples": len(identities),
            }
        )

    return {
        "report_version": 1,
        "privacy": {
            "contains_transcript_text": False,
            "contains_raw_identifiers": False,
            "contains_person_names": False,
            "person_identifiers_pseudonymized": True,
            "pseudonymization": "stable-linkable-sha256-domain-v1",
            "pseudonyms_linkable_across_reports": True,
            "anonymized": False,
            "speaker_assignment_details_omitted": True,
        },
        "summary": {
            "text": _aggregate_error_counts(all_text_metrics),
            "critical_terms": _aggregate_critical(all_critical_metrics),
            "speakers": _aggregate_speakers(all_speaker_metrics),
            "identity": identity_metrics(all_identity_pairs),
        },
        "groups": {
            group_name: _aggregate_error_counts(group_metrics)
            for group_name, group_metrics in sorted(grouped_text.items())
        },
        "clips": clip_reports,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gold", required=True, type=Path)
    parser.add_argument("--hypothesis", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--pretty", action="store_true")
    return parser


def _validate_report_output_path(output: Path, input_paths: Iterable[Path]) -> Path:
    expanded_output = output.expanduser()
    resolved_output = expanded_output.resolve(strict=False)
    for input_path in input_paths:
        expanded_input = input_path.expanduser()
        resolved_input = expanded_input.resolve(strict=True)
        if resolved_output == resolved_input:
            raise ValueError("Report output must not overwrite an input file.")
        if expanded_output.exists() and os.path.samefile(expanded_output, expanded_input):
            raise ValueError("Report output must not alias an input file.")
    return resolved_output


def _write_report_atomic(output: Path, encoded: str) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.",
        suffix=".tmp",
        dir=output.parent,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(encoded)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, output)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        output_path = (
            _validate_report_output_path(args.output, (args.gold, args.hypothesis))
            if args.output is not None
            else None
        )
        report = build_report(_load_jsonl(args.gold), _load_jsonl(args.hypothesis))
        encoded = json.dumps(
            report,
            ensure_ascii=False,
            indent=2 if args.pretty else None,
            sort_keys=True,
        )
        if output_path is None:
            print(encoded)
        else:
            _write_report_atomic(output_path, encoded)
        return 0
    except (OSError, RuntimeError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(json.dumps({"status": "error", "error": str(error)}, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
