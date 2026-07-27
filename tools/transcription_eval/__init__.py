"""Protected, local-only transcription evaluation helpers."""

from .corpus import CorpusSafetyError, build_manifest, validate_manifest
from .metrics import critical_term_metrics, error_metrics, identity_metrics, speaker_metrics
from .normalization import normalize_text, normalized_character_stream, normalized_tokens

__all__ = [
    "CorpusSafetyError",
    "build_manifest",
    "critical_term_metrics",
    "error_metrics",
    "identity_metrics",
    "normalize_text",
    "normalized_character_stream",
    "normalized_tokens",
    "speaker_metrics",
    "validate_manifest",
]
