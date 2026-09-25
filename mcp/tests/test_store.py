import json
import os
import stat
from pathlib import Path

import pytest
from conftest import make_id, segment, session_payload, write_session

from cepessa_sessions_mcp import store
from cepessa_sessions_mcp.schema import SessionValidationError
from cepessa_sessions_mcp.store import (
    SessionPathError,
    get_transcript,
    list_sessions,
    search_transcripts,
)

OLDER_ID = make_id("session:older")
NEWER_ID = make_id("session:newer")
HEBREW_ID = make_id("session:hebrew")
HEALTHY_ID = make_id("session:healthy")

HEBREW_TITLE = "פגישת תכנון רבעונית"
HEBREW_TEXT = "שלום לכולם, נתחיל בסקירת התקציב של הרבעון."


# list_sessions


def test_list_sessions_returns_summaries_newest_first(sessions_root):
    write_session(
        sessions_root,
        OLDER_ID,
        title="Older",
        started_at="2026-06-10T08:00:00Z",
        segments=[segment("You", "Old notes")],
    )
    write_session(
        sessions_root,
        NEWER_ID,
        title="Newer",
        started_at="2026-06-11T08:00:00Z",
        status="transcribing",
        segments=[],
    )

    result = list_sessions()

    assert result["total"] == 2
    assert result["skippedCount"] == 0
    assert result["sessions"] == [
        {
            "id": NEWER_ID,
            "title": "Newer",
            "startedAt": "2026-06-11T08:00:00Z",
            "status": "transcribing",
            "segmentCount": 0,
            "hasTranscript": False,
        },
        {
            "id": OLDER_ID,
            "title": "Older",
            "startedAt": "2026-06-10T08:00:00Z",
            "status": "ready",
            "segmentCount": 1,
            "hasTranscript": True,
        },
    ]


def test_list_sessions_orders_by_instant_not_by_string(sessions_root):
    # 09:30+02:00 is 07:30Z: earlier than 08:00Z even though it sorts later as text.
    write_session(sessions_root, OLDER_ID, started_at="2026-06-11T09:30:00+02:00")
    write_session(sessions_root, NEWER_ID, started_at="2026-06-11T08:00:00Z")

    assert [s["id"] for s in list_sessions()["sessions"]] == [NEWER_ID, OLDER_ID]


def test_blank_segments_do_not_count_as_a_transcript(sessions_root):
    write_session(sessions_root, OLDER_ID, segments=[segment("You", "   ")])

    [summary] = list_sessions()["sessions"]
    assert summary["segmentCount"] == 1
    assert summary["hasTranscript"] is False


def test_list_sessions_paginates(sessions_root):
    ids = [make_id(f"page:{day}") for day in range(1, 6)]
    for day, session_id in zip(range(1, 6), ids, strict=True):
        write_session(sessions_root, session_id, started_at=f"2026-06-0{day}T08:00:00Z")
    newest_first = list(reversed(ids))

    pages = [list_sessions(limit=2, offset=offset) for offset in (0, 2, 4, 6)]

    assert [[s["id"] for s in page["sessions"]] for page in pages] == [
        newest_first[0:2],
        newest_first[2:4],
        newest_first[4:5],
        [],
    ]
    assert {page["total"] for page in pages} == {5}
    assert [(page["offset"], page["limit"]) for page in pages] == [
        (0, 2),
        (2, 2),
        (4, 2),
        (6, 2),
    ]


@pytest.mark.parametrize(
    ("limit", "offset"),
    [(0, 0), (store.MAX_LIST_LIMIT + 1, 0), (5, -1), (True, 0), ("5", 0)],
)
def test_list_sessions_rejects_out_of_range_paging(sessions_root, limit, offset):
    with pytest.raises(ValueError):
        list_sessions(limit=limit, offset=offset)


def test_missing_root_lists_nothing(tmp_path, monkeypatch):
    monkeypatch.setenv("CEPESSA_SESSIONS_ROOT", str(tmp_path / "does-not-exist"))

    assert list_sessions() == {
        "total": 0,
        "offset": 0,
        "limit": store.DEFAULT_LIST_LIMIT,
        "skippedCount": 0,
        "sessions": [],
    }
    with pytest.raises(FileNotFoundError):
        get_transcript(OLDER_ID)


def test_root_comes_from_env_then_the_apps_two_stores(tmp_path, monkeypatch):
    monkeypatch.setenv("CEPESSA_SESSIONS_ROOT", str(tmp_path / "custom"))
    assert store.sessions_roots() == [tmp_path / "custom"]

    monkeypatch.delenv("CEPESSA_SESSIONS_ROOT")
    support = Path.home() / "Library" / "Application Support"
    assert store.sessions_roots() == [
        support / "Cepessa" / "Sessions",
        support / "Cepessa Legacy" / "Meetings" / "Sessions",
    ]


# get_transcript


def test_get_transcript_returns_stored_segments_and_plain_text(sessions_root):
    write_session(
        sessions_root,
        OLDER_ID,
        title="Agent handoff",
        segments=[
            segment(
                "You",
                "Please read the transcript directly.",
                "2026-06-11T08:00:01Z",
                endTimestamp="2026-06-11T08:00:04Z",
                source="microphone",
            ),
            segment("Remote speaker", "   ", "2026-06-11T08:00:04Z"),
            segment("", "Unlabelled line", "2026-06-11T08:00:05.123Z"),
        ],
    )

    result = get_transcript(OLDER_ID)

    assert result["id"] == OLDER_ID
    assert result["title"] == "Agent handoff"
    assert result["startedAt"] == "2026-06-11T08:00:00Z"
    assert result["status"] == "ready"
    assert result["segmentCount"] == 3
    assert result["segments"][0] == {
        "id": make_id(
            "segment:YouPlease read the transcript directly.2026-06-11T08:00:01Z"
        ),
        "speaker": "You",
        "text": "Please read the transcript directly.",
        "timestamp": "2026-06-11T08:00:01Z",
        "endTimestamp": "2026-06-11T08:00:04Z",
    }
    assert result["segments"][2]["endTimestamp"] is None
    assert result["transcript"] == (
        "You: Please read the transcript directly.\nSpeaker: Unlabelled line"
    )


def test_get_transcript_reads_legacy_segments_key(sessions_root):
    payload = session_payload(OLDER_ID)
    del payload["transcriptSegments"]
    payload["segments"] = [segment("Dana", "Legacy layout")]
    write_session(sessions_root, OLDER_ID, payload)

    assert get_transcript(OLDER_ID)["transcript"] == "Dana: Legacy layout"


def test_hebrew_passes_through_unchanged(sessions_root):
    write_session(
        sessions_root,
        HEBREW_ID,
        title=HEBREW_TITLE,
        segments=[segment("דנה", HEBREW_TEXT)],
    )

    result = get_transcript(HEBREW_ID)

    assert result["title"] == HEBREW_TITLE
    assert result["segments"][0]["speaker"] == "דנה"
    assert result["segments"][0]["text"] == HEBREW_TEXT
    assert result["transcript"] == f"דנה: {HEBREW_TEXT}"
    assert list_sessions()["sessions"][0]["title"] == HEBREW_TITLE


@pytest.mark.parametrize("bad_id", ["../outside", "", "not-a-uuid", f"{OLDER_ID}/.."])
def test_get_transcript_rejects_non_uuid_ids(sessions_root, bad_id):
    with pytest.raises(SessionValidationError):
        get_transcript(bad_id)


def test_get_transcript_unknown_session(sessions_root):
    with pytest.raises(FileNotFoundError, match="Session not found"):
        get_transcript(make_id("session:missing"))


# search_transcripts


def test_search_is_case_insensitive_and_returns_snippets(sessions_root):
    write_session(
        sessions_root,
        OLDER_ID,
        title="Planning",
        segments=[segment("You", "Nothing relevant here")],
    )
    write_session(
        sessions_root,
        NEWER_ID,
        title="Codex MCP",
        started_at="2026-06-12T08:00:00Z",
        segments=[
            segment("You", "Intro", "2026-06-12T08:00:01Z"),
            segment(
                "Dana",
                "Codex should connect and Pull Transcripts directly",
                "2026-06-12T08:00:02Z",
            ),
        ],
    )

    result = search_transcripts("pull TRANSCRIPTS")

    assert result["query"] == "pull TRANSCRIPTS"
    assert result["totalMatches"] == 1
    [match] = result["results"]
    assert match["id"] == NEWER_ID
    assert match["title"] == "Codex MCP"
    assert match["matchingSegmentCount"] == 1
    assert match["snippets"] == [
        {
            "segmentId": make_id(
                "segment:DanaCodex should connect and Pull Transcripts directly"
                "2026-06-12T08:00:02Z"
            ),
            "speaker": "Dana",
            "timestamp": "2026-06-12T08:00:02Z",
            "snippet": "Codex should connect and Pull Transcripts directly",
        }
    ]


def test_search_matches_all_words_across_segments(sessions_root):
    write_session(
        sessions_root,
        OLDER_ID,
        segments=[
            segment("You", "The budget is approved", "2026-06-11T08:00:01Z"),
            segment("Dana", "Hiring starts in July", "2026-06-11T08:00:02Z"),
        ],
    )

    [match] = search_transcripts("july budget")["results"]
    assert [s["snippet"] for s in match["snippets"]] == [
        "The budget is approved",
        "Hiring starts in July",
    ]
    assert search_transcripts("july invoices")["results"] == []


def test_search_finds_hebrew(sessions_root):
    write_session(sessions_root, HEBREW_ID, segments=[segment("דנה", HEBREW_TEXT)])
    write_session(sessions_root, OLDER_ID, segments=[segment("You", "English only")])

    result = search_transcripts("התקציב")

    assert [match["id"] for match in result["results"]] == [HEBREW_ID]
    assert result["results"][0]["snippets"][0]["snippet"] == HEBREW_TEXT


def test_search_trims_long_lines_around_the_match(sessions_root):
    text = "a" * 300 + " needle " + "b" * 300
    write_session(sessions_root, OLDER_ID, segments=[segment("You", text)])

    [match] = search_transcripts("NEEDLE")["results"]
    snippet = match["snippets"][0]["snippet"]

    assert snippet.startswith("...") and snippet.endswith("...")
    assert "needle" in snippet
    assert len(snippet) <= len("needle") + 2 * store.SNIPPET_RADIUS + 8


def test_search_caps_snippets_and_honours_limit(sessions_root):
    for day in range(1, 5):
        write_session(
            sessions_root,
            make_id(f"search:{day}"),
            started_at=f"2026-06-0{day}T08:00:00Z",
            segments=[
                segment("You", f"roadmap item {n}", f"2026-06-0{day}T08:00:0{n}Z")
                for n in range(1, 6)
            ],
        )

    result = search_transcripts("roadmap", limit=2)

    assert result["totalMatches"] == 4
    assert [match["id"] for match in result["results"]] == [
        make_id("search:4"),
        make_id("search:3"),
    ]
    assert result["results"][0]["matchingSegmentCount"] == 5
    assert len(result["results"][0]["snippets"]) == store.MAX_SNIPPETS_PER_SESSION


@pytest.mark.parametrize(
    ("query", "limit"),
    [("", 10), ("   ", 10), ("x" * (store.MAX_QUERY_LENGTH + 1), 10), ("ok", 0)],
)
def test_search_rejects_bad_input(sessions_root, query, limit):
    with pytest.raises(ValueError):
        search_transcripts(query, limit=limit)


# Unsafe and malformed data


def _write_raw(root: Path, name: str, raw: bytes) -> None:
    directory = root / name
    directory.mkdir()
    (directory / "session.json").write_bytes(raw)


@pytest.mark.parametrize(
    ("label", "raw", "error"),
    [
        ("truncated", b"{", SessionValidationError),
        ("array", b"[]", SessionValidationError),
        ("latin1", '{"title": "caf\xe9"}'.encode("latin-1"), SessionValidationError),
        ("nan", None, SessionValidationError),
        ("bad-status", None, SessionValidationError),
        ("bad-date", None, SessionValidationError),
        ("bad-segment", None, SessionValidationError),
        ("id-mismatch", None, SessionValidationError),
    ],
)
def test_malformed_sessions_are_skipped_and_rejected(sessions_root, label, raw, error):
    bad_id = make_id(f"malformed:{label}")
    if raw is None:
        payload = session_payload(bad_id, segments=[segment("You", "hidden words")])
        if label == "nan":
            raw = json.dumps(payload).replace('"ready"', '"ready", "x": NaN').encode()
        else:
            if label == "bad-status":
                payload["status"] = "archived"
            elif label == "bad-date":
                payload["startedAt"] = "11/06/2026"
            elif label == "bad-segment":
                payload["transcriptSegments"] = [{"speaker": "You", "text": 42}]
            elif label == "id-mismatch":
                payload["id"] = make_id("somebody-else")
            raw = json.dumps(payload).encode()
    _write_raw(sessions_root, bad_id, raw)
    write_session(sessions_root, HEALTHY_ID, segments=[segment("You", "hidden words")])

    listed = list_sessions()
    assert [s["id"] for s in listed["sessions"]] == [HEALTHY_ID]
    assert listed["skippedCount"] == 1
    searched = search_transcripts("hidden words")
    assert [m["id"] for m in searched["results"]] == [HEALTHY_ID]
    assert searched["skippedCount"] == 1
    with pytest.raises(error):
        get_transcript(bad_id)


def test_non_uuid_entries_are_ignored_not_counted(sessions_root):
    write_session(sessions_root, HEALTHY_ID)
    (sessions_root / "legacy-name").mkdir()
    (sessions_root / "legacy-name" / "session.json").write_text(
        json.dumps(session_payload(HEALTHY_ID)), encoding="utf-8"
    )
    (sessions_root / ".DS_Store").write_bytes(b"\x00")

    listed = list_sessions()
    assert [s["id"] for s in listed["sessions"]] == [HEALTHY_ID]
    assert listed["skippedCount"] == 0


def test_oversized_manifest_is_rejected(sessions_root, monkeypatch):
    write_session(sessions_root, OLDER_ID, segments=[segment("You", "x" * 400)])
    monkeypatch.setattr(store, "MAX_MANIFEST_BYTES", 256)

    assert list_sessions()["skippedCount"] == 1
    with pytest.raises(SessionPathError, match="limit"):
        get_transcript(OLDER_ID)


def test_symlinked_and_hardlinked_sessions_are_rejected(sessions_root, tmp_path):
    write_session(sessions_root, HEALTHY_ID)
    outside = tmp_path / "outside"
    outside_id = make_id("outside")
    outside_manifest = write_session(
        outside, outside_id, segments=[segment("You", "secret outside text")]
    )

    directory_link = make_id("directory-link")
    os.symlink(outside / outside_id, sessions_root / directory_link)

    manifest_link = make_id("manifest-link")
    (sessions_root / manifest_link).mkdir()
    os.symlink(outside_manifest, sessions_root / manifest_link / "session.json")

    hard_link = make_id("hard-link")
    (sessions_root / hard_link).mkdir()
    os.link(outside_manifest, sessions_root / hard_link / "session.json")

    for session_id in (directory_link, manifest_link, hard_link):
        with pytest.raises(SessionPathError):
            get_transcript(session_id)
    listed = list_sessions()
    assert [s["id"] for s in listed["sessions"]] == [HEALTHY_ID]
    assert listed["skippedCount"] == 3
    assert search_transcripts("secret outside")["results"] == []


def test_symlinked_root_is_rejected(tmp_path, monkeypatch):
    real_root = tmp_path / "real"
    real_root.mkdir()
    write_session(real_root, HEALTHY_ID)
    link = tmp_path / "link"
    os.symlink(real_root, link)
    monkeypatch.setenv("CEPESSA_SESSIONS_ROOT", str(link))

    for call in (list_sessions, lambda: get_transcript(HEALTHY_ID)):
        with pytest.raises(SessionPathError, match="symlink"):
            call()
    with pytest.raises(SessionPathError, match="symlink"):
        search_transcripts("anything")


def test_fifo_manifest_is_rejected_without_blocking(sessions_root):
    (sessions_root / OLDER_ID).mkdir()
    os.mkfifo(sessions_root / OLDER_ID / "session.json")

    with pytest.raises(SessionPathError, match="regular file"):
        get_transcript(OLDER_ID)
    assert list_sessions()["skippedCount"] == 1


# Read-only guarantee


def _snapshot(root: Path) -> dict:
    tree = {}
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        tree[str(path.relative_to(root))] = (
            stat.S_IFMT(info.st_mode),
            stat.S_IMODE(info.st_mode),
            info.st_mtime_ns,
            path.read_bytes() if path.is_file() else None,
        )
    return tree


def _run_every_tool() -> None:
    list_sessions()
    get_transcript(HEBREW_ID)
    search_transcripts("התקציב")


def test_tools_never_change_the_store(sessions_root):
    write_session(
        sessions_root,
        HEBREW_ID,
        title=HEBREW_TITLE,
        segments=[segment("דנה", HEBREW_TEXT)],
    )
    exports = sessions_root / HEBREW_ID / "Exports"
    exports.mkdir()
    (exports / "session-package.md").write_text("cached", encoding="utf-8")
    before = _snapshot(sessions_root)

    _run_every_tool()

    assert _snapshot(sessions_root) == before


def test_tools_work_on_a_read_only_store(sessions_root):
    write_session(sessions_root, HEBREW_ID, segments=[segment("דנה", HEBREW_TEXT)])
    paths = sorted(sessions_root.rglob("*"), reverse=True) + [sessions_root]
    for path in paths:
        path.chmod(0o555 if path.is_dir() else 0o444)
    try:
        _run_every_tool()
        assert list(sessions_root.rglob(".session.lock")) == []
    finally:
        for path in reversed(paths):
            path.chmod(0o755 if path.is_dir() else 0o644)


def test_package_source_has_no_write_calls():
    package = Path(store.__file__).parent
    forbidden = (
        "O_CREAT",
        "O_WRONLY",
        "O_RDWR",
        "O_TRUNC",
        "O_APPEND",
        "flock",
        ".unlink(",
        "os.rename",
        "os.replace",
        "os.remove",
        "rmtree",
        "mkstemp",
        "mkdir(",
        "write_text",
        "write_bytes",
        '"w"',
        '"wb"',
        '"a"',
    )
    offenders = [
        f"{source.name}: {token}"
        for source in sorted(package.glob("*.py"))
        for token in forbidden
        if token in source.read_text(encoding="utf-8")
    ]
    assert offenders == []


# The earliest format: offset times ("MM:SS") and no segment ids.


def test_earliest_format_sessions_are_read_like_the_app_reads_them(sessions_root):
    session_id = make_id("legacy-offsets")
    write_session(
        sessions_root,
        session_id,
        started_at="2026-08-20T18:40:48Z",
        status="failed",
        segments=[
            {"speaker": "Speaker 1", "text": "בוקר טוב", "timestamp": "00:05"},
            {"speaker": "Speaker 2", "text": "Morning", "timestamp": "1:02:03"},
        ],
    )

    listing = store.list_sessions()
    assert listing["skippedCount"] == 0
    assert listing["sessions"][0]["hasTranscript"] is True

    transcript = store.get_transcript(session_id)
    first, second = transcript["segments"]
    assert first["timestamp"] == "2026-08-20T18:40:53Z"
    assert second["timestamp"] == "2026-08-20T19:42:51Z"
    # Same derivation as the app's LocalSessionStableID (cross-checked vector).
    assert first["id"] == "D1178BFA-F017-5F83-83FF-06391CB0F226"
    assert transcript["transcript"] == "Speaker 1: בוקר טוב\nSpeaker 2: Morning"


def test_a_segment_without_an_id_gets_the_apps_stable_id(sessions_root):
    session_id = make_id("missing-id")
    write_session(
        sessions_root,
        session_id,
        segments=[{"speaker": "A", "text": "x", "timestamp": "2026-08-20T18:40:48Z"}],
    )
    transcript = store.get_transcript(session_id)
    assert transcript["segments"][0]["id"] == "7F9932CB-DD98-563C-AC56-7EDC93577679"
    assert store.get_transcript(session_id) == transcript


def test_offset_segments_are_decoded_as_a_whole_array_like_the_app(sessions_root):
    session_id = make_id("legacy-array")
    started = "2026-08-20T18:40:48Z"
    write_session(
        sessions_root,
        session_id,
        started_at=started,
        segments=[
            # A stored id and an offset end time are ignored, as in the app.
            {
                "id": make_id("stored"),
                "speaker": "Speaker 1",
                "text": "בוקר טוב",
                "timestamp": "00:05",
                "endTimestamp": "00:09",
            },
            {"speaker": "Speaker 2", "text": "Morning", "timestamp": "1:02:03"},
        ],
    )

    first, second = get_transcript(session_id)["segments"]
    assert first["id"] == "D1178BFA-F017-5F83-83FF-06391CB0F226"
    assert first["endTimestamp"] is None
    assert second["timestamp"] == "2026-08-20T19:42:51Z"


@pytest.mark.parametrize(
    ("timestamp", "seconds"),
    [(".5", 0.5), ("5.", 5), ("1e2", 100), ("+5", 5), ("1:00.5", 60.5)],
)
def test_offsets_accept_what_swift_double_accepts(timestamp, seconds):
    assert store.legacy_offset_seconds(timestamp) == seconds


@pytest.mark.parametrize(
    "timestamp", ["٠٥", "12:34\n", " 5", "5 ", "1_0", "-5", "nan", "", "1:2:3:4", "1e"]
)
def test_offsets_reject_what_swift_double_rejects(timestamp):
    assert store.legacy_offset_seconds(timestamp) is None


@pytest.mark.parametrize(
    ("label", "segments_value", "extra"),
    [
        (
            "mixed-date-and-offset",
            [
                segment("A", "dated"),
                {"speaker": "B", "text": "offset", "timestamp": "00:05"},
            ],
            {},
        ),
        ("null-with-legacy-key", None, {"segments": [segment("A", "hidden words")]}),
        (
            "offset-overflows",
            [{"speaker": "A", "text": "hidden words", "timestamp": "99999999999:00"}],
            {},
        ),
        (
            "start-at-year-one",
            [{"speaker": "A", "text": "hidden words", "timestamp": "00:05"}],
            {"startedAt": "0001-01-01T00:30:00+01:00"},
        ),
        (
            "unpaired-surrogate",
            [segment("A", "hidden words \ud800", label="surrogate")],
            {},
        ),
    ],
)
def test_sessions_the_app_cannot_read_are_skipped_not_fatal(
    sessions_root, label, segments_value, extra
):
    bad_id = make_id(f"unreadable:{label}")
    payload = {**session_payload(bad_id), "transcriptSegments": segments_value, **extra}
    # ASCII-escaped, as a surrogate would appear in a real file.
    _write_raw(sessions_root, bad_id, json.dumps(payload).encode())
    write_session(sessions_root, HEALTHY_ID, segments=[segment("You", "hidden words")])

    listed = list_sessions()
    assert [s["id"] for s in listed["sessions"]] == [HEALTHY_ID]
    assert listed["skippedCount"] == 1
    assert search_transcripts("hidden words")["skippedCount"] == 1
    with pytest.raises(SessionValidationError):
        get_transcript(bad_id)


def test_nesting_stops_where_swift_stops(sessions_root):
    def nested(depth: int) -> bytes:
        # The session object is the first level.
        body = "[" * (depth - 1) + "]" * (depth - 1)
        return (
            json.dumps(session_payload(make_id(f"depth:{depth}"))).encode()[:-1]
            + f', "x": {body}}}'.encode()
        )

    for depth in (512, 513, 100_000):
        _write_raw(sessions_root, make_id(f"depth:{depth}"), nested(depth))

    listed = list_sessions()
    assert [s["id"] for s in listed["sessions"]] == [make_id("depth:512")]
    assert listed["skippedCount"] == 2


def test_the_pre_rename_store_is_read_behind_the_current_one(tmp_path, monkeypatch):
    current = tmp_path / "Cepessa" / "Sessions"
    legacy = tmp_path / "Cepessa Legacy" / "Meetings" / "Sessions"
    current.mkdir(parents=True)
    legacy.mkdir(parents=True)
    monkeypatch.delenv("CEPESSA_SESSIONS_ROOT")
    monkeypatch.setattr(store, "DEFAULT_SESSIONS_ROOT", current)
    monkeypatch.setattr(store, "LEGACY_SESSIONS_ROOT", legacy)

    shared, only_legacy, broken_here = (make_id(f"stores:{n}") for n in range(3))
    write_session(current, shared, title="Current copy")
    write_session(legacy, shared, title="Legacy copy")
    write_session(legacy, only_legacy, title="Only in legacy")
    _write_raw(current, broken_here, b"{")
    write_session(legacy, broken_here, title="Readable in legacy")

    titles = {s["id"]: s["title"] for s in list_sessions()["sessions"]}
    assert titles == {
        shared: "Current copy",
        only_legacy: "Only in legacy",
        broken_here: "Readable in legacy",
    }
    assert get_transcript(only_legacy)["title"] == "Only in legacy"
    assert get_transcript(broken_here)["title"] == "Readable in legacy"


def test_a_directory_swapped_for_a_link_mid_read_is_never_followed(
    sessions_root, tmp_path, monkeypatch
):
    write_session(sessions_root, HEALTHY_ID, segments=[segment("You", "inside")])
    outside = tmp_path / "outside"
    write_session(outside, HEALTHY_ID, segments=[segment("You", "OUTSIDE")])
    real_open = os.open
    bundle = sessions_root / HEALTHY_ID

    def swapping_open(path, flags, *args, **kwargs):
        # Just before the manifest is opened, the session directory becomes a
        # link to a directory outside the store.
        if os.fspath(path).endswith(store.MANIFEST_NAME) and not bundle.is_symlink():
            bundle.rename(sessions_root / "moved-away")
            os.symlink(outside / HEALTHY_ID, bundle)
        return real_open(path, flags, *args, **kwargs)

    monkeypatch.setattr(store.os, "open", swapping_open)
    assert get_transcript(HEALTHY_ID)["transcript"] == "You: inside"


def test_search_reads_titles_and_text_but_not_speaker_names(sessions_root):
    write_session(
        sessions_root,
        OLDER_ID,
        title="Meeting 20 Aug",
        segments=[segment("", "hello"), segment("Dana", "hello again")],
    )

    assert search_transcripts("speaker")["results"] == []
    assert search_transcripts("dana")["results"] == []
    [by_title] = search_transcripts("session 20 aug")["results"]
    assert by_title["title"] == "Session 20 Aug"
    assert by_title["matchingSegmentCount"] == 0


def test_search_pages_with_offset(sessions_root):
    for day in range(1, 4):
        write_session(
            sessions_root,
            make_id(f"page:{day}"),
            started_at=f"2026-06-0{day}T08:00:00Z",
            segments=[segment("You", "roadmap", f"2026-06-0{day}T08:00:01Z")],
        )

    page = search_transcripts("roadmap", limit=2, offset=2)
    assert page["totalMatches"] == 3
    assert page["offset"] == 2
    assert [r["id"] for r in page["results"]] == [make_id("page:1")]
