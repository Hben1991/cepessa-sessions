from __future__ import annotations

import unittest

from tools.transcription_eval.metrics import (
    critical_term_metrics,
    error_metrics,
    identity_metrics,
    speaker_metrics,
)
from tools.transcription_eval.normalization import (
    normalize_text,
    normalized_character_stream,
    normalized_tokens,
    token_language,
)


class NormalizationTests(unittest.TestCase):
    def test_mixed_hebrew_english_normalization_preserves_words_without_bidi_or_diacritics(self) -> None:
        text = "\u2067שָׁלוֹם,\u2069 Figma’s FILE — מָחָר!"

        self.assertEqual(normalize_text(text), "שלום figmas file מחר")
        self.assertEqual(normalized_tokens(text), ["שלום", "figmas", "file", "מחר"])
        self.assertEqual("".join(normalized_character_stream(text)), "שלוםfigmasfileמחר")

    def test_language_detection_does_not_transliterate(self) -> None:
        self.assertEqual(token_language("שלום"), "he")
        self.assertEqual(token_language("figma"), "en")
        self.assertEqual(token_language("גרסה2"), "he")
        self.assertEqual(token_language("v2"), "en")
        self.assertEqual(token_language("2026"), "other")


class TextMetricTests(unittest.TestCase):
    def test_wer_cer_deletion_and_insertion_counts(self) -> None:
        result = error_metrics(
            "שלום open the Figma file tomorrow",
            "שלום open Figma file tomorrow extra",
        )

        self.assertEqual(result["reference_words"], 6)
        self.assertEqual(result["deletions"], 1)
        self.assertEqual(result["insertions"], 1)
        self.assertEqual(result["substitutions"], 0)
        self.assertAlmostEqual(result["wer"], 2 / 6)
        self.assertGreater(result["cer"], 0)

    def test_substitution_is_preferred_over_delete_plus_insert(self) -> None:
        result = error_metrics("alpha beta", "alpha gamma")

        self.assertEqual(result["substitutions"], 1)
        self.assertEqual(result["deletions"], 0)
        self.assertEqual(result["insertions"], 0)

    def test_empty_reference_reports_undefined_rates_without_dividing_by_zero(self) -> None:
        result = error_metrics("", "invented")

        self.assertIsNone(result["wer"])
        self.assertIsNone(result["cer"])
        self.assertEqual(result["insertions"], 1)

    def test_critical_term_metrics_count_misses_and_hallucinations(self) -> None:
        result = critical_term_metrics(
            "Open the Figma design file tomorrow",
            "Open Figma tomorrow Webflow",
            ["Figma", "design file", "Webflow"],
        )

        self.assertEqual(result["reference_occurrences"], 2)
        self.assertEqual(result["matched_occurrences"], 1)
        self.assertEqual(result["missed_occurrences"], 1)
        self.assertEqual(result["hallucinated_occurrences"], 1)
        self.assertEqual(result["recall"], 0.5)
        self.assertEqual(result["precision"], 0.5)


class SpeakerMetricTests(unittest.TestCase):
    def test_permuted_anonymous_speaker_labels_score_as_correct(self) -> None:
        reference = [
            {"start_ms": 0, "end_ms": 2_000, "speaker_id": "person-a"},
            {"start_ms": 2_000, "end_ms": 4_000, "speaker_id": "person-b"},
        ]
        hypothesis = [
            {"start_ms": 0, "end_ms": 2_000, "speaker_id": "SPEAKER_2"},
            {"start_ms": 2_000, "end_ms": 4_000, "speaker_id": "SPEAKER_1"},
        ]

        result = speaker_metrics(reference, hypothesis, collar_ms=0)

        self.assertEqual(result["mapping"], {"SPEAKER_1": "person-b", "SPEAKER_2": "person-a"})
        self.assertEqual(result["der"], 0)
        self.assertTrue(result["speaker_count_exact"])

    def test_speaker_confusion_contributes_to_der(self) -> None:
        reference = [
            {"start_ms": 0, "end_ms": 1_000, "speaker_id": "a"},
            {"start_ms": 1_000, "end_ms": 2_000, "speaker_id": "b"},
        ]
        hypothesis = [
            {"start_ms": 0, "end_ms": 2_000, "speaker_id": "one"},
        ]

        result = speaker_metrics(reference, hypothesis, collar_ms=0)

        self.assertFalse(result["speaker_count_exact"])
        self.assertGreater(result["der"], 0)
        self.assertEqual(result["reference_speaker_ms"], 2_000)

    def test_collar_cuts_partial_interval_instead_of_discarding_it(self) -> None:
        reference = [
            {"start_ms": 0, "end_ms": 1_000, "speaker_id": "a"},
        ]
        hypothesis = [
            {"start_ms": 300, "end_ms": 1_000, "speaker_id": "speaker-1"},
        ]

        result = speaker_metrics(reference, hypothesis, collar_ms=250)

        self.assertEqual(result["reference_speaker_ms"], 500)
        self.assertEqual(result["missed_speaker_ms"], 50)
        self.assertEqual(result["diarization_error_ms"], 50)
        self.assertEqual(result["der"], 0.1)

    def test_adjacent_same_speaker_segments_do_not_create_collars_or_turns(self) -> None:
        reference = [
            {"start_ms": 0, "end_ms": 400, "speaker_id": "a"},
            {"start_ms": 400, "end_ms": 800, "speaker_id": "a"},
            {"start_ms": 800, "end_ms": 1_200, "speaker_id": "a"},
        ]

        result = speaker_metrics(reference, [], collar_ms=250)

        self.assertEqual(result["reference_speaker_ms"], 700)
        self.assertEqual(result["missed_speaker_ms"], 700)
        self.assertEqual(result["diarization_error_ms"], 700)
        self.assertEqual(result["der"], 1.0)
        self.assertEqual(result["turn_boundaries"]["reference_boundaries"], 0)
        self.assertEqual(result["turn_boundaries"]["hypothesis_boundaries"], 0)

    def test_overlap_is_counted_as_speaker_time(self) -> None:
        reference = [
            {"start_ms": 0, "end_ms": 2_000, "speaker_id": "a"},
            {"start_ms": 1_000, "end_ms": 3_000, "speaker_id": "b"},
        ]
        hypothesis = [
            {"start_ms": 0, "end_ms": 3_000, "speaker_id": "one"},
        ]

        result = speaker_metrics(reference, hypothesis, collar_ms=0)

        self.assertEqual(result["reference_speaker_ms"], 4_000)
        self.assertGreaterEqual(result["missed_speaker_ms"], 1_000)

    def test_identity_metrics_reward_abstention_over_false_confidence_separately(self) -> None:
        result = identity_metrics(
            [
                {"reference_person_id": "person-a", "predicted_person_id": "person-a"},
                {"reference_person_id": "person-b", "predicted_person_id": None},
                {"reference_person_id": "person-c", "predicted_person_id": "person-x"},
            ]
        )

        self.assertEqual(result["correct_predictions"], 1)
        self.assertEqual(result["false_predictions"], 1)
        self.assertEqual(result["abstentions"], 1)
        self.assertEqual(result["precision"], 0.5)
        self.assertAlmostEqual(result["recall"], 1 / 3)


if __name__ == "__main__":
    unittest.main()
