from __future__ import annotations

import copy
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path

from tools.transcription_eval.report import build_report, main


class ReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.gold = [
            {
                "clip_id": "locked-001",
                "track": "system",
                "split": "locked",
                "critical_terms": ["Figma", "tomorrow"],
                "segments": [
                    {
                        "start_ms": 0,
                        "end_ms": 2_000,
                        "speaker_id": "gold-a",
                        "person_id": "person-private",
                        "text": "שלום Figma",
                    },
                    {
                        "start_ms": 2_000,
                        "end_ms": 4_000,
                        "speaker_id": "gold-b",
                        "text": "tomorrow",
                    },
                ],
            }
        ]
        self.hypothesis = [
            {
                "clip_id": "locked-001",
                "segments": [
                    {
                        "start_ms": 0,
                        "end_ms": 2_000,
                        "speaker_id": "SPEAKER_2",
                        "person_id": None,
                        "text": "שלום Figma",
                    },
                    {
                        "start_ms": 2_000,
                        "end_ms": 4_000,
                        "speaker_id": "SPEAKER_1",
                        "text": "today",
                    },
                ],
            }
        ]

    def test_report_aggregates_without_transcript_text_or_person_names(self) -> None:
        report = build_report(self.gold, self.hypothesis)
        encoded = json.dumps(report, ensure_ascii=False)

        self.assertFalse(report["privacy"]["contains_transcript_text"])
        self.assertFalse(report["privacy"]["contains_person_names"])
        self.assertFalse(report["privacy"]["contains_raw_identifiers"])
        self.assertTrue(report["privacy"]["person_identifiers_pseudonymized"])
        self.assertTrue(report["privacy"]["pseudonyms_linkable_across_reports"])
        self.assertFalse(report["privacy"]["anonymized"])
        self.assertNotIn("שלום", encoded)
        self.assertNotIn("person-private", encoded)
        self.assertNotIn("locked-001", encoded)
        self.assertNotIn('"locked"', encoded)
        self.assertNotIn('"system"', encoded)
        self.assertNotIn('"mapping"', encoded)
        self.assertEqual(report["summary"]["text"]["reference_words"], 3)
        self.assertEqual(report["summary"]["text"]["substitutions"], 1)
        self.assertEqual(report["summary"]["critical_terms"]["recall"], 0.5)
        self.assertEqual(report["summary"]["identity"]["abstentions"], 1)

    def test_report_pseudonymizes_alice_and_bob_identifiers_stably(self) -> None:
        gold = copy.deepcopy(self.gold)
        hypothesis = copy.deepcopy(self.hypothesis)
        gold[0]["clip_id"] = "Alice-private-call"
        gold[0]["split"] = "Alice-split"
        gold[0]["track"] = "Bob-track"
        gold[0]["segments"][0]["speaker_id"] = "Alice"
        gold[0]["segments"][0]["person_id"] = "Alice"
        gold[0]["segments"][1]["speaker_id"] = "Bob"
        hypothesis[0]["clip_id"] = "Alice-private-call"
        hypothesis[0]["segments"][0]["speaker_id"] = "Bob"
        hypothesis[0]["segments"][0]["person_id"] = "Bob"
        hypothesis[0]["segments"][1]["speaker_id"] = "Alice"

        first_report = build_report(gold, hypothesis)
        second_report = build_report(gold, hypothesis)
        encoded = json.dumps(first_report, ensure_ascii=False)

        self.assertEqual(first_report, second_report)
        self.assertNotIn("Alice", encoded)
        self.assertNotIn("Bob", encoded)
        self.assertNotIn("mapping", encoded)
        self.assertRegex(first_report["clips"][0]["clip_id"], r"^clip_[0-9a-f]{20}$")
        self.assertRegex(first_report["clips"][0]["split_id"], r"^split_[0-9a-f]{20}$")
        self.assertRegex(first_report["clips"][0]["track_id"], r"^track_[0-9a-f]{20}$")

    def test_report_rejects_top_level_text_that_disagrees_with_segments(self) -> None:
        gold = copy.deepcopy(self.gold)
        gold[0]["text"] = "This contradicts the segment transcript."

        with self.assertRaisesRegex(ValueError, "does not match canonical segment text"):
            build_report(gold, self.hypothesis)

    def test_report_rejects_mismatched_clip_sets(self) -> None:
        with self.assertRaisesRegex(ValueError, "Clip sets differ"):
            build_report(self.gold, [])

    def test_cli_writes_privacy_safe_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            gold_path = root / "gold.jsonl"
            hypothesis_path = root / "hypothesis.jsonl"
            output_path = root / "report.json"
            gold_path.write_text(
                "\n".join(json.dumps(record, ensure_ascii=False) for record in self.gold) + "\n",
                encoding="utf-8",
            )
            hypothesis_path.write_text(
                "\n".join(json.dumps(record, ensure_ascii=False) for record in self.hypothesis) + "\n",
                encoding="utf-8",
            )

            exit_code = main(
                [
                    "--gold",
                    str(gold_path),
                    "--hypothesis",
                    str(hypothesis_path),
                    "--output",
                    str(output_path),
                    "--pretty",
                ]
            )

            self.assertEqual(exit_code, 0)
            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(report["report_version"], 1)

    def test_cli_refuses_to_overwrite_or_alias_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            gold_path = root / "gold.jsonl"
            hypothesis_path = root / "hypothesis.jsonl"
            alias_path = root / "gold-alias.jsonl"
            original_gold = (
                "\n".join(json.dumps(record, ensure_ascii=False) for record in self.gold) + "\n"
            )
            gold_path.write_text(original_gold, encoding="utf-8")
            hypothesis_path.write_text(
                "\n".join(json.dumps(record, ensure_ascii=False) for record in self.hypothesis)
                + "\n",
                encoding="utf-8",
            )
            os.link(gold_path, alias_path)

            stderr = StringIO()
            with redirect_stderr(stderr):
                direct_exit = main(
                    [
                        "--gold",
                        str(gold_path),
                        "--hypothesis",
                        str(hypothesis_path),
                        "--output",
                        str(gold_path),
                    ]
                )
                alias_exit = main(
                    [
                        "--gold",
                        str(gold_path),
                        "--hypothesis",
                        str(hypothesis_path),
                        "--output",
                        str(alias_path),
                    ]
                )

            self.assertEqual(direct_exit, 2)
            self.assertEqual(alias_exit, 2)
            self.assertEqual(gold_path.read_text(encoding="utf-8"), original_gold)
            self.assertIn("must not overwrite", stderr.getvalue())
            self.assertIn("must not alias", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
