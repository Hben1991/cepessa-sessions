"""Strict validation of ``session.json`` against the desktop app's Swift models.

A manifest that the app itself could not decode is rejected here too, so the
MCP server never serves a transcript the app would refuse to show.
"""

import math
import re
from datetime import datetime
from pathlib import Path
from typing import Any
from uuid import UUID

SESSION_ID_PATTERN = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
SWIFT_ISO8601_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"
)
SESSION_STATUS_VALUES = {"recording", "transcribing", "ready", "failed"}
SESSION_TITLE_ORIGIN_VALUES = {"automatic", "user", "imported"}
SESSION_SOURCE_VALUES = {"microphone", "system", "mixed", "imported"}
SESSION_IDENTITY_VALUES = {"anonymous", "confirmed", "unavailable"}
SESSION_CONTENT_TYPE_VALUES = {
    "meeting",
    "voiceNote",
    "videoCommentary",
    "generalTranscript",
}
SESSION_ATTACHMENT_KIND_VALUES = {"file", "image", "audio", "link", "capture"}
SESSION_ATTACHMENT_SOURCE_VALUES = {
    "manual",
    "transcript",
    "floatingBar",
    "imported",
}
SESSION_CAPTURE_KIND_VALUES = {
    "floatingBarCapture",
    "screenCapture",
    "clipboardCapture",
    "note",
}
SESSION_EVIDENCE_DISPOSITION_VALUES = {"ready", "degraded", "failed"}
SESSION_CHAT_ROLE_VALUES = {"user", "assistant"}
SESSION_CHAT_STATUS_VALUES = {"idle", "sending", "failed"}
SESSION_DOCUMENT_OPERATION_VALUES = {"read", "update", "delete"}


class SessionValidationError(ValueError):
    """Raised when a session cannot be decoded by the Swift app models."""


def validate_session_id(value: Any, field: str) -> str:
    if not isinstance(value, str) or not SESSION_ID_PATTERN.fullmatch(value):
        raise SessionValidationError(f"{field} must be a UUID string.")
    try:
        UUID(value)
    except ValueError as error:
        raise SessionValidationError(f"{field} must be a UUID string.") from error
    return value


LEGACY_OFFSET_PATTERN = re.compile(r"^\d+(?:\.\d+)?(?::\d+(?:\.\d+)?){0,2}$")


def legacy_offset_seconds(value: str) -> float | None:
    """Seconds for the earliest format's "SS", "MM:SS" or "H:MM:SS" segment times."""
    if not isinstance(value, str) or not LEGACY_OFFSET_PATTERN.match(value):
        return None
    seconds = 0.0
    for part in value.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def parse_date(value: str) -> datetime:
    """Parse a date string that already passed ``_expect_date``."""
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _expect_object(value: Any, path: str) -> dict:
    if not isinstance(value, dict):
        raise SessionValidationError(f"{path} must be an object.")
    return value


def _expect_list(value: Any, path: str) -> list:
    if not isinstance(value, list):
        raise SessionValidationError(f"{path} must be an array.")
    return value


def _expect_string(value: Any, path: str) -> str:
    if not isinstance(value, str):
        raise SessionValidationError(f"{path} must be a string.")
    return value


def _expect_number(value: Any, path: str) -> float | int:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
    ):
        raise SessionValidationError(f"{path} must be a finite number.")
    return value


def _expect_integer(value: Any, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise SessionValidationError(f"{path} must be an integer.")
    return value


def _expect_bool(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        raise SessionValidationError(f"{path} must be a boolean.")
    return value


def _expect_enum(value: Any, values: set[str], path: str) -> str:
    value = _expect_string(value, path)
    if value not in values:
        raise SessionValidationError(f"{path} has unsupported value: {value}")
    return value


def _expect_date(value: Any, path: str) -> str:
    value = _expect_string(value, path)
    if not SWIFT_ISO8601_PATTERN.fullmatch(value):
        raise SessionValidationError(
            f"{path} must be an ISO-8601 date supported by Swift."
        )
    try:
        parse_date(value)
    except ValueError as error:
        raise SessionValidationError(
            f"{path} must be a valid ISO-8601 date."
        ) from error
    return value


def _validate_json_value(value: Any, path: str = "value") -> None:
    if value is None or isinstance(value, (str, bool, int)):
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            raise SessionValidationError(f"{path} contains a non-finite number.")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_json_value(item, f"{path}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise SessionValidationError(f"{path} has a non-string object key.")
            _validate_json_value(item, f"{path}.{key}")
        return
    raise SessionValidationError(
        f"{path} contains a value that cannot be represented as JSON."
    )


def _decoded_array(value: dict, key: str, path: str) -> list:
    """Match Swift ``decodeIfPresent(...) ?? []`` for legacy null arrays."""
    raw = value.get(key)
    return [] if raw is None else _expect_list(raw, f"{path}.{key}")


def _safe_bundle_filename(value: Any, path: str) -> str:
    value = _expect_string(value, path)
    if not value or value in {".", ".."} or "\x00" in value:
        raise SessionValidationError(f"{path} must be a safe file name.")
    if (
        Path(value).name != value
        or "/" in value
        or "\\" in value
        or Path(value).is_absolute()
    ):
        raise SessionValidationError(f"{path} must be a safe file name.")
    return value


def _validate_transcript_segment(segment: Any, path: str) -> None:
    segment = _expect_object(segment, path)
    # The earliest recordings have no segment id and store the time as an
    # offset from the start; the app converts both on load, and so does this.
    if segment.get("id") is not None:
        validate_session_id(segment["id"], f"{path}.id")
    _expect_string(segment.get("speaker"), f"{path}.speaker")
    _expect_string(segment.get("text"), f"{path}.text")
    if legacy_offset_seconds(segment.get("timestamp")) is None:
        _expect_date(segment.get("timestamp"), f"{path}.timestamp")
    if segment.get("endTimestamp") is not None:
        _expect_date(segment["endTimestamp"], f"{path}.endTimestamp")
    if segment.get("speakerID") is not None:
        _expect_string(segment["speakerID"], f"{path}.speakerID")
    if segment.get("source") is not None:
        _expect_enum(segment["source"], SESSION_SOURCE_VALUES, f"{path}.source")
    if segment.get("identityStatus") is not None:
        _expect_enum(
            segment["identityStatus"], SESSION_IDENTITY_VALUES, f"{path}.identityStatus"
        )
    if segment.get("uncertainty") is not None:
        for index, item in enumerate(
            _expect_list(segment["uncertainty"], f"{path}.uncertainty")
        ):
            _expect_string(item, f"{path}.uncertainty[{index}]")


def _validate_recap_section(section: Any, path: str) -> None:
    section = _expect_object(section, path)
    validate_session_id(section.get("id"), f"{path}.id")
    # Swift's custom decoder maps unknown recap kinds to `.notes`, so any string
    # kind is accepted here to match that forward-compatible behavior.
    _expect_string(section.get("kind"), f"{path}.kind")
    _expect_string(section.get("title"), f"{path}.title")
    _expect_string(section.get("summary"), f"{path}.summary")
    for index, bullet in enumerate(
        _expect_list(section.get("bullets"), f"{path}.bullets")
    ):
        _expect_string(bullet, f"{path}.bullets[{index}]")
    if section.get("anchorTimestamp") is not None:
        _expect_date(section["anchorTimestamp"], f"{path}.anchorTimestamp")
    for key in ("startOffset", "endOffset"):
        if section.get(key) is not None:
            _expect_number(section[key], f"{path}.{key}")


def _validate_recap(recap: Any, path: str) -> None:
    recap = _expect_object(recap, path)
    _expect_string(recap.get("overview"), f"{path}.overview")
    if recap.get("generatedAt") is not None:
        _expect_date(recap["generatedAt"], f"{path}.generatedAt")
    for index, section in enumerate(
        _expect_list(recap.get("sections"), f"{path}.sections")
    ):
        _validate_recap_section(section, f"{path}.sections[{index}]")


def _validate_attachment(attachment: Any, path: str) -> None:
    attachment = _expect_object(attachment, path)
    validate_session_id(attachment.get("id"), f"{path}.id")
    _expect_enum(attachment.get("kind"), SESSION_ATTACHMENT_KIND_VALUES, f"{path}.kind")
    _expect_enum(
        attachment.get("source"), SESSION_ATTACHMENT_SOURCE_VALUES, f"{path}.source"
    )
    _expect_string(attachment.get("title"), f"{path}.title")
    _expect_date(attachment.get("timestamp"), f"{path}.timestamp")
    if attachment.get("sessionOffset") is not None:
        _expect_number(attachment["sessionOffset"], f"{path}.sessionOffset")
    for key in ("fileName", "mimeType", "urlString", "note"):
        if attachment.get(key) is not None:
            _expect_string(attachment[key], f"{path}.{key}")
    if attachment.get("transcriptSegmentID") is not None:
        validate_session_id(
            attachment["transcriptSegmentID"], f"{path}.transcriptSegmentID"
        )


def _validate_capture_artifact(artifact: Any, path: str) -> None:
    artifact = _expect_object(artifact, path)
    validate_session_id(artifact.get("id"), f"{path}.id")
    _expect_enum(artifact.get("kind"), SESSION_CAPTURE_KIND_VALUES, f"{path}.kind")
    _expect_string(artifact.get("title"), f"{path}.title")
    _expect_date(artifact.get("capturedAt"), f"{path}.capturedAt")
    if artifact.get("sessionOffset") is not None:
        _expect_number(artifact["sessionOffset"], f"{path}.sessionOffset")
    for index, identifier in enumerate(
        _expect_list(artifact.get("attachmentIDs"), f"{path}.attachmentIDs")
    ):
        validate_session_id(identifier, f"{path}.attachmentIDs[{index}]")
    if artifact.get("notes") is not None:
        _expect_string(artifact["notes"], f"{path}.notes")
    if artifact.get("transcriptSegmentID") is not None:
        validate_session_id(
            artifact["transcriptSegmentID"], f"{path}.transcriptSegmentID"
        )


def _validate_audio_artifacts(audio: Any, path: str) -> None:
    audio = _expect_object(audio, path)
    for key in (
        "micFileName",
        "micTranscriptFileName",
        "systemFileName",
        "mixedFileName",
    ):
        if audio.get(key) is not None:
            _expect_string(audio[key], f"{path}.{key}")
    if audio.get("importedFileName") is not None:
        _safe_bundle_filename(audio["importedFileName"], f"{path}.importedFileName")


def _validate_content_classification(classification: Any, path: str) -> None:
    classification = _expect_object(classification, path)
    _expect_enum(
        classification.get("type"), SESSION_CONTENT_TYPE_VALUES, f"{path}.type"
    )
    _expect_number(classification.get("confidence"), f"{path}.confidence")
    _expect_string(classification.get("rationale"), f"{path}.rationale")
    _expect_date(classification.get("generatedAt"), f"{path}.generatedAt")


def _validate_transcription_evidence(evidence: Any, path: str) -> None:
    evidence = _expect_object(evidence, path)
    _expect_string(evidence.get("runID"), f"{path}.runID")
    _expect_integer(evidence.get("revision"), f"{path}.revision")
    _expect_enum(
        evidence.get("disposition"),
        SESSION_EVIDENCE_DISPOSITION_VALUES,
        f"{path}.disposition",
    )
    _expect_string(evidence.get("contentHash"), f"{path}.contentHash")
    if evidence.get("parentContentHash") is not None:
        _expect_string(evidence["parentContentHash"], f"{path}.parentContentHash")
    _expect_string(evidence.get("runFileName"), f"{path}.runFileName")
    _expect_string(evidence.get("outboxFileName"), f"{path}.outboxFileName")
    for index, issue in enumerate(
        _expect_list(evidence.get("issues"), f"{path}.issues")
    ):
        _expect_string(issue, f"{path}.issues[{index}]")
    if evidence.get("isComplete") is not None:
        _expect_bool(evidence["isComplete"], f"{path}.isComplete")
    if evidence.get("speechCoverage") is not None:
        coverage = _expect_number(evidence["speechCoverage"], f"{path}.speechCoverage")
        if not 0 <= coverage <= 1:
            raise SessionValidationError(
                f"{path}.speechCoverage must be between 0 and 1."
            )
    if evidence.get("hasVerifiableTimestamps") is not None:
        _expect_bool(
            evidence["hasVerifiableTimestamps"], f"{path}.hasVerifiableTimestamps"
        )


def _validate_source_citation(citation: Any, path: str) -> None:
    citation = _expect_object(citation, path)
    validate_session_id(citation.get("id"), f"{path}.id")
    if citation.get("segmentID") is not None:
        validate_session_id(citation["segmentID"], f"{path}.segmentID")
    _expect_string(citation.get("title"), f"{path}.title")
    _expect_string(citation.get("excerpt"), f"{path}.excerpt")


def _validate_recap_patch(patch: Any, path: str) -> None:
    patch = _expect_object(patch, path)
    if patch.get("overview") is not None:
        _expect_string(patch["overview"], f"{path}.overview")
    for index, section in enumerate(
        _expect_list(patch.get("sections"), f"{path}.sections")
    ):
        section_path = f"{path}.sections[{index}]"
        section = _expect_object(section, section_path)
        _expect_string(section.get("kind"), f"{section_path}.kind")
        _expect_string(section.get("title"), f"{section_path}.title")
        _expect_string(section.get("summary"), f"{section_path}.summary")
        for bullet_index, bullet in enumerate(
            _expect_list(section.get("bullets"), f"{section_path}.bullets")
        ):
            _expect_string(bullet, f"{section_path}.bullets[{bullet_index}]")


def _validate_edit_proposal(proposal: Any, path: str) -> None:
    proposal = _expect_object(proposal, path)
    _expect_string(proposal.get("assistantMessage"), f"{path}.assistantMessage")
    if proposal.get("operation") is not None:
        _expect_enum(
            proposal["operation"],
            SESSION_DOCUMENT_OPERATION_VALUES,
            f"{path}.operation",
        )
    for key in ("sessionTitle", "documentMarkdown"):
        if proposal.get(key) is not None:
            _expect_string(proposal[key], f"{path}.{key}")
    if proposal.get("recapPatch") is not None:
        _validate_recap_patch(proposal["recapPatch"], f"{path}.recapPatch")
    for index, patch in enumerate(_decoded_array(proposal, "transcriptPatches", path)):
        patch_path = f"{path}.transcriptPatches[{index}]"
        patch = _expect_object(patch, patch_path)
        validate_session_id(patch.get("segmentID"), f"{patch_path}.segmentID")
        _expect_string(patch.get("text"), f"{patch_path}.text")
    for index, rename in enumerate(_decoded_array(proposal, "speakerRenames", path)):
        rename_path = f"{path}.speakerRenames[{index}]"
        rename = _expect_object(rename, rename_path)
        _expect_string(rename.get("oldName"), f"{rename_path}.oldName")
        _expect_string(rename.get("newName"), f"{rename_path}.newName")
    for index, item in enumerate(_decoded_array(proposal, "warnings", path)):
        _expect_string(item, f"{path}.warnings[{index}]")
    for index, citation in enumerate(_decoded_array(proposal, "sourceCitations", path)):
        _validate_source_citation(citation, f"{path}.sourceCitations[{index}]")


def _validate_undo_snapshot(snapshot: Any, path: str) -> None:
    snapshot = _expect_object(snapshot, path)
    _expect_string(snapshot.get("title"), f"{path}.title")
    if snapshot.get("documentMarkdown") is not None:
        _expect_string(snapshot["documentMarkdown"], f"{path}.documentMarkdown")
    _validate_recap(snapshot.get("recap"), f"{path}.recap")
    for index, segment in enumerate(
        _expect_list(snapshot.get("transcriptSegments"), f"{path}.transcriptSegments")
    ):
        _validate_transcript_segment(segment, f"{path}.transcriptSegments[{index}]")
    _expect_date(snapshot.get("createdAt"), f"{path}.createdAt")


def _validate_document_chat(chat: Any, path: str) -> None:
    chat = _expect_object(chat, path)
    for index, message in enumerate(
        _expect_list(chat.get("messages"), f"{path}.messages")
    ):
        message_path = f"{path}.messages[{index}]"
        message = _expect_object(message, message_path)
        validate_session_id(message.get("id"), f"{message_path}.id")
        _expect_enum(
            message.get("role"), SESSION_CHAT_ROLE_VALUES, f"{message_path}.role"
        )
        _expect_string(message.get("text"), f"{message_path}.text")
        _expect_date(message.get("createdAt"), f"{message_path}.createdAt")
        for citation_index, citation in enumerate(
            _decoded_array(message, "sourceCitations", message_path)
        ):
            _validate_source_citation(
                citation, f"{message_path}.sourceCitations[{citation_index}]"
            )
    if chat.get("pendingProposal") is not None:
        _validate_edit_proposal(chat["pendingProposal"], f"{path}.pendingProposal")
    if chat.get("undoSnapshot") is not None:
        _validate_undo_snapshot(chat["undoSnapshot"], f"{path}.undoSnapshot")
    _expect_enum(chat.get("status"), SESSION_CHAT_STATUS_VALUES, f"{path}.status")
    if chat.get("errorMessage") is not None:
        _expect_string(chat["errorMessage"], f"{path}.errorMessage")
    for key in ("createdAt", "updatedAt"):
        if chat.get(key) is not None:
            _expect_date(chat[key], f"{path}.{key}")


def validate_session(session: Any, session_id: str | None = None) -> dict:
    """Validate a decoded manifest; ``session_id`` is its directory name."""
    session = _expect_object(session, "session")
    _validate_json_value(session, "session")
    identifier = validate_session_id(session.get("id"), "session.id")
    if session_id is not None:
        requested_id = validate_session_id(session_id, "session ID")
        if identifier.casefold() != requested_id.casefold():
            raise SessionValidationError("session.id must match its directory ID.")
    _expect_string(session.get("title"), "session.title")
    if session.get("titleOrigin") is not None:
        _expect_enum(
            session["titleOrigin"], SESSION_TITLE_ORIGIN_VALUES, "session.titleOrigin"
        )
    if session.get("processingError") is not None:
        _expect_string(session["processingError"], "session.processingError")
    _expect_date(session.get("startedAt"), "session.startedAt")
    _expect_enum(session.get("status"), SESSION_STATUS_VALUES, "session.status")
    for key in ("transcriptSegments", "segments"):
        if session.get(key) is not None:
            for index, segment in enumerate(
                _expect_list(session[key], f"session.{key}")
            ):
                _validate_transcript_segment(segment, f"session.{key}[{index}]")
    if session.get("recap") is not None:
        _validate_recap(session["recap"], "session.recap")
    if session.get("attachments") is not None:
        for index, attachment in enumerate(
            _expect_list(session["attachments"], "session.attachments")
        ):
            _validate_attachment(attachment, f"session.attachments[{index}]")
    if session.get("captureArtifacts") is not None:
        for index, artifact in enumerate(
            _expect_list(session["captureArtifacts"], "session.captureArtifacts")
        ):
            _validate_capture_artifact(artifact, f"session.captureArtifacts[{index}]")
    if session.get("audioArtifacts") is not None:
        _validate_audio_artifacts(session["audioArtifacts"], "session.audioArtifacts")
    if session.get("contentClassification") is not None:
        _validate_content_classification(
            session["contentClassification"], "session.contentClassification"
        )
    for key in ("transcriptionEvidence", "latestTranscriptionAttempt"):
        if session.get(key) is not None:
            _validate_transcription_evidence(session[key], f"session.{key}")
    if session.get("documentMarkdown") is not None:
        _expect_string(session["documentMarkdown"], "session.documentMarkdown")
    if session.get("documentChat") is not None:
        _validate_document_chat(session["documentChat"], "session.documentChat")
    return session
