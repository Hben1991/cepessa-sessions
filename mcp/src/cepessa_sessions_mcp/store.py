"""Read-only access to the Cepessa Sessions store on disk.

Layout: ``<root>/<session UUID>/session.json``. The app reads its current store
and, behind it, the store it used before the rename; so does this module.
Every read walks directory descriptors: the root, then the session directory,
then ``session.json``, each opened without following a link. No component can
be swapped for a link between a check and the read. The manifest must be a
single-link regular file under the size limit. Nothing in this module creates,
modifies, locks or deletes a file.
"""

import errno
import hashlib
import json
import os
import re
import stat
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, NoReturn

from .schema import (
    SessionValidationError,
    decode_transcript_segments,
    legacy_offset_seconds,
    parse_date,
    validate_session,
    validate_session_id,
)

SESSIONS_ROOT_ENV = "CEPESSA_SESSIONS_ROOT"
_APPLICATION_SUPPORT = Path.home() / "Library/Application Support"
DEFAULT_SESSIONS_ROOT = _APPLICATION_SUPPORT / "Cepessa/Sessions"
LEGACY_SESSIONS_ROOT = _APPLICATION_SUPPORT / "Cepessa Legacy/Meetings/Sessions"
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

_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | _CLOEXEC
_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0) | _CLOEXEC


class SessionPathError(ValueError):
    """Raised when a path in the sessions store is unsafe to read."""


# Paths and safe reads


def sessions_roots(override: str | os.PathLike[str] | None = None) -> list[Path]:
    """The stores to read, in order: the override, else $CEPESSA_SESSIONS_ROOT,
    else the app's current store followed by its pre-rename store."""
    raw = override if override is not None else os.getenv(SESSIONS_ROOT_ENV)
    if raw:
        return [Path(raw).expanduser()]
    return [DEFAULT_SESSIONS_ROOT, LEGACY_SESSIONS_ROOT]


def _unsafe(what: str, path: Path, error: OSError) -> SessionPathError:
    if error.errno == errno.ELOOP:
        return SessionPathError(f"{what} must not be a symlink: {path}")
    if error.errno == errno.ENOTDIR:
        return SessionPathError(f"{what} is not a directory: {path}")
    return SessionPathError(f"Cannot open {what.lower()}: {path}")


@contextmanager
def _open_root(root: Path) -> Iterator[int]:
    """A descriptor for the root directory, which must not itself be a link."""
    if not root.is_absolute():
        root = Path.cwd() / root
    try:
        descriptor = os.open(root, _DIRECTORY_FLAGS)
    except FileNotFoundError:
        raise FileNotFoundError(f"Sessions root not found: {root}") from None
    except OSError as error:
        raise _unsafe("Sessions root", root, error) from error
    try:
        yield descriptor
    finally:
        os.close(descriptor)


def _reject_json_constant(value: str) -> NoReturn:
    raise ValueError(f"Non-finite JSON number is not supported: {value}")


def _read_manifest(root: Path, root_fd: int, session_id: str) -> dict:
    """Read and decode ``<root>/<id>/session.json`` without following links."""
    bundle = root / session_id
    manifest = bundle / MANIFEST_NAME
    try:
        bundle_fd = os.open(session_id, _DIRECTORY_FLAGS, dir_fd=root_fd)
    except FileNotFoundError:
        raise FileNotFoundError(f"Session not found: {session_id}") from None
    except OSError as error:
        raise _unsafe("Session directory", bundle, error) from error
    try:
        file_fd = os.open(MANIFEST_NAME, _READ_FLAGS, dir_fd=bundle_fd)
    except FileNotFoundError:
        raise FileNotFoundError(f"Session manifest not found: {manifest}") from None
    except OSError as error:
        raise _unsafe("Session manifest", manifest, error) from error
    finally:
        os.close(bundle_fd)
    try:
        opened = os.fstat(file_fd)
        if not stat.S_ISREG(opened.st_mode):
            raise SessionPathError(
                f"Session manifest must be a regular file: {manifest}"
            )
        if opened.st_nlink != 1:
            raise SessionPathError(
                f"Session manifest must not be hard-linked: {manifest}"
            )
        if opened.st_size > MAX_MANIFEST_BYTES:
            raise SessionPathError(
                f"Session manifest exceeds the {MAX_MANIFEST_BYTES}-byte limit: {manifest}"
            )
        with os.fdopen(file_fd, "rb") as file:
            file_fd = -1
            raw = file.read(MAX_MANIFEST_BYTES + 1)
    finally:
        if file_fd >= 0:
            os.close(file_fd)
    if len(raw) > MAX_MANIFEST_BYTES:
        raise SessionPathError(
            f"Session manifest exceeds the {MAX_MANIFEST_BYTES}-byte limit: {manifest}"
        )
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SessionValidationError(
            f"Session manifest is not UTF-8: {manifest}"
        ) from error
    try:
        value = json.loads(decoded, parse_constant=_reject_json_constant)
    except (ValueError, RecursionError) as error:
        raise SessionValidationError(
            f"Invalid session manifest JSON: {manifest}"
        ) from error
    if not isinstance(value, dict):
        raise SessionValidationError(f"Session manifest must be an object: {manifest}")
    return value


@dataclass(frozen=True)
class _Session:
    manifest: dict
    segments: list[dict]


def _load(root: Path, root_fd: int, session_id: str) -> _Session:
    """One session as the app reads it, or an error saying why it cannot be."""
    manifest = validate_session(_read_manifest(root, root_fd, session_id), session_id)
    try:
        return _Session(manifest, _segments(manifest))
    except OverflowError as error:
        raise SessionValidationError(
            f"Session {session_id} has times outside the representable range."
        ) from error


def _scan_sessions(
    root_override: str | os.PathLike[str] | None,
) -> tuple[list[_Session], int]:
    """Every readable session across the stores, and how many were skipped.

    Entries whose name is not a UUID are ignored. A UUID-named entry that is a
    link, lacks a safe manifest, or cannot be read the way the app reads it is
    skipped and counted; it never fails the whole scan. A missing store yields
    nothing. As in the app, a session in an earlier store hides the same ID in
    a later one.
    """
    found: dict[str, _Session] = {}
    skipped = 0
    for root in sessions_roots(root_override):
        try:
            with _open_root(root) as root_fd:
                for name in sorted(os.listdir(root_fd)):
                    try:
                        validate_session_id(name, "session ID")
                    except SessionValidationError:
                        continue
                    try:
                        session = _load(root, root_fd, name)
                    except (OSError, ValueError):
                        skipped += 1
                        continue
                    found.setdefault(session.manifest["id"].upper(), session)
        except FileNotFoundError:
            continue
    return list(found.values()), skipped


def _find_session(
    session_id: str, root_override: str | os.PathLike[str] | None
) -> _Session:
    """The first store holding a readable copy wins, as in the app. Otherwise the
    first reason a copy could not be read, or not found."""
    session_id = validate_session_id(session_id, "session ID")
    failure: Exception | None = None
    for root in sessions_roots(root_override):
        try:
            with _open_root(root) as root_fd:
                return _load(root, root_fd, session_id)
        except FileNotFoundError as error:
            failure = failure or error
        except (OSError, ValueError) as error:
            if failure is None or isinstance(failure, FileNotFoundError):
                failure = error
    if isinstance(failure, FileNotFoundError) or failure is None:
        raise FileNotFoundError(f"Session not found: {session_id}")
    raise failure


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


def _segments(session: dict) -> list[dict]:
    """The segments as the app reads them. Earliest-format offsets become dates
    and every id is derived, ignoring anything else stored with them; a current
    segment without an id gets the one the app derives."""
    earliest, stored = decode_transcript_segments(session)
    started_at = parse_date(session["startedAt"])
    if earliest:
        return [
            {
                "id": _stable_id(
                    "legacy-offset-transcript-segment",
                    [f"{started_at.timestamp():.3f}", str(index), segment["text"]],
                ),
                "speaker": segment["speaker"],
                "text": segment["text"],
                "timestamp": _iso(
                    started_at
                    + timedelta(seconds=legacy_offset_seconds(segment["timestamp"]))
                ),
            }
            for index, segment in enumerate(stored)
        ]
    return [
        {
            **segment,
            "id": segment.get("id")
            or _stable_id(
                "legacy-transcript-segment",
                [
                    segment["speaker"],
                    segment["text"],
                    f"{parse_date(segment['timestamp']).timestamp():.3f}",
                ],
            ),
        }
        for segment in stored
    ]


def _display_title(session: dict) -> str:
    """The title the app shows: "Meeting …" records read as "Session …"."""
    title = session["title"]
    return (
        "Session " + title[len("Meeting ") :] if title.startswith("Meeting ") else title
    )


def _speaker(segment: dict) -> str:
    return segment["speaker"].strip() or UNNAMED_SPEAKER


def _line(segment: dict) -> str:
    return f"{_speaker(segment)}: {segment['text'].strip()}"


def _spoken(segments: list[dict]) -> list[dict]:
    return [segment for segment in segments if segment["text"].strip()]


def _sort_key(session: _Session) -> tuple[datetime, str]:
    return parse_date(session.manifest["startedAt"]), session.manifest["id"]


def _summary(session: _Session) -> dict:
    return {
        "id": session.manifest["id"],
        "title": _display_title(session.manifest),
        "startedAt": session.manifest["startedAt"],
        "status": session.manifest["status"],
        "segmentCount": len(session.segments),
        "hasTranscript": bool(_spoken(session.segments)),
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
    sessions, skipped = _scan_sessions(root)
    sessions.sort(key=_sort_key, reverse=True)
    return {
        "total": len(sessions),
        "offset": offset,
        "limit": limit,
        "skippedCount": skipped,
        "sessions": [
            _summary(session) for session in sessions[offset : offset + limit]
        ],
    }


def get_transcript(
    session_id: str, *, root: str | os.PathLike[str] | None = None
) -> dict:
    """One session's transcript, as stored, plus a plain ``Speaker: text`` rendering."""
    session = _find_session(session_id, root)
    segments = session.segments
    return {
        "id": session.manifest["id"],
        "title": _display_title(session.manifest),
        "startedAt": session.manifest["startedAt"],
        "status": session.manifest["status"],
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
    offset: int = 0,
    *,
    root: str | os.PathLike[str] | None = None,
) -> dict:
    """Case-insensitive search of titles and spoken text, as the app searches.

    A session matches when its title and text contain the whole phrase or every
    word of it. Speaker names are not searched. Snippets come from the text.
    """
    if not isinstance(query, str):
        raise ValueError("query must be a string.")
    needle = query.strip()
    if not needle:
        raise ValueError("query must not be blank.")
    if len(needle) > MAX_QUERY_LENGTH:
        raise ValueError(f"query must be at most {MAX_QUERY_LENGTH} characters.")
    limit = _bounded(limit, "limit", 1, MAX_SEARCH_LIMIT)
    offset = _bounded(offset, "offset", 0)

    phrase = re.compile(re.escape(needle), re.IGNORECASE)
    words = [re.compile(re.escape(word), re.IGNORECASE) for word in needle.split()]
    sessions, skipped = _scan_sessions(root)
    sessions.sort(key=_sort_key, reverse=True)
    results = []
    for session in sessions:
        spoken = _spoken(session.segments)
        searchable = "\n".join(
            [_display_title(session.manifest), *(s["text"] for s in spoken)]
        )
        if not phrase.search(searchable) and not all(
            word.search(searchable) for word in words
        ):
            continue
        snippets = []
        for segment in spoken:
            text = segment["text"].strip()
            match = phrase.search(text) or _first_match(text, words)
            if match:
                snippets.append(
                    {
                        "segmentId": segment["id"],
                        "speaker": _speaker(segment),
                        "timestamp": segment["timestamp"],
                        "snippet": _snippet(text, match),
                    }
                )
        results.append(
            {
                **_summary(session),
                "matchingSegmentCount": len(snippets),
                "snippets": snippets[:MAX_SNIPPETS_PER_SESSION],
            }
        )

    return {
        "query": needle,
        "totalMatches": len(results),
        "offset": offset,
        "limit": limit,
        "skippedCount": skipped,
        "results": results[offset : offset + limit],
    }
