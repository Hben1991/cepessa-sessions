import json
import os
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

import pytest

from mcp_server_omi.server import (
    LocalSessionLockError,
    LocalSessionPathError,
    LocalSessionValidationError,
    UpdateLocalSessionFields,
    get_local_clip,
    get_local_session_data,
    list_local_session_files,
    list_local_clips,
    list_local_sessions,
    search_local_session_transcripts,
    update_local_session_fields,
    update_local_session_title,
)


def identifier(label: str) -> str:
    return str(uuid5(NAMESPACE_URL, f"cepessa-mcp-robustness:{label}"))


SESSION_ID = identifier("session")
HEALTHY_ID = identifier("healthy")
SEGMENT_ID = identifier("segment")
ATTACHMENT_ID = identifier("attachment")
CAPTURE_ID = identifier("capture")
CHAT_MESSAGE_ID = identifier("chat-message")
CITATION_ID = identifier("citation")


def session_payload(
    session_id: str = SESSION_ID, *, text: str = "Keep this transcript"
) -> dict:
    return {
        "id": session_id,
        "title": "Robustness fixture",
        "startedAt": "2026-09-07T08:00:00Z",
        "status": "ready",
        "transcriptSegments": [
            {
                "id": SEGMENT_ID,
                "speaker": "You",
                "text": text,
                "timestamp": "2026-09-07T08:00:01Z",
            }
        ],
    }


def write_manifest(
    root: Path, session_id: str = SESSION_ID, payload: dict | None = None
) -> Path:
    session_directory = root / session_id
    session_directory.mkdir(parents=True)
    path = session_directory / "session.json"
    path.write_text(
        json.dumps(payload or session_payload(session_id)), encoding="utf-8"
    )
    return path


def read_bytes(path: Path) -> bytes:
    return path.read_bytes()


def test_invalid_update_is_rejected_before_write_and_healthy_search_survives(tmp_path):
    path = write_manifest(tmp_path)
    healthy_path = write_manifest(
        tmp_path, HEALTHY_ID, session_payload(HEALTHY_ID, text="Healthy evidence")
    )
    before = read_bytes(path)

    with pytest.raises(LocalSessionValidationError, match="status"):
        update_local_session_fields(
            SESSION_ID, {"status": "not-a-swift-status"}, str(tmp_path)
        )

    assert read_bytes(path) == before
    path.write_text(
        json.dumps({**session_payload(SESSION_ID), "status": "not-a-swift-status"}),
        encoding="utf-8",
    )
    listed = list_local_sessions(str(tmp_path))
    assert [session["id"] for session in listed] == [HEALTHY_ID]
    matches = search_local_session_transcripts("healthy evidence", str(tmp_path))
    assert [session["id"] for session in matches] == [HEALTHY_ID]
    assert healthy_path.exists()


@pytest.mark.parametrize(
    ("field", "value", "error_fragment"),
    [
        ("transcriptSegments", [42], "transcriptSegments"),
        (
            "recap",
            {"overview": "bad", "sections": [{"id": ATTACHMENT_ID}]},
            "recap.sections",
        ),
        ("attachments", [{"id": ATTACHMENT_ID, "kind": "image"}], "attachments"),
        ("documentChat", {"messages": [], "status": 42}, "documentChat.status"),
    ],
)
def test_invalid_nested_candidate_never_changes_manifest(
    tmp_path, field, value, error_fragment
):
    path = write_manifest(tmp_path)
    before = read_bytes(path)

    with pytest.raises(LocalSessionValidationError, match=error_fragment):
        update_local_session_fields(SESSION_ID, {field: value}, str(tmp_path))

    assert read_bytes(path) == before


def test_valid_swift_shaped_update_preserves_unknown_extensions(tmp_path):
    path = write_manifest(
        tmp_path,
        payload={
            **session_payload(),
            "futureFeature": {"enabled": True, "vendorPayload": ["keep", 2]},
        },
    )
    update = {
        "titleOrigin": "user",
        "processingError": None,
        "recap": {
            "overview": "A complete recap",
            "generatedAt": "2026-09-07T08:05:00Z",
            "sections": [
                {
                    "id": identifier("recap-section"),
                    "kind": "keyPoints",
                    "title": "Key point",
                    "summary": "A summary",
                    "bullets": ["One bullet"],
                    "anchorTimestamp": "2026-09-07T08:00:02Z",
                    "startOffset": 1.5,
                    "endOffset": 2,
                }
            ],
        },
        "attachments": [
            {
                "id": ATTACHMENT_ID,
                "kind": "capture",
                "source": "floatingBar",
                "title": "Screen capture",
                "timestamp": "2026-09-07T08:01:00Z",
                "sessionOffset": 60,
                "fileName": "screen.png",
                "mimeType": "image/png",
                "urlString": "file:///safe/screen.png",
                "note": "Extension-safe attachment",
                "transcriptSegmentID": SEGMENT_ID,
            }
        ],
        "captureArtifacts": [
            {
                "id": CAPTURE_ID,
                "kind": "screenCapture",
                "title": "Screen",
                "capturedAt": "2026-09-07T08:01:00Z",
                "sessionOffset": 60,
                "attachmentIDs": [ATTACHMENT_ID],
                "notes": "A capture note",
                "transcriptSegmentID": SEGMENT_ID,
            }
        ],
        "audioArtifacts": {
            "micFileName": "mic.wav",
            "micTranscriptFileName": "mic.json",
            "systemFileName": None,
            "mixedFileName": "mixed.wav",
        },
        "contentClassification": {
            "type": "meeting",
            "confidence": 0.9,
            "rationale": "Fixture",
            "generatedAt": "2026-09-07T08:05:00Z",
        },
        "transcriptionEvidence": {
            "runID": "run-1",
            "revision": 1,
            "disposition": "ready",
            "contentHash": "hash",
            "parentContentHash": None,
            "runFileName": "run.json",
            "outboxFileName": "outbox.json",
            "issues": [],
        },
        "documentMarkdown": "# Notes",
        "documentChat": {
            "messages": [
                {
                    "id": CHAT_MESSAGE_ID,
                    "role": "assistant",
                    "text": "A cited answer",
                    "createdAt": "2026-09-07T08:06:00Z",
                    "sourceCitations": [
                        {
                            "id": CITATION_ID,
                            "segmentID": SEGMENT_ID,
                            "title": "Transcript",
                            "excerpt": "Keep this transcript",
                        }
                    ],
                }
            ],
            "pendingProposal": None,
            "undoSnapshot": None,
            "status": "idle",
            "errorMessage": None,
            "createdAt": "2026-09-07T08:06:00Z",
            "updatedAt": "2026-09-07T08:06:00Z",
        },
        "newExtension": {"nested": {"preserve": True}},
    }

    result = update_local_session_fields(SESSION_ID, update, str(tmp_path))
    assert result["title"] == "Robustness fixture"
    stored = json.loads(path.read_text(encoding="utf-8"))
    assert stored["futureFeature"] == {"enabled": True, "vendorPayload": ["keep", 2]}
    assert stored["newExtension"] == {"nested": {"preserve": True}}
    assert (
        stored["documentChat"]["messages"][0]["sourceCitations"][0]["id"] == CITATION_ID
    )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("isComplete", "yes"),
        ("speechCoverage", -0.1),
        ("speechCoverage", 1.1),
        ("hasVerifiableTimestamps", 1),
    ],
)
def test_transcription_evidence_optional_fields_match_swift_types(
    tmp_path, field, value
):
    path = write_manifest(
        tmp_path,
        payload={
            **session_payload(),
            "transcriptionEvidence": {
                "runID": "run-1",
                "revision": 1,
                "disposition": "ready",
                "contentHash": "hash",
                "parentContentHash": None,
                "runFileName": "run.json",
                "outboxFileName": "outbox.json",
                "issues": [],
                field: value,
            },
        },
    )
    before = read_bytes(path)

    with pytest.raises(
        LocalSessionValidationError, match=f"transcriptionEvidence.{field}"
    ):
        update_local_session_fields(
            SESSION_ID,
            {
                "transcriptionEvidence": json.loads(path.read_text())[
                    "transcriptionEvidence"
                ]
            },
            str(tmp_path),
        )

    assert read_bytes(path) == before


def test_id_mutation_and_invalid_date_are_rejected_without_partial_write(tmp_path):
    path = write_manifest(tmp_path)
    before = read_bytes(path)
    with pytest.raises(ValueError, match="id"):
        update_local_session_fields(
            SESSION_ID, {"id": identifier("other")}, str(tmp_path)
        )
    with pytest.raises(LocalSessionValidationError, match="startedAt"):
        update_local_session_fields(
            SESSION_ID, {"startedAt": "09/07/2026"}, str(tmp_path)
        )
    assert read_bytes(path) == before


def test_title_update_marks_user_origin_only_after_validating_candidate(tmp_path):
    path = write_manifest(tmp_path)
    result = update_local_session_title(SESSION_ID, "Renamed", str(tmp_path))
    assert result["new_title"] == "Renamed"
    stored = json.loads(path.read_text(encoding="utf-8"))
    assert stored["title"] == "Renamed"
    assert stored["titleOrigin"] == "user"


def test_update_fields_schema_exposes_sessions_root():
    schema = UpdateLocalSessionFields.model_json_schema()
    assert "sessions_root" in schema["properties"]


def test_malformed_json_and_uuid_records_are_skipped_without_poisoning_readers(
    tmp_path,
):
    write_manifest(
        tmp_path, HEALTHY_ID, session_payload(HEALTHY_ID, text="still searchable")
    )
    malformed_dir = tmp_path / identifier("malformed")
    malformed_dir.mkdir()
    (malformed_dir / "session.json").write_text("{", encoding="utf-8")
    bad_uuid_dir = tmp_path / "legacy-session-name"
    bad_uuid_dir.mkdir()
    (bad_uuid_dir / "session.json").write_text(
        json.dumps(session_payload(HEALTHY_ID)), encoding="utf-8"
    )

    listed = list_local_sessions(str(tmp_path))
    assert [session["id"] for session in listed] == [HEALTHY_ID]
    assert [
        session["id"]
        for session in search_local_session_transcripts("searchable", str(tmp_path))
    ] == [HEALTHY_ID]


def test_symlink_and_hardlink_manifests_are_unreadable_and_skipped(tmp_path):
    healthy_path = write_manifest(tmp_path, HEALTHY_ID, session_payload(HEALTHY_ID))
    outside = tmp_path.parent / f"mcp-outside-{identifier('outside')}"
    outside.mkdir()
    outside_manifest = outside / "session.json"
    outside_manifest.write_text(
        json.dumps(session_payload(SESSION_ID, text="outside")), encoding="utf-8"
    )

    symlink_id = identifier("symlink")
    os.symlink(outside, tmp_path / symlink_id)
    with pytest.raises(LocalSessionPathError):
        get_local_session_data(symlink_id, str(tmp_path))

    manifest_link_id = identifier("manifest-link")
    manifest_link_dir = tmp_path / manifest_link_id
    manifest_link_dir.mkdir()
    os.symlink(outside_manifest, manifest_link_dir / "session.json")
    with pytest.raises(LocalSessionPathError):
        get_local_session_data(manifest_link_id, str(tmp_path))

    hardlink_id = identifier("hardlink")
    hardlink_dir = tmp_path / hardlink_id
    hardlink_dir.mkdir()
    try:
        os.link(outside_manifest, hardlink_dir / "session.json")
    except OSError as error:
        pytest.skip(f"hardlinks unavailable in test filesystem: {error}")
    with pytest.raises(LocalSessionPathError):
        get_local_session_data(hardlink_id, str(tmp_path))

    assert [session["id"] for session in list_local_sessions(str(tmp_path))] == [
        HEALTHY_ID
    ]
    assert healthy_path.exists()


def test_root_symlink_and_traversal_ids_are_rejected(tmp_path):
    real_root = tmp_path / "real"
    real_root.mkdir()
    root_link = tmp_path / "root-link"
    os.symlink(real_root, root_link)
    with pytest.raises(LocalSessionPathError):
        list_local_sessions(str(root_link))
    with pytest.raises(ValueError):
        get_local_session_data("../outside", str(real_root))


def test_file_inventory_skips_symlink_and_hardlink_artifacts(tmp_path):
    write_manifest(tmp_path)
    session_dir = tmp_path / SESSION_ID
    safe = session_dir / "safe.txt"
    safe.write_text("safe", encoding="utf-8")
    outside = tmp_path.parent / f"mcp-file-outside-{identifier('file-outside')}"
    outside.write_text("outside", encoding="utf-8")
    os.symlink(outside, session_dir / "outside-link.txt")
    try:
        os.link(outside, session_dir / "outside-hardlink.txt")
    except OSError as error:
        pytest.skip(f"hardlinks unavailable in test filesystem: {error}")

    result = list_local_session_files(SESSION_ID, str(tmp_path))
    assert [entry["relative_path"] for entry in result["files"]] == ["safe.txt"]


def test_clip_manifest_filenames_cannot_escape_clip_directory(tmp_path):
    clip_id = identifier("clip")
    clip_directory = tmp_path / clip_id
    clip_directory.mkdir()
    payload = {
        "id": clip_id,
        "title": "Clip",
        "startedAt": "2026-09-07T08:00:00Z",
        "endedAt": None,
        "status": "ready",
        "intent": None,
        "videoFileName": "../outside.mov",
        "audioFileName": "clip-audio.wav",
        "transcriptFileName": "transcript.json",
        "notesFileName": "notes.md",
        "transcriptSegments": [],
        "postNotes": "",
        "errorMessage": None,
    }
    (clip_directory / "clip.json").write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(LocalSessionValidationError, match="videoFileName"):
        get_local_clip(clip_id, str(tmp_path))
    assert list_local_clips(str(tmp_path)) == []


def test_session_lock_rejects_symlink_and_hardlink_lock_files(tmp_path):
    write_manifest(tmp_path)
    lock_path = tmp_path / SESSION_ID / ".session.lock"
    outside = tmp_path.parent / f"mcp-lock-outside-{identifier('lock-outside')}"
    outside.write_text("lock", encoding="utf-8")

    os.symlink(outside, lock_path)
    with pytest.raises(LocalSessionLockError):
        update_local_session_fields(
            SESSION_ID, {"documentMarkdown": "blocked"}, str(tmp_path)
        )

    lock_path.unlink()
    try:
        os.link(outside, lock_path)
    except OSError as error:
        pytest.skip(f"hardlinks unavailable in test filesystem: {error}")
    with pytest.raises(LocalSessionLockError):
        update_local_session_fields(
            SESSION_ID, {"documentMarkdown": "blocked"}, str(tmp_path)
        )
