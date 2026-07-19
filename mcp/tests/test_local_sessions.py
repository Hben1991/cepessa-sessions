import json

from mcp_server_omi.server import (
    get_local_clip,
    get_local_session_data,
    get_local_session_transcript,
    list_local_clip_files,
    list_local_clips,
    list_local_session_files,
    list_local_sessions,
    requires_omi_api_key,
    search_local_session_transcripts,
    update_local_session_fields,
    update_local_session_title,
)


def write_session(root, session_id, title, started_at, segments, extra=None):
    session_dir = root / session_id
    session_dir.mkdir(parents=True)
    payload = {
        "id": session_id,
        "title": title,
        "startedAt": started_at,
        "status": "ready",
        "recap": {"overview": "Short recap", "sections": []},
        "transcriptSegments": segments,
    }
    if extra:
        payload.update(extra)
    (session_dir / "session.json").write_text(json.dumps(payload), encoding="utf-8")


def write_clip(root, clip_id, title, started_at, segments=None, extra=None):
    clip_dir = root / clip_id
    clip_dir.mkdir(parents=True)
    payload = {
        "id": clip_id,
        "title": title,
        "startedAt": started_at,
        "endedAt": "2026-06-11T08:02:00Z",
        "status": "ready",
        "intent": "Show the agent what changed on screen",
        "videoFileName": "clip-video.mov",
        "audioFileName": "clip-audio.wav",
        "transcriptFileName": "transcript.json",
        "notesFileName": "notes.md",
        "transcriptSegments": segments or [],
        "postNotes": "Additional post-recording context.",
    }
    if extra:
        payload.update(extra)
    (clip_dir / "clip.json").write_text(json.dumps(payload), encoding="utf-8")


def test_list_local_sessions_returns_recent_transcript_summaries(tmp_path):
    write_session(
        tmp_path,
        "older",
        "Older session",
        "2026-06-10T08:00:00Z",
        [{"speaker": "You", "text": "Old notes", "timestamp": "2026-06-10T08:00:01Z"}],
    )
    write_session(
        tmp_path,
        "newer",
        "Newer session",
        "2026-06-11T08:00:00Z",
        [
            {
                "speaker": "Dana",
                "text": "Discussed MCP access for transcripts",
                "timestamp": "2026-06-11T08:00:01Z",
            }
        ],
    )

    result = list_local_sessions(str(tmp_path))

    assert [session["id"] for session in result] == ["newer", "older"]
    assert result[0]["transcript_segment_count"] == 1
    assert (
        result[0]["transcript_preview"] == "Dana: Discussed MCP access for transcripts"
    )


def test_get_local_session_transcript_formats_segments_as_markdown(tmp_path):
    write_session(
        tmp_path,
        "session-1",
        "Agent handoff",
        "2026-06-11T08:00:00Z",
        [
            {
                "speaker": "You",
                "text": "Please read the transcript directly.",
                "timestamp": "2026-06-11T08:00:01Z",
                "endTimestamp": "2026-06-11T08:00:04Z",
            },
            {
                "speaker": "Remote speaker",
                "text": "That should work through MCP.",
                "timestamp": "2026-06-11T08:00:05Z",
            },
        ],
    )

    result = get_local_session_transcript("session-1", str(tmp_path))

    assert result["id"] == "session-1"
    assert result["title"] == "Agent handoff"
    assert (
        "- [2026-06-11T08:00:01Z] You: Please read the transcript directly."
        in result["transcript_markdown"]
    )
    assert (
        "- [2026-06-11T08:00:05Z] Remote speaker: That should work through MCP."
        in result["transcript_markdown"]
    )


def test_search_local_session_transcripts_returns_matching_snippet(tmp_path):
    write_session(
        tmp_path,
        "session-1",
        "Planning",
        "2026-06-11T08:00:00Z",
        [
            {
                "speaker": "You",
                "text": "Nothing relevant here",
                "timestamp": "2026-06-11T08:00:01Z",
            }
        ],
    )
    write_session(
        tmp_path,
        "session-2",
        "Codex MCP",
        "2026-06-12T08:00:00Z",
        [
            {
                "speaker": "You",
                "text": "Codex should connect and pull transcripts directly",
                "timestamp": "2026-06-12T08:00:01Z",
            }
        ],
    )

    result = search_local_session_transcripts("pull transcripts", str(tmp_path))

    assert len(result) == 1
    assert result[0]["id"] == "session-2"
    assert "pull transcripts directly" in result[0]["snippet"]


def test_local_session_tools_do_not_require_omi_api_key():
    assert requires_omi_api_key("list_local_sessions") is False
    assert requires_omi_api_key("get_local_session_transcript") is False
    assert requires_omi_api_key("search_local_session_transcripts") is False
    assert requires_omi_api_key("update_local_session_title") is False
    assert requires_omi_api_key("get_local_session_data") is False
    assert requires_omi_api_key("list_local_session_files") is False
    assert requires_omi_api_key("update_local_session_fields") is False
    assert requires_omi_api_key("list_local_clips") is False
    assert requires_omi_api_key("get_local_clip") is False
    assert requires_omi_api_key("list_local_clip_files") is False
    assert requires_omi_api_key("get_conversations") is True


def test_list_local_clips_returns_recent_agent_handoff_summaries(tmp_path):
    write_clip(
        tmp_path,
        "older-clip",
        "Older CLIP",
        "2026-06-10T08:00:00Z",
        [{"id": "s1", "startOffset": 0, "endOffset": 2, "text": "Old clip"}],
    )
    write_clip(
        tmp_path,
        "newer-clip",
        "Newer CLIP",
        "2026-06-11T08:00:00Z",
        [
            {
                "id": "s2",
                "startOffset": 0,
                "endOffset": 5,
                "text": "Agent should inspect the screen change",
            }
        ],
    )

    result = list_local_clips(str(tmp_path))

    assert [clip["id"] for clip in result] == ["newer-clip", "older-clip"]
    assert result[0]["transcript_segment_count"] == 1
    assert "screen change" in result[0]["transcript_preview"]
    assert result[0]["video_path"].endswith("newer-clip/clip-video.mov")


def test_get_local_clip_exposes_video_transcript_and_notes(tmp_path):
    write_clip(
        tmp_path,
        "clip-1",
        "Agent visual handoff",
        "2026-06-11T08:00:00Z",
        [{"id": "s1", "startOffset": 1, "endOffset": 3, "text": "Look at this button"}],
    )

    result = get_local_clip("clip-1", str(tmp_path))

    assert result["id"] == "clip-1"
    assert result["clip"]["title"] == "Agent visual handoff"
    assert result["transcript_segments"][0]["text"] == "Look at this button"
    assert result["post_notes"] == "Additional post-recording context."
    assert result["video_path"].endswith("clip-1/clip-video.mov")


def test_list_local_clip_files_returns_agent_packet_inventory(tmp_path):
    write_clip(tmp_path, "clip-1", "Files", "2026-06-11T08:00:00Z")
    video_path = tmp_path / "clip-1" / "clip-video.mov"
    notes_path = tmp_path / "clip-1" / "notes.md"
    video_path.write_bytes(b"mov")
    notes_path.write_text("note", encoding="utf-8")

    result = list_local_clip_files("clip-1", str(tmp_path))

    assert result["id"] == "clip-1"
    relative_paths = [file["relative_path"] for file in result["files"]]
    assert relative_paths == ["clip-video.mov", "clip.json", "notes.md"]


def test_update_local_session_title_writes_session_json(tmp_path):
    write_session(
        tmp_path,
        "session-1",
        "Old title",
        "2026-06-11T08:00:00Z",
        [
            {
                "speaker": "You",
                "text": "Title source",
                "timestamp": "2026-06-11T08:00:01Z",
            }
        ],
    )

    result = update_local_session_title(
        "session-1", "Better meeting title", str(tmp_path)
    )

    assert result["id"] == "session-1"
    assert result["old_title"] == "Old title"
    assert result["new_title"] == "Better meeting title"
    assert result["title"] == "Better meeting title"

    updated_session = json.loads(
        (tmp_path / "session-1" / "session.json").read_text(encoding="utf-8")
    )
    assert updated_session["title"] == "Better meeting title"


def test_update_local_session_title_rejects_blank_titles(tmp_path):
    write_session(
        tmp_path,
        "session-1",
        "Old title",
        "2026-06-11T08:00:00Z",
        [],
    )

    try:
        update_local_session_title("session-1", "   ", str(tmp_path))
    except ValueError as error:
        assert "title" in str(error).lower()
    else:
        raise AssertionError("blank title should fail")


def test_get_local_session_data_exposes_future_fields_and_file_path(tmp_path):
    write_session(
        tmp_path,
        "session-1",
        "Full feature session",
        "2026-06-11T08:00:00Z",
        [],
        extra={
            "futureFeature": {"enabled": True},
            "attachments": [{"id": "image-1", "urlString": "/tmp/example.png"}],
        },
    )

    result = get_local_session_data("session-1", str(tmp_path))

    assert result["session"]["futureFeature"] == {"enabled": True}
    assert result["session"]["attachments"][0]["id"] == "image-1"
    assert result["session_json_path"].endswith("session-1/session.json")


def test_list_local_session_files_returns_attachment_inventory(tmp_path):
    write_session(tmp_path, "session-1", "Files", "2026-06-11T08:00:00Z", [])
    attachments_dir = tmp_path / "session-1" / "Attachments"
    attachments_dir.mkdir()
    image_path = attachments_dir / "screen.png"
    image_path.write_bytes(b"png")

    result = list_local_session_files("session-1", str(tmp_path))

    assert result["id"] == "session-1"
    assert result["files"] == [
        {
            "path": str(image_path),
            "relative_path": "Attachments/screen.png",
            "size_bytes": 3,
            "extension": ".png",
        }
    ]


def test_update_local_session_fields_merges_top_level_future_fields(tmp_path):
    write_session(
        tmp_path,
        "session-1",
        "Field update",
        "2026-06-11T08:00:00Z",
        [],
        extra={"futureFeature": {"enabled": False}},
    )

    result = update_local_session_fields(
        "session-1",
        {"futureFeature": {"enabled": True}, "documentMarkdown": "# Summary"},
        str(tmp_path),
    )

    assert result["updated_fields"] == ["documentMarkdown", "futureFeature"]
    updated_session = json.loads(
        (tmp_path / "session-1" / "session.json").read_text(encoding="utf-8")
    )
    assert updated_session["futureFeature"] == {"enabled": True}
    assert updated_session["documentMarkdown"] == "# Summary"


def test_update_local_session_fields_rejects_identity_changes(tmp_path):
    write_session(tmp_path, "session-1", "Field update", "2026-06-11T08:00:00Z", [])

    try:
        update_local_session_fields("session-1", {"id": "different"}, str(tmp_path))
    except ValueError as error:
        assert "id" in str(error)
    else:
        raise AssertionError("id changes should fail")
