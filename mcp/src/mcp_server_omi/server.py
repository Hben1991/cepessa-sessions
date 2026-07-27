import os
from enum import Enum
import json
from typing import Any, List, Optional
from datetime import datetime, timedelta
from pathlib import Path
import requests
import logging
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool
from pydantic import BaseModel, Field

from .local_brain import (
    get_meeting_evidence,
    meeting_brain_status,
    prepare_agent_context,
    resolve_participant,
    search_meeting_brain,
)


class MemoryCategory(str, Enum):
    core = "core"
    hobbies = "hobbies"
    lifestyle = "lifestyle"
    interests = "interests"
    habits = "habits"
    work = "work"
    skills = "skills"
    learnings = "learnings"
    other = "other"


class ConversationCategory(str, Enum):
    personal = "personal"
    education = "education"
    health = "health"
    finance = "finance"
    legal = "legal"
    philosophy = "philosophy"
    spiritual = "spiritual"
    science = "science"
    entrepreneurship = "entrepreneurship"
    parenting = "parenting"
    romance = "romantic"
    travel = "travel"
    inspiration = "inspiration"
    technology = "technology"
    business = "business"
    social = "social"
    work = "work"
    sports = "sports"
    politics = "politics"
    literature = "literature"
    history = "history"
    architecture = "architecture"
    music = "music"
    weather = "weather"
    news = "news"
    entertainment = "entertainment"
    psychology = "psychology"
    real = "real"
    design = "design"
    family = "family"
    economics = "economics"
    environment = "environment"
    other = "other"


base_url = os.getenv("OMI_API_BASE_URL", "https://api.omi.me/v1/mcp/")
if not base_url or base_url == "":
    raise Exception("Base URL not found")

DEFAULT_CEPESSA_SESSIONS_ROOT = (
    Path.home() / "Library/Application Support/Cepessa/Sessions"
)
DEFAULT_CEPESSA_CLIPS_ROOT = Path.home() / "Library/Application Support/Cepessa/Clips"


class OmiTools(str, Enum):
    GET_MEMORIES = "get_memories"
    CREATE_MEMORY = "create_memory"
    DELETE_MEMORY = "delete_memory"
    EDIT_MEMORY = "edit_memory"
    GET_CONVERSATIONS = "get_conversations"
    GET_CONVERSATION_BY_ID = "get_conversation_by_id"
    LIST_LOCAL_SESSIONS = "list_local_sessions"
    GET_LOCAL_SESSION_TRANSCRIPT = "get_local_session_transcript"
    SEARCH_LOCAL_SESSION_TRANSCRIPTS = "search_local_session_transcripts"
    UPDATE_LOCAL_SESSION_TITLE = "update_local_session_title"
    GET_LOCAL_SESSION_DATA = "get_local_session_data"
    LIST_LOCAL_SESSION_FILES = "list_local_session_files"
    UPDATE_LOCAL_SESSION_FIELDS = "update_local_session_fields"
    LIST_LOCAL_CLIPS = "list_local_clips"
    GET_LOCAL_CLIP = "get_local_clip"
    LIST_LOCAL_CLIP_FILES = "list_local_clip_files"
    BRAIN_STATUS = "brain_status"
    SEARCH_MEETING_BRAIN = "search_meeting_brain"
    PREPARE_AGENT_CONTEXT = "prepare_agent_context"
    GET_MEETING_EVIDENCE = "get_meeting_evidence"
    RESOLVE_PARTICIPANT = "resolve_participant"


class GetMemories(BaseModel):
    api_key: Optional[str] = Field(
        description="The user's MCP API key. If not provided, it will be read from the OMI_API_KEY environment variable. For more details, see https://docs.omi.me/doc/developer/MCP",
        default=None,
    )
    categories: List[MemoryCategory] = Field(
        description="The categories of memories to filter by.", default=[]
    )
    limit: int = Field(description="The number of memories to retrieve.", default=100)
    offset: int = Field(
        description="The offset of the memories to retrieve.", default=0
    )


class CreateMemory(BaseModel):
    api_key: Optional[str] = Field(
        description="The user's MCP API key. If not provided, it will be read from the OMI_API_KEY environment variable. For more details, see https://docs.omi.me/doc/developer/MCP",
        default=None,
    )
    content: str = Field(description="The content of the memory.")
    category: MemoryCategory = Field(
        description="The category of the memory to create."
    )


class DeleteMemory(BaseModel):
    api_key: Optional[str] = Field(
        description="The user's MCP API key. If not provided, it will be read from the OMI_API_KEY environment variable. For more details, see https://docs.omi.me/doc/developer/MCP",
        default=None,
    )
    memory_id: str = Field(description="The ID of the memory to delete.")


class EditMemory(BaseModel):
    api_key: Optional[str] = Field(
        description="The user's MCP API key. If not provided, it will be read from the OMI_API_KEY environment variable. For more details, see https://docs.omi.me/doc/developer/MCP",
        default=None,
    )
    memory_id: str = Field(description="The ID of the memory to edit.")
    content: str = Field(description="The new content for the memory.")


class GetConversations(BaseModel):
    api_key: Optional[str] = Field(
        description="The user's MCP API key. If not provided, it will be read from the OMI_API_KEY environment variable. For more details, see https://docs.omi.me/doc/developer/MCP",
        default=None,
    )
    start_date: Optional[str] = Field(
        description="Filter conversations after this date (yyyy-mm-dd)", default=None
    )
    end_date: Optional[str] = Field(
        description="Filter conversations before this date (yyyy-mm-dd)", default=None
    )
    categories: List[ConversationCategory] = Field(
        description="Filter by conversation categories.", default=[]
    )
    limit: int = Field(
        description="The number of conversations to retrieve.", default=100
    )
    offset: int = Field(
        description="The offset of the conversations to retrieve.", default=0
    )


class GetConversationById(BaseModel):
    api_key: Optional[str] = Field(
        description="The user's MCP API key. If not provided, it will be read from the OMI_API_KEY environment variable. For more details, see https://docs.omi.me/doc/developer/MCP",
        default=None,
    )
    conversation_id: str = Field(description="The ID of the conversation to retrieve.")


class ListLocalSessions(BaseModel):
    sessions_root: Optional[str] = Field(
        description="Path to the Cepessa Sessions root. Defaults to CEPESSA_SESSIONS_ROOT or ~/Library/Application Support/Cepessa/Sessions.",
        default=None,
    )
    limit: int = Field(
        description="The number of local sessions to retrieve.", default=20
    )
    offset: int = Field(
        description="The offset of the local sessions to retrieve.", default=0
    )


class GetLocalSessionTranscript(BaseModel):
    session_id: str = Field(description="The local Cepessa session ID to retrieve.")
    sessions_root: Optional[str] = Field(
        description="Path to the Cepessa Sessions root. Defaults to CEPESSA_SESSIONS_ROOT or ~/Library/Application Support/Cepessa/Sessions.",
        default=None,
    )


class SearchLocalSessionTranscripts(BaseModel):
    query: str = Field(
        description="Case-insensitive words to search for in local transcript text."
    )
    sessions_root: Optional[str] = Field(
        description="Path to the Cepessa Sessions root. Defaults to CEPESSA_SESSIONS_ROOT or ~/Library/Application Support/Cepessa/Sessions.",
        default=None,
    )
    limit: int = Field(
        description="Maximum number of matching sessions to return.", default=10
    )


class UpdateLocalSessionTitle(BaseModel):
    session_id: str = Field(description="The local Cepessa session ID to rename.")
    title: str = Field(
        description="The new title to write into the local session.json file."
    )
    sessions_root: Optional[str] = Field(
        description="Path to the Cepessa Sessions root. Defaults to CEPESSA_SESSIONS_ROOT or ~/Library/Application Support/Cepessa/Sessions.",
        default=None,
    )


class GetLocalSessionData(BaseModel):
    session_id: str = Field(description="The local Cepessa session ID to retrieve.")
    sessions_root: Optional[str] = Field(
        description="Path to the Cepessa Sessions root. Defaults to CEPESSA_SESSIONS_ROOT or ~/Library/Application Support/Cepessa/Sessions.",
        default=None,
    )


class ListLocalSessionFiles(BaseModel):
    session_id: str = Field(description="The local Cepessa session ID to inspect.")
    sessions_root: Optional[str] = Field(
        description="Path to the Cepessa Sessions root. Defaults to CEPESSA_SESSIONS_ROOT or ~/Library/Application Support/Cepessa/Sessions.",
        default=None,
    )


class UpdateLocalSessionFields(BaseModel):
    session_id: str = Field(description="The local Cepessa session ID to update.")
    fields: dict[str, Any] = Field(
        description="Top-level JSON fields to merge into session.json. This enables current and future app-backed session features."
    )


class ListLocalClips(BaseModel):
    clips_root: Optional[str] = Field(
        description="Path to the Cepessa CLIPS root. Defaults to CEPESSA_CLIPS_ROOT or ~/Library/Application Support/Cepessa/Clips.",
        default=None,
    )
    limit: int = Field(description="The number of local CLIPS to retrieve.", default=20)
    offset: int = Field(
        description="The offset of the local CLIPS to retrieve.", default=0
    )


class GetLocalClip(BaseModel):
    clip_id: str = Field(description="The local Cepessa CLIP ID to retrieve.")
    clips_root: Optional[str] = Field(
        description="Path to the Cepessa CLIPS root. Defaults to CEPESSA_CLIPS_ROOT or ~/Library/Application Support/Cepessa/Clips.",
        default=None,
    )


class ListLocalClipFiles(BaseModel):
    clip_id: str = Field(description="The local Cepessa CLIP ID to inspect.")
    clips_root: Optional[str] = Field(
        description="Path to the Cepessa CLIPS root. Defaults to CEPESSA_CLIPS_ROOT or ~/Library/Application Support/Cepessa/Clips.",
        default=None,
    )
    sessions_root: Optional[str] = Field(
        description="Path to the Cepessa Sessions root. Defaults to CEPESSA_SESSIONS_ROOT or ~/Library/Application Support/Cepessa/Sessions.",
        default=None,
    )


class BrainStatus(BaseModel):
    pass


class SearchMeetingBrain(BaseModel):
    query: str = Field(
        description="Hebrew, English, or mixed-language terms to find in meeting evidence."
    )
    limit: int = Field(description="Maximum matching segments to return.", default=10)


class PrepareAgentContext(BaseModel):
    query: str = Field(
        description="The question or topic for which bounded meeting context is needed."
    )
    token_budget: int = Field(
        description="Maximum estimated tokens of transcript evidence to return.",
        default=2000,
    )
    limit: int = Field(
        description="Maximum search hits considered while assembling context.",
        default=20,
    )


class GetMeetingEvidence(BaseModel):
    session_id: str = Field(description="The local Cepessa session identifier.")
    segment_id: Optional[str] = Field(
        description="Optional exact transcript segment identifier.", default=None
    )
    context_segments: int = Field(
        description="Neighboring segments to return around the requested segment.",
        default=2,
    )


class ResolveParticipant(BaseModel):
    name: str = Field(
        description="Participant name or stored speaker label to investigate."
    )
    limit: int = Field(description="Maximum candidates to explain.", default=10)


def get_memories(
    logger: logging.Logger,
    api_key: str,
    offset: int = 0,
    limit: int = 100,
    categories: List[MemoryCategory] = [],
) -> List:
    logger.info(f"Getting memories with params: {offset}, {limit}, {categories}")
    params = {"offset": offset, "limit": limit}
    if categories:
        params["categories"] = ",".join([c.value for c in categories])
    logger.info(f"get_memories params: {params}")
    try:
        response = requests.get(
            f"{base_url}memories",
            params=params,
            headers={"Authorization": f"Bearer {api_key}"},
        )
        logger.info(f"get_memories response: {response.json()}")
        return response.json()
    except Exception as e:
        logger.error(f"Error getting memories: {e}")
        raise e


def create_memory(api_key: str, content: str, category: MemoryCategory) -> dict:
    response = requests.post(
        f"{base_url}memories",
        headers={"Authorization": f"Bearer {api_key}"},
        json={"content": content, "category": category},
    )
    return response.json()


def delete_memory(api_key: str, memory_id: str) -> dict:
    response = requests.delete(
        f"{base_url}memories/{memory_id}",
        headers={"Authorization": f"Bearer {api_key}"},
    )
    return response.json()


def edit_memory(api_key: str, memory_id: str, content: str) -> dict:
    response = requests.patch(
        f"{base_url}memories/{memory_id}",
        headers={"Authorization": f"Bearer {api_key}"},
        params={"value": content},
    )
    return response.json()


def get_conversations(
    logger: logging.Logger,
    api_key: str,
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    categories: List[ConversationCategory] = [],
    limit: int = 100,
    offset: int = 0,
) -> List:
    params = {"limit": limit, "offset": offset}
    if start_date:
        try:
            params["start_date"] = datetime.strptime(start_date, "%Y-%m-%d").isoformat()
        except ValueError:
            logger.warning(f"Could not parse start date: {start_date}")
    if end_date:
        try:
            # Set to end of day (23:59:59) so the entire day is included
            params["end_date"] = (
                datetime.strptime(end_date, "%Y-%m-%d")
                + timedelta(days=1)
                - timedelta(seconds=1)
            ).isoformat()
        except ValueError:
            logger.warning(f"Could not parse end date: {end_date}")
    if categories:
        params["categories"] = ",".join([c.value for c in categories])

    logger.info(f"Getting conversations with params: {params}")
    response = requests.get(
        f"{base_url}conversations",
        params=params,
        headers={"Authorization": f"Bearer {api_key}"},
    )
    return response.json()


def get_conversation_by_id(api_key: str, conversation_id: str) -> dict:
    response = requests.get(
        f"{base_url}conversations/{conversation_id}",
        headers={"Authorization": f"Bearer {api_key}"},
    )
    return response.json()


def _local_sessions_root(sessions_root: Optional[str] = None) -> Path:
    raw_root = sessions_root or os.getenv("CEPESSA_SESSIONS_ROOT")
    if raw_root:
        return Path(raw_root).expanduser()
    return DEFAULT_CEPESSA_SESSIONS_ROOT


def _local_clips_root(clips_root: Optional[str] = None) -> Path:
    raw_root = clips_root or os.getenv("CEPESSA_CLIPS_ROOT")
    if raw_root:
        return Path(raw_root).expanduser()
    return DEFAULT_CEPESSA_CLIPS_ROOT


def _read_local_session(session_json_path: Path) -> dict:
    with session_json_path.open("r", encoding="utf-8") as file:
        return json.load(file)


def _write_local_session(session_json_path: Path, session: dict) -> None:
    temporary_path = session_json_path.with_suffix(".json.tmp")
    with temporary_path.open("w", encoding="utf-8") as file:
        json.dump(session, file, ensure_ascii=False, indent=2)
        file.write("\n")
    temporary_path.replace(session_json_path)


def _local_session_paths(sessions_root: Optional[str] = None) -> list[Path]:
    root = _local_sessions_root(sessions_root)
    if not root.exists():
        return []
    return sorted(root.glob("*/session.json"))


def _local_clip_paths(clips_root: Optional[str] = None) -> list[Path]:
    root = _local_clips_root(clips_root)
    if not root.exists():
        return []
    return sorted(root.glob("*/clip.json"))


def _session_segments(session: dict) -> list[dict]:
    segments = session.get("transcriptSegments")
    if not segments:
        segments = session.get("segments")
    return segments if isinstance(segments, list) else []


def _segment_line(segment: dict) -> str:
    speaker = str(segment.get("speaker") or "Speaker").strip() or "Speaker"
    text = str(segment.get("text") or "").strip()
    return f"{speaker}: {text}".strip()


def _session_started_at(session: dict) -> str:
    return str(session.get("startedAt") or "")


def _session_summary(session: dict, session_json_path: Path) -> dict:
    segments = _session_segments(session)
    preview_lines = [
        _segment_line(segment)
        for segment in segments
        if str(segment.get("text") or "").strip()
    ]
    return {
        "id": str(session.get("id") or session_json_path.parent.name),
        "title": str(session.get("title") or "Untitled session"),
        "started_at": _session_started_at(session),
        "status": session.get("status"),
        "transcript_segment_count": len(segments),
        "transcript_preview": " ".join(preview_lines)[:500],
    }


def _clip_transcript_segments(clip: dict) -> list[dict]:
    segments = clip.get("transcriptSegments")
    return segments if isinstance(segments, list) else []


def _clip_summary(clip: dict, clip_json_path: Path) -> dict:
    segments = _clip_transcript_segments(clip)
    preview = " ".join(
        str(segment.get("text") or "").strip()
        for segment in segments
        if str(segment.get("text") or "").strip()
    )
    return {
        "id": str(clip.get("id") or clip_json_path.parent.name),
        "title": str(clip.get("title") or "Untitled CLIP"),
        "started_at": str(clip.get("startedAt") or ""),
        "ended_at": clip.get("endedAt"),
        "status": clip.get("status"),
        "intent": clip.get("intent"),
        "transcript_segment_count": len(segments),
        "transcript_preview": preview[:500],
        "clip_directory": str(clip_json_path.parent),
        "video_path": str(
            clip_json_path.parent / str(clip.get("videoFileName") or "clip-video.mov")
        ),
    }


def list_local_sessions(
    sessions_root: Optional[str] = None, limit: int = 20, offset: int = 0
) -> list[dict]:
    sessions = []
    for session_json_path in _local_session_paths(sessions_root):
        try:
            session = _read_local_session(session_json_path)
        except (OSError, json.JSONDecodeError):
            continue
        sessions.append(_session_summary(session, session_json_path))

    sessions.sort(key=lambda session: session.get("started_at") or "", reverse=True)
    return sessions[max(0, offset) : max(0, offset) + max(0, limit)]


def list_local_clips(
    clips_root: Optional[str] = None, limit: int = 20, offset: int = 0
) -> list[dict]:
    clips = []
    for clip_json_path in _local_clip_paths(clips_root):
        try:
            clip = _read_local_session(clip_json_path)
        except (OSError, json.JSONDecodeError):
            continue
        clips.append(_clip_summary(clip, clip_json_path))

    clips.sort(key=lambda clip: clip.get("started_at") or "", reverse=True)
    return clips[max(0, offset) : max(0, offset) + max(0, limit)]


def _resolve_local_session_json(
    session_id: str, sessions_root: Optional[str] = None
) -> Path:
    if "/" in session_id or "\\" in session_id or session_id in {"", ".", ".."}:
        raise ValueError("Invalid local session ID.")

    session_json_path = (
        _local_sessions_root(sessions_root) / session_id / "session.json"
    )
    if not session_json_path.exists():
        raise FileNotFoundError(f"Local session not found: {session_id}")
    return session_json_path


def _resolve_local_clip_json(clip_id: str, clips_root: Optional[str] = None) -> Path:
    if "/" in clip_id or "\\" in clip_id or clip_id in {"", ".", ".."}:
        raise ValueError("Invalid local CLIP ID.")

    clip_json_path = _local_clips_root(clips_root) / clip_id / "clip.json"
    if not clip_json_path.exists():
        raise FileNotFoundError(f"Local CLIP not found: {clip_id}")
    return clip_json_path


def _transcript_markdown(session: dict) -> str:
    lines = []
    for segment in _session_segments(session):
        text = str(segment.get("text") or "").strip()
        if not text:
            continue
        timestamp = str(segment.get("timestamp") or "").strip()
        speaker = str(segment.get("speaker") or "Speaker").strip() or "Speaker"
        prefix = f"[{timestamp}] " if timestamp else ""
        lines.append(f"- {prefix}{speaker}: {text}")
    return "\n".join(lines)


def get_local_session_transcript(
    session_id: str, sessions_root: Optional[str] = None
) -> dict:
    session_json_path = _resolve_local_session_json(session_id, sessions_root)
    session = _read_local_session(session_json_path)
    segments = _session_segments(session)
    return {
        "id": str(session.get("id") or session_json_path.parent.name),
        "title": str(session.get("title") or "Untitled session"),
        "started_at": _session_started_at(session),
        "status": session.get("status"),
        "transcript_segment_count": len(segments),
        "transcript_markdown": _transcript_markdown(session),
        "recap": session.get("recap"),
        "document_markdown": session.get("documentMarkdown"),
        "session_json_path": str(session_json_path),
    }


def get_local_session_data(
    session_id: str, sessions_root: Optional[str] = None
) -> dict:
    session_json_path = _resolve_local_session_json(session_id, sessions_root)
    session = _read_local_session(session_json_path)
    return {
        "id": str(session.get("id") or session_json_path.parent.name),
        "session": session,
        "session_directory": str(session_json_path.parent),
        "session_json_path": str(session_json_path),
    }


def get_local_clip(clip_id: str, clips_root: Optional[str] = None) -> dict:
    clip_json_path = _resolve_local_clip_json(clip_id, clips_root)
    clip = _read_local_session(clip_json_path)
    clip_directory = clip_json_path.parent
    return {
        "id": str(clip.get("id") or clip_json_path.parent.name),
        "clip": clip,
        "transcript_segments": _clip_transcript_segments(clip),
        "post_notes": clip.get("postNotes") or "",
        "clip_directory": str(clip_directory),
        "clip_json_path": str(clip_json_path),
        "video_path": str(
            clip_directory / str(clip.get("videoFileName") or "clip-video.mov")
        ),
        "audio_path": str(
            clip_directory / str(clip.get("audioFileName") or "clip-audio.wav")
        ),
        "transcript_path": str(
            clip_directory / str(clip.get("transcriptFileName") or "transcript.json")
        ),
        "notes_path": str(
            clip_directory / str(clip.get("notesFileName") or "notes.md")
        ),
    }


def _file_inventory_entry(file_path: Path, session_directory: Path) -> dict:
    stat = file_path.stat()
    return {
        "path": str(file_path),
        "relative_path": file_path.relative_to(session_directory).as_posix(),
        "size_bytes": stat.st_size,
        "extension": file_path.suffix,
    }


def list_local_session_files(
    session_id: str, sessions_root: Optional[str] = None
) -> dict:
    session_json_path = _resolve_local_session_json(session_id, sessions_root)
    session_directory = session_json_path.parent
    files = []
    for file_path in sorted(session_directory.rglob("*")):
        if file_path.is_file() and file_path.name != "session.json":
            files.append(_file_inventory_entry(file_path, session_directory))
    return {
        "id": session_id,
        "session_directory": str(session_directory),
        "files": files,
    }


def list_local_clip_files(clip_id: str, clips_root: Optional[str] = None) -> dict:
    clip_json_path = _resolve_local_clip_json(clip_id, clips_root)
    clip_directory = clip_json_path.parent
    files = []
    for file_path in sorted(clip_directory.rglob("*")):
        if file_path.is_file():
            files.append(_file_inventory_entry(file_path, clip_directory))
    return {
        "id": clip_id,
        "clip_directory": str(clip_directory),
        "files": files,
    }


def _matching_snippet(text: str, query: str, radius: int = 120) -> str:
    lower_text = text.lower()
    lower_query = query.lower()
    index = lower_text.find(lower_query)
    if index < 0:
        terms = [term for term in lower_query.split() if term]
        indexes = [
            lower_text.find(term) for term in terms if lower_text.find(term) >= 0
        ]
        index = min(indexes) if indexes else 0
    start = max(0, index - radius)
    end = min(len(text), index + len(query) + radius)
    prefix = "..." if start > 0 else ""
    suffix = "..." if end < len(text) else ""
    return f"{prefix}{text[start:end].strip()}{suffix}"


def search_local_session_transcripts(
    query: str,
    sessions_root: Optional[str] = None,
    limit: int = 10,
) -> list[dict]:
    normalized_query = query.strip().lower()
    if not normalized_query:
        return []

    matches = []
    terms = [term for term in normalized_query.split() if term]
    for session_json_path in _local_session_paths(sessions_root):
        try:
            session = _read_local_session(session_json_path)
        except (OSError, json.JSONDecodeError):
            continue

        transcript_text = "\n".join(
            _segment_line(segment)
            for segment in _session_segments(session)
            if str(segment.get("text") or "").strip()
        )
        lower_transcript = transcript_text.lower()
        if normalized_query not in lower_transcript and not all(
            term in lower_transcript for term in terms
        ):
            continue

        summary = _session_summary(session, session_json_path)
        summary["snippet"] = _matching_snippet(transcript_text, query)
        matches.append(summary)

    matches.sort(key=lambda session: session.get("started_at") or "", reverse=True)
    return matches[: max(0, limit)]


def update_local_session_title(
    session_id: str,
    title: str,
    sessions_root: Optional[str] = None,
) -> dict:
    new_title = title.strip()
    if not new_title:
        raise ValueError("Local session title cannot be empty.")

    session_json_path = _resolve_local_session_json(session_id, sessions_root)
    session = _read_local_session(session_json_path)
    old_title = str(session.get("title") or "")
    session["title"] = new_title
    _write_local_session(session_json_path, session)

    updated = _read_local_session(session_json_path)
    summary = _session_summary(updated, session_json_path)
    summary["old_title"] = old_title
    summary["new_title"] = new_title
    summary["session_json_path"] = str(session_json_path)
    return summary


def update_local_session_fields(
    session_id: str,
    fields: dict[str, Any],
    sessions_root: Optional[str] = None,
) -> dict:
    if not isinstance(fields, dict) or not fields:
        raise ValueError("fields must be a non-empty object.")

    protected_fields = {"id"}
    blocked = sorted(protected_fields.intersection(fields.keys()))
    if blocked:
        raise ValueError(
            f"Cannot update protected session field(s): {', '.join(blocked)}"
        )

    session_json_path = _resolve_local_session_json(session_id, sessions_root)
    session = _read_local_session(session_json_path)
    for key, value in fields.items():
        session[key] = value
    _write_local_session(session_json_path, session)

    updated = _read_local_session(session_json_path)
    summary = _session_summary(updated, session_json_path)
    summary["updated_fields"] = sorted(fields.keys())
    summary["session_json_path"] = str(session_json_path)
    return summary


def requires_omi_api_key(tool_name: str) -> bool:
    local_tools = {
        OmiTools.LIST_LOCAL_SESSIONS.value,
        OmiTools.GET_LOCAL_SESSION_TRANSCRIPT.value,
        OmiTools.SEARCH_LOCAL_SESSION_TRANSCRIPTS.value,
        OmiTools.UPDATE_LOCAL_SESSION_TITLE.value,
        OmiTools.GET_LOCAL_SESSION_DATA.value,
        OmiTools.LIST_LOCAL_SESSION_FILES.value,
        OmiTools.UPDATE_LOCAL_SESSION_FIELDS.value,
        OmiTools.LIST_LOCAL_CLIPS.value,
        OmiTools.GET_LOCAL_CLIP.value,
        OmiTools.LIST_LOCAL_CLIP_FILES.value,
        OmiTools.BRAIN_STATUS.value,
        OmiTools.SEARCH_MEETING_BRAIN.value,
        OmiTools.PREPARE_AGENT_CONTEXT.value,
        OmiTools.GET_MEETING_EVIDENCE.value,
        OmiTools.RESOLVE_PARTICIPANT.value,
    }
    return str(tool_name) not in local_tools


async def serve(uid: str | None) -> None:
    logger = logging.getLogger(__name__)
    # if uid is not None:
    #     logger.info(f"Using uid: {uid}")

    server = Server("mcp-omi")
    logger.info("mcp-omi server started")

    @server.list_tools()
    async def list_tools() -> list[Tool]:
        return [
            Tool(
                name=OmiTools.GET_MEMORIES,
                description="Retrieve a list of memories. A memory is a known fact about the user across multiple domains.",
                inputSchema=GetMemories.model_json_schema(),
            ),
            Tool(
                name=OmiTools.CREATE_MEMORY,
                description="Create a new memory. A memory is a known fact about the user across multiple domains.",
                inputSchema=CreateMemory.model_json_schema(),
            ),
            Tool(
                name=OmiTools.DELETE_MEMORY,
                description="Delete a memory by ID. A memory is a known fact about the user across multiple domains.",
                inputSchema=DeleteMemory.model_json_schema(),
            ),
            Tool(
                name=OmiTools.EDIT_MEMORY,
                description="Edit a memory's content. A memory is a known fact about the user across multiple domains.",
                inputSchema=EditMemory.model_json_schema(),
            ),
            Tool(
                name=OmiTools.GET_CONVERSATIONS,
                description="Retrieve a list of conversation metadata. To get full transcripts, use get_conversation_by_id.",
                inputSchema=GetConversations.model_json_schema(),
            ),
            Tool(
                name=OmiTools.GET_CONVERSATION_BY_ID,
                description="Retrieve a conversation by ID including each segment of the transcript.",
                inputSchema=GetConversationById.model_json_schema(),
            ),
            Tool(
                name=OmiTools.LIST_LOCAL_SESSIONS,
                description="List local Cepessa Sessions stored on this Mac. Use this before fetching a local transcript.",
                inputSchema=ListLocalSessions.model_json_schema(),
            ),
            Tool(
                name=OmiTools.GET_LOCAL_SESSION_TRANSCRIPT,
                description="Retrieve a local Cepessa Session transcript directly from the app's session.json storage.",
                inputSchema=GetLocalSessionTranscript.model_json_schema(),
            ),
            Tool(
                name=OmiTools.SEARCH_LOCAL_SESSION_TRANSCRIPTS,
                description="Search local Cepessa Session transcripts stored on this Mac and return matching snippets.",
                inputSchema=SearchLocalSessionTranscripts.model_json_schema(),
            ),
            Tool(
                name=OmiTools.UPDATE_LOCAL_SESSION_TITLE,
                description="Rename a local Cepessa Session by writing the title field in the app's session.json storage.",
                inputSchema=UpdateLocalSessionTitle.model_json_schema(),
            ),
            Tool(
                name=OmiTools.GET_LOCAL_SESSION_DATA,
                description="Retrieve the full raw local Cepessa Session JSON, including current and future app feature fields.",
                inputSchema=GetLocalSessionData.model_json_schema(),
            ),
            Tool(
                name=OmiTools.LIST_LOCAL_SESSION_FILES,
                description="List all files inside a local Cepessa Session directory, including images, audio, exports, and future feature artifacts.",
                inputSchema=ListLocalSessionFiles.model_json_schema(),
            ),
            Tool(
                name=OmiTools.UPDATE_LOCAL_SESSION_FIELDS,
                description="Atomically merge top-level JSON fields into a local Cepessa session.json file for app-backed current and future features.",
                inputSchema=UpdateLocalSessionFields.model_json_schema(),
            ),
            Tool(
                name=OmiTools.LIST_LOCAL_CLIPS,
                description="List local Cepessa CLIPS stored on this Mac. CLIPS include screen video, transcript, and post notes.",
                inputSchema=ListLocalClips.model_json_schema(),
            ),
            Tool(
                name=OmiTools.GET_LOCAL_CLIP,
                description="Retrieve a local Cepessa CLIP bundle, including manifest JSON, transcript segments, notes, and media file paths.",
                inputSchema=GetLocalClip.model_json_schema(),
            ),
            Tool(
                name=OmiTools.LIST_LOCAL_CLIP_FILES,
                description="List every file inside a local Cepessa CLIP directory, including video, audio, transcript, and notes artifacts.",
                inputSchema=ListLocalClipFiles.model_json_schema(),
            ),
            Tool(
                name=OmiTools.BRAIN_STATUS,
                description="Report the standalone meeting-evidence index status and refresh it without modifying source sessions.",
                inputSchema=BrainStatus.model_json_schema(),
            ),
            Tool(
                name=OmiTools.SEARCH_MEETING_BRAIN,
                description="Search indexed meeting evidence with exact session, revision, segment, time, and source citations.",
                inputSchema=SearchMeetingBrain.model_json_schema(),
            ),
            Tool(
                name=OmiTools.PREPARE_AGENT_CONTEXT,
                description="Prepare bounded, cited meeting evidence for another agent. Transcript text is always treated as untrusted data.",
                inputSchema=PrepareAgentContext.model_json_schema(),
            ),
            Tool(
                name=OmiTools.GET_MEETING_EVIDENCE,
                description="Retrieve exact cited transcript evidence from one indexed session or segment.",
                inputSchema=GetMeetingEvidence.model_json_schema(),
            ),
            Tool(
                name=OmiTools.RESOLVE_PARTICIPANT,
                description="Explain possible participant-label matches with citations. Never performs identity binding or biometric matching.",
                inputSchema=ResolveParticipant.model_json_schema(),
            ),
        ]

    @server.call_tool()
    async def call_tool(name: str, arguments: dict) -> list[TextContent]:
        logger.info(f"Calling tool: {name} with arguments: {arguments}")

        if name == OmiTools.LIST_LOCAL_SESSIONS:
            result = list_local_sessions(
                sessions_root=arguments.get("sessions_root"),
                limit=arguments.get("limit", 20),
                offset=arguments.get("offset", 0),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.GET_LOCAL_SESSION_TRANSCRIPT:
            result = get_local_session_transcript(
                session_id=arguments["session_id"],
                sessions_root=arguments.get("sessions_root"),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.SEARCH_LOCAL_SESSION_TRANSCRIPTS:
            result = search_local_session_transcripts(
                query=arguments["query"],
                sessions_root=arguments.get("sessions_root"),
                limit=arguments.get("limit", 10),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.UPDATE_LOCAL_SESSION_TITLE:
            result = update_local_session_title(
                session_id=arguments["session_id"],
                title=arguments["title"],
                sessions_root=arguments.get("sessions_root"),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.GET_LOCAL_SESSION_DATA:
            result = get_local_session_data(
                session_id=arguments["session_id"],
                sessions_root=arguments.get("sessions_root"),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.LIST_LOCAL_SESSION_FILES:
            result = list_local_session_files(
                session_id=arguments["session_id"],
                sessions_root=arguments.get("sessions_root"),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.UPDATE_LOCAL_SESSION_FIELDS:
            result = update_local_session_fields(
                session_id=arguments["session_id"],
                fields=arguments["fields"],
                sessions_root=arguments.get("sessions_root"),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.LIST_LOCAL_CLIPS:
            result = list_local_clips(
                clips_root=arguments.get("clips_root"),
                limit=arguments.get("limit", 20),
                offset=arguments.get("offset", 0),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.GET_LOCAL_CLIP:
            result = get_local_clip(
                clip_id=arguments["clip_id"],
                clips_root=arguments.get("clips_root"),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.LIST_LOCAL_CLIP_FILES:
            result = list_local_clip_files(
                clip_id=arguments["clip_id"],
                clips_root=arguments.get("clips_root"),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.BRAIN_STATUS:
            result = meeting_brain_status()
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.SEARCH_MEETING_BRAIN:
            result = search_meeting_brain(
                query=arguments["query"],
                limit=arguments.get("limit", 10),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.PREPARE_AGENT_CONTEXT:
            result = prepare_agent_context(
                query=arguments["query"],
                token_budget=arguments.get("token_budget", 2000),
                limit=arguments.get("limit", 20),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.GET_MEETING_EVIDENCE:
            result = get_meeting_evidence(
                session_id=arguments["session_id"],
                segment_id=arguments.get("segment_id"),
                context_segments=arguments.get("context_segments", 2),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        elif name == OmiTools.RESOLVE_PARTICIPANT:
            result = resolve_participant(
                name=arguments["name"],
                limit=arguments.get("limit", 10),
            )
            return [
                TextContent(
                    type="text", text=json.dumps(result, indent=2, ensure_ascii=False)
                )
            ]

        api_key = arguments.get("api_key") or os.getenv("OMI_API_KEY")
        if not api_key:
            raise ValueError(
                "API key not provided and OMI_API_KEY environment variable not set."
            )

        if name == OmiTools.GET_MEMORIES:
            # return [TextContent(type="text", text=json.dumps(arguments, indent=2))]
            categories: List[str] = arguments.get("categories", [])
            if not isinstance(categories, list):
                raise ValueError(f"categories must be a list, got {type(categories)}")
            categories_enum = []
            for category in categories:
                try:
                    categories_enum.append(MemoryCategory(category))
                except ValueError:
                    logger.warning(f"Could not parse category: {category}")

            result = get_memories(
                logger,
                api_key,
                offset=arguments.get("offset", 0),
                limit=arguments.get("limit", 100),
                categories=categories_enum,
            )
            return [TextContent(type="text", text=json.dumps(result, indent=2))]

        elif name == OmiTools.CREATE_MEMORY:
            # return [TextContent(type="text", text=json.dumps(arguments, indent=2))]
            result = create_memory(
                api_key,
                content=arguments["content"],
                category=arguments["category"],
            )
            return [TextContent(type="text", text=json.dumps(result, indent=2))]

        elif name == OmiTools.DELETE_MEMORY:
            result = delete_memory(api_key, memory_id=arguments["memory_id"])
            return [TextContent(type="text", text=json.dumps(result, indent=2))]

        elif name == OmiTools.EDIT_MEMORY:
            result = edit_memory(
                api_key,
                memory_id=arguments["memory_id"],
                content=arguments["content"],
            )
            return [TextContent(type="text", text=json.dumps(result, indent=2))]

        elif name == OmiTools.GET_CONVERSATIONS:
            result = get_conversations(
                logger,
                api_key,
                start_date=arguments.get("start_date"),
                end_date=arguments.get("end_date"),
                categories=arguments.get("categories", []),
                limit=arguments.get("limit", 20),
                offset=arguments.get("offset", 0),
            )
            return [TextContent(type="text", text=json.dumps(result, indent=2))]

        elif name == OmiTools.GET_CONVERSATION_BY_ID:
            result = get_conversation_by_id(
                api_key, conversation_id=arguments["conversation_id"]
            )
            return [TextContent(type="text", text=json.dumps(result, indent=2))]

        raise ValueError(f"Unknown tool: {name}")

    options = server.create_initialization_options()
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, options, raise_exceptions=True)


# TODO:
# - add get conversations by semantic search + reranking
