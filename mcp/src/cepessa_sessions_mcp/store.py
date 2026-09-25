"""Read-only access to the Cepessa Sessions store on disk.

Layout: ``<root>/<session UUID>/session.json``. Every read goes through the same
checks: the root is not a symlink, the session ID is a UUID, the session
directory is a real directory directly under the root, and ``session.json`` is a
single-link regular file under the size limit, opened without following links.
Nothing in this module creates, modifies, locks or deletes a file.
"""

import hashlib
import json
import os
import re
import stat
import uuid
from collections.abc import Iterator
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, NoReturn

from .schema import (
    SessionValidationError,
    legacy_offset_seconds,
    parse_date,
    validate_session,
    validate_session_id,
)

SESSIONS_ROOT_ENV = "CEPESSA_SESSIONS_ROOT"
DEFAULT_SESSIONS_ROOT = Path.home() / "Library/Application Support/Cepessa/Sessions"
MANIFEST_NAME = "session.json"
MAX_MANIFEST_BYTES = 32 * 1024 * 1024

DEFAULT_LIST_LIMIT = 20
MAX_LIST_LIMIT = 200
DEFAULT_SEARCH_LIMIT = 10
MAX_SEARCH_LIMIT = 50
MAX_QUERY_LENGTH = 500
MAX_SNIPPETS_PER_SESSION = 3
SNIPPET_RADIUS = 120
UNNAMED_SPEAKER = "Speaker"

_READ_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_NOFOLLOW", 0)
    | getattr(os, "O_NONBLOCK", 0)
    | getattr(os, "O_CLOEXEC", 0)
)


class SessionPathError(ValueError):
    """Raised when a path in the sessions store is unsafe to read."""


# Paths and safe reads


def sessions_root(override: str | os.PathLike[str] | None = None) -> Path:
    """Return the root: override, then $CEPESSA_SESSIONS_ROOT, then the default."""
    raw = override if override is not None else os.getenv(SESSIONS_ROOT_ENV)
    return Path(raw).expanduser() if raw else DEFAULT_SESSIONS_ROOT


def _validated_root(root: Path) -> Path:
    """Return the canonical root, rejecting a symlink or non-directory root."""
    if not root.is_absolute():
        root = Path.cwd() / root
    try:
        root_stat = root.lstat()
    except FileNotFoundError:
        raise FileNotFoundError(f"Sessions root not found: {root}") from None
    except OSError as error:
        raise SessionPathError(f"Cannot inspect sessions root: {root}") from error
    if stat.S_ISLNK(root_stat.st_mode):
        raise SessionPathError(f"Sessions root must not be a symlink: {root}")
    if not stat.S_ISDIR(root_stat.st_mode):
        raise SessionPathError(f"Sessions root is not a directory: {root}")
    try:
        return root.resolve(strict=True)
    except OSError as error:
        raise SessionPathError(f"Cannot resolve sessions root: {root}") from error


def _regular_file_stat(path: Path) -> os.stat_result:
    try:
        file_stat = path.lstat()
    except FileNotFoundError:
        raise FileNotFoundError(f"Session manifest not found: {path}") from None
    except OSError as error:
        raise SessionPathError(f"Cannot inspect session manifest: {path}") from error
    if stat.S_ISLNK(file_stat.st_mode):
        raise SessionPathError(f"Session manifest must not be a symlink: {path}")
    if not stat.S_ISREG(file_stat.st_mode):
        raise SessionPathError(f"Session manifest must be a regular file: {path}")
    if file_stat.st_nlink != 1:
        raise SessionPathError(f"Session manifest must not be hard-linked: {path}")
    if file_stat.st_size > MAX_MANIFEST_BYTES:
        raise SessionPathError(
            f"Session manifest exceeds the {MAX_MANIFEST_BYTES}-byte limit: {path}"
        )
    return file_stat


def _manifest_path(root: Path, session_id: str) -> Path:
    """Return ``<root>/<id>/session.json`` after checking every path component."""
    session_id = validate_session_id(session_id, "session ID")
    bundle = root / session_id
    try:
        bundle_stat = bundle.lstat()
    except FileNotFoundError:
        raise FileNotFoundError(f"Session not found: {session_id}") from None
    except OSError as error:
        raise SessionPathError(f"Cannot inspect session: {session_id}") from error
    if stat.S_ISLNK(bundle_stat.st_mode):
        raise SessionPathError(f"Session directory must not be a symlink: {bundle}")
    if not stat.S_ISDIR(bundle_stat.st_mode):
        raise SessionPathError(f"Session path is not a directory: {bundle}")
    try:
        if bundle.resolve(strict=True).parent != root:
            raise SessionPathError("Session directory is outside the sessions root.")
    except OSError as error:
        raise SessionPathError(f"Cannot resolve session directory: {bundle}") from error
    manifest = bundle / MANIFEST_NAME
    _regular_file_stat(manifest)
    return manifest


def _reject_json_constant(value: str) -> NoReturn:
    raise ValueError(f"Non-finite JSON number is not supported: {value}")


def _read_manifest(path: Path) -> dict:
    """Read and decode one manifest without following links or blocking."""
    expected = _regular_file_stat(path)
    try:
        file_descriptor = os.open(path, _READ_FLAGS)
    except OSError as error:
        raise SessionPathError(
            f"Cannot securely open session manifest: {path}"
        ) from error
    try:
        opened = os.fstat(file_descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino)
        ):
            raise SessionPathError(f"Session manifest changed while opening: {path}")
        with os.fdopen(file_descriptor, "rb") as file:
            file_descriptor = -1
            raw = file.read(MAX_MANIFEST_BYTES + 1)
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
    if len(raw) > MAX_MANIFEST_BYTES:
        raise SessionPathError(
            f"Session manifest exceeds the {MAX_MANIFEST_BYTES}-byte limit: {path}"
        )
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SessionValidationError(
            f"Session manifest is not UTF-8: {path}"
        ) from error
    try:
        value = json.loads(decoded, parse_constant=_reject_json_constant)
    except ValueError as error:
        raise SessionValidationError(
            f"Invalid session manifest JSON: {path}"
        ) from error
    if not isinstance(value, dict):
        raise SessionValidationError(f"Session manifest must be an object: {path}")
    return value


def _load_session(manifest: Path) -> dict:
    return validate_session(_read_manifest(manifest), manifest.parent.name)


def _scan_sessions(
    root_override: str | os.PathLike[str] | None,
) -> Iterator[dict | None]:
    """Yield each valid session under the root, or None for one that was skipped.

    Entries whose name is not a UUID are ignored. A UUID-named entry that is a
    symlink, lacks a safe manifest, or fails validation is skipped. A missing
    root yields nothing.
    """
    try:
        root = _validated_root(sessions_root(root_override))
    except FileNotFoundError:
        return
    for child in sorted(root.iterdir()):
        try:
            validate_session_id(child.name, "session ID")
        except SessionValidationError:
            continue
        try:
            yield _load_session(_manifest_path(root, child.name))
        except (OSError, ValueError):
            yield None


# Session views


def _stable_id(namespace: str, components: list[str]) -> str:
    """The app's ``LocalSessionStableID.uuid``: same input, same id."""
    digest = bytearray(
        hashlib.sha256("\x1f".join([namespace, *components]).encode("utf-8")).digest()[
            :16
        ]
    )
    digest[6] = (digest[6] & 0x0F) | 0x50
    digest[8] = (digest[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(digest))).upper()


def _iso(moment: datetime) -> str:
    text = moment.astimezone(timezone.utc).isoformat(timespec="milliseconds")
    return text.replace(".000+00:00", "Z").replace("+00:00", "Z")


def _normalized(segment: dict, index: int, started_at: datetime) -> dict:
    """A segment as the app reads it: earliest-format offsets become dates and
    a missing id is derived exactly the way the app derives it."""
    segment = dict(segment)
    offset = legacy_offset_seconds(segment["timestamp"])
    if offset is not None:
        segment["timestamp"] = _iso(started_at + timedelta(seconds=offset))
        segment["id"] = segment.get("id") or _stable_id(
            "legacy-offset-transcript-segment",
            [f"{started_at.timestamp():.3f}", str(index), segment["text"]],
        )
    elif not segment.get("id"):
        segment["id"] = _stable_id(
            "legacy-transcript-segment",
            [
                segment["speaker"],
                segment["text"],
                f"{parse_date(segment['timestamp']).timestamp():.3f}",
            ],
        )
    return segment


def _segments(session: dict) -> list[dict]:
    """Current key first, then the legacy ``segments`` key."""
    segments = session.get("transcriptSegments")
    if segments is None:
        segments = session.get("segments")
    if not isinstance(segments, list):
        return []
    started_at = parse_date(session["startedAt"])
    return [
        _normalized(segment, index, started_at)
        for index, segment in enumerate(segments)
    ]


def _speaker(segment: dict) -> str:
    return segment["speaker"].strip() or UNNAMED_SPEAKER


def _line(segment: dict) -> str:
    return f"{_speaker(segment)}: {segment['text'].strip()}"


def _spoken(segments: list[dict]) -> list[dict]:
    return [segment for segment in segments if segment["text"].strip()]


def _sort_key(session: dict) -> tuple[datetime, str]:
    return parse_date(session["startedAt"]), session["id"]


def _summary(session: dict) -> dict:
    segments = _segments(session)
    return {
        "id": session["id"],
        "title": session["title"],
        "startedAt": session["startedAt"],
        "status": session["status"],
        "segmentCount": len(segments),
        "hasTranscript": bool(_spoken(segments)),
    }


def _bounded(value: Any, name: str, minimum: int, maximum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{name} must be an integer.")
    if maximum is None and value < minimum:
        raise ValueError(f"{name} must be at least {minimum}.")
    if maximum is not None and not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}.")
    return value


# Tools


def list_sessions(
    limit: int = DEFAULT_LIST_LIMIT,
    offset: int = 0,
    *,
    root: str | os.PathLike[str] | None = None,
) -> dict:
    """Recent sessions, newest first."""
    limit = _bounded(limit, "limit", 1, MAX_LIST_LIMIT)
    offset = _bounded(offset, "offset", 0)
    summaries = []
    skipped = 0
    for session in _scan_sessions(root):
        if session is None:
            skipped += 1
        else:
            summaries.append(_summary(session))
    summaries.sort(key=_sort_key, reverse=True)
    return {
        "total": len(summaries),
        "offset": offset,
        "limit": limit,
        "skippedCount": skipped,
        "sessions": summaries[offset : offset + limit],
    }


def get_transcript(
    session_id: str, *, root: str | os.PathLike[str] | None = None
) -> dict:
    """One session's transcript, as stored, plus a plain ``Speaker: text`` rendering."""
    manifest = _manifest_path(_validated_root(sessions_root(root)), session_id)
    session = _load_session(manifest)
    segments = _segments(session)
    return {
        "id": session["id"],
        "title": session["title"],
        "startedAt": session["startedAt"],
        "status": session["status"],
        "segmentCount": len(segments),
        "segments": [
            {
                "id": segment["id"],
                "speaker": segment["speaker"],
                "text": segment["text"],
                "timestamp": segment["timestamp"],
                "endTimestamp": segment.get("endTimestamp"),
            }
            for segment in segments
        ],
        "transcript": "\n".join(_line(segment) for segment in _spoken(segments)),
    }


def _snippet(line: str, match: re.Match[str]) -> str:
    start = max(0, match.start() - SNIPPET_RADIUS)
    end = min(len(line), match.end() + SNIPPET_RADIUS)
    prefix = "..." if start > 0 else ""
    suffix = "..." if end < len(line) else ""
    return f"{prefix}{line[start:end].strip()}{suffix}"


def _first_match(line: str, patterns: list[re.Pattern[str]]) -> re.Match[str] | None:
    matches = [match for pattern in patterns if (match := pattern.search(line))]
    return min(matches, key=lambda match: match.start()) if matches else None


def search_transcripts(
    query: str,
    limit: int = DEFAULT_SEARCH_LIMIT,
    *,
    root: str | os.PathLike[str] | None = None,
) -> dict:
    """Case-insensitive search; a session matches the whole phrase or all its words."""
    if not isinstance(query, str):
        raise ValueError("query must be a string.")
    needle = query.strip()
    if not needle:
        raise ValueError("query must not be blank.")
    if len(needle) > MAX_QUERY_LENGTH:
        raise ValueError(f"query must be at most {MAX_QUERY_LENGTH} characters.")
    limit = _bounded(limit, "limit", 1, MAX_SEARCH_LIMIT)

    phrase = re.compile(re.escape(needle), re.IGNORECASE)
    words = [re.compile(re.escape(word), re.IGNORECASE) for word in needle.split()]
    results = []
    skipped = 0
    for session in _scan_sessions(root):
        if session is None:
            skipped += 1
            continue
        spoken = _spoken(_segments(session))
        lines = [_line(segment) for segment in spoken]
        full_text = "\n".join(lines)
        if not phrase.search(full_text) and not all(
            word.search(full_text) for word in words
        ):
            continue
        snippets = []
        for segment, line in zip(spoken, lines, strict=True):
            match = phrase.search(line) or _first_match(line, words)
            if match:
                snippets.append(
                    {
                        "segmentId": segment["id"],
                        "speaker": segment["speaker"],
                        "timestamp": segment["timestamp"],
                        "snippet": _snippet(line, match),
                    }
                )
        results.append(
            {
                **_summary(session),
                "matchingSegmentCount": len(snippets),
                "snippets": snippets[:MAX_SNIPPETS_PER_SESSION],
            }
        )

    results.sort(key=_sort_key, reverse=True)
    return {
        "query": needle,
        "totalMatches": len(results),
        "skippedCount": skipped,
        "results": results[:limit],
    }
