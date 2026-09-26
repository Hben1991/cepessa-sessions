import json
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

import pytest


def make_id(label: str) -> str:
    return str(uuid5(NAMESPACE_URL, f"cepessa-sessions-mcp-test:{label}"))


def segment(
    speaker: str,
    text: str,
    timestamp: str = "2026-06-11T08:00:01Z",
    *,
    label: str | None = None,
    **extra,
) -> dict:
    return {
        "id": make_id(f"segment:{label or speaker + text + timestamp}"),
        "speaker": speaker,
        "text": text,
        "timestamp": timestamp,
        **extra,
    }


def session_payload(
    session_id: str,
    *,
    title: str = "Fixture session",
    started_at: str = "2026-06-11T08:00:00Z",
    status: str = "ready",
    segments: list[dict] | None = None,
    **extra,
) -> dict:
    return {
        "id": session_id,
        "title": title,
        "startedAt": started_at,
        "status": status,
        "transcriptSegments": segments if segments is not None else [],
        **extra,
    }


def write_session(
    root: Path, session_id: str, payload: dict | None = None, **kwargs
) -> Path:
    """Write ``<root>/<id>/session.json`` the way the desktop app lays it out."""
    directory = root / session_id
    directory.mkdir(parents=True)
    manifest = directory / "session.json"
    body = payload if payload is not None else session_payload(session_id, **kwargs)
    manifest.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
    return manifest


@pytest.fixture(autouse=True)
def _never_default_root(tmp_path, monkeypatch):
    """No test may fall back to the owner's real sessions store."""
    monkeypatch.setenv("CEPESSA_SESSIONS_ROOT", str(tmp_path / "unconfigured-root"))


@pytest.fixture
def sessions_root(tmp_path, monkeypatch) -> Path:
    root = tmp_path / "Sessions"
    root.mkdir()
    monkeypatch.setenv("CEPESSA_SESSIONS_ROOT", str(root))
    return root
