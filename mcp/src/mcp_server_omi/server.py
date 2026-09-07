import json
import requests
import logging
import fcntl
import math
import os
import re
import stat
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timedelta
from enum import Enum
from pathlib import Path
from typing import Any, List, NoReturn, Optional
from uuid import UUID
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
MAX_LOCAL_JSON_BYTES = 32 * 1024 * 1024
GENERATED_SESSION_PACKAGE_DIRECTORY = "Exports"
GENERATED_SESSION_PACKAGE_NAMES = ("session-package.md", "session-package.json")
LOCAL_ID_PATTERN = re.compile(
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


class LocalSessionValidationError(ValueError):
    """Raised when a session cannot be decoded by the Swift app models."""


class LocalSessionPathError(ValueError):
    """Raised when a local MCP path is outside its configured root or unsafe."""


class LocalSessionLockError(LocalSessionPathError):
    """Raised when a local session lock cannot be acquired safely."""


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
        description=(
            "Top-level JSON fields to merge into session.json. User-editable fields "
            "include title, titleOrigin, recap, documentMarkdown, documentChat, and "
            "future user metadata. Capture and transcription-owned fields such as "
            "status, timestamps, transcriptSegments, captureArtifacts, "
            "audioArtifacts, transcriptionEvidence, and latestTranscriptionAttempt "
            "are rejected when changed."
        )
    )
    sessions_root: Optional[str] = Field(
        description="Path to the Cepessa Sessions root. Defaults to CEPESSA_SESSIONS_ROOT or ~/Library/Application Support/Cepessa/Sessions.",
        default=None,
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
    params: dict[str, Any] = {"offset": offset, "limit": limit}
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
    params: dict[str, Any] = {"limit": limit, "offset": offset}
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


def _validated_local_root(root: Path, label: str, *, allow_missing: bool) -> Path:
    """Return a canonical configured root, rejecting a symlink root."""
    root = root.expanduser()
    if not root.is_absolute():
        root = Path.cwd() / root
    try:
        root_stat = root.lstat()
    except FileNotFoundError:
        if allow_missing:
            return root
        raise FileNotFoundError(f"{label} root not found: {root}") from None
    except OSError as error:
        raise LocalSessionPathError(f"Cannot inspect {label} root: {root}") from error
    if stat.S_ISLNK(root_stat.st_mode):
        raise LocalSessionPathError(f"{label} root must not be a symlink: {root}")
    if not stat.S_ISDIR(root_stat.st_mode):
        raise LocalSessionPathError(f"{label} root is not a directory: {root}")
    try:
        return root.resolve(strict=True)
    except OSError as error:
        raise LocalSessionPathError(f"Cannot resolve {label} root: {root}") from error


def _validate_local_id(value: Any, field: str) -> str:
    if not isinstance(value, str) or not LOCAL_ID_PATTERN.fullmatch(value):
        raise LocalSessionValidationError(f"{field} must be a UUID string.")
    try:
        UUID(value)
    except ValueError as error:
        raise LocalSessionValidationError(f"{field} must be a UUID string.") from error
    return value


def _validated_regular_file(
    path: Path, *, label: str, max_bytes: Optional[int] = None
) -> Path:
    try:
        file_stat = path.lstat()
    except FileNotFoundError:
        raise FileNotFoundError(f"{label} not found: {path}") from None
    except OSError as error:
        raise LocalSessionPathError(f"Cannot inspect {label}: {path}") from error
    if stat.S_ISLNK(file_stat.st_mode):
        raise LocalSessionPathError(f"{label} must not be a symlink: {path}")
    if not stat.S_ISREG(file_stat.st_mode):
        raise LocalSessionPathError(f"{label} must be a regular file: {path}")
    if file_stat.st_nlink != 1:
        raise LocalSessionPathError(f"{label} must not be hard-linked: {path}")
    if max_bytes is not None and file_stat.st_size > max_bytes:
        raise LocalSessionPathError(
            f"{label} exceeds the {max_bytes}-byte limit: {path}"
        )
    return path


def _validated_bundle_json(
    root: Path, bundle_id: str, filename: str, label: str
) -> Path:
    bundle_id = _validate_local_id(bundle_id, f"{label} ID")
    bundle = root / bundle_id
    try:
        bundle_stat = bundle.lstat()
    except FileNotFoundError:
        raise FileNotFoundError(f"{label} not found: {bundle_id}") from None
    except OSError as error:
        raise LocalSessionPathError(f"Cannot inspect {label}: {bundle_id}") from error
    if stat.S_ISLNK(bundle_stat.st_mode):
        raise LocalSessionPathError(
            f"{label} directory must not be a symlink: {bundle}"
        )
    if not stat.S_ISDIR(bundle_stat.st_mode):
        raise LocalSessionPathError(f"{label} path is not a directory: {bundle}")
    try:
        if bundle.resolve(strict=True).parent != root:
            raise LocalSessionPathError(
                f"{label} directory is outside its configured root."
            )
    except OSError as error:
        raise LocalSessionPathError(
            f"Cannot resolve {label} directory: {bundle}"
        ) from error
    return _validated_regular_file(
        bundle / filename, label=f"{label} manifest", max_bytes=MAX_LOCAL_JSON_BYTES
    )


@contextmanager
def _local_session_lock(session_json_path: Path):
    """Hold the same bounded advisory lock used by the desktop store."""
    lock_path = session_json_path.parent / ".session.lock"
    flags = (
        os.O_RDWR
        | os.O_CREAT
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        file_descriptor = os.open(lock_path, flags, 0o600)
    except OSError as error:
        raise LocalSessionLockError(
            f"Cannot securely open local session lock: {lock_path}"
        ) from error
    try:
        lock_stat = os.fstat(file_descriptor)
        if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_nlink != 1:
            raise LocalSessionLockError(
                f"Local session lock is not a private regular file: {lock_path}"
            )
        deadline = time.monotonic() + 1.0
        while True:
            try:
                fcntl.flock(file_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise LocalSessionLockError(
                        f"Timed out waiting for local session lock: {lock_path}"
                    )
                time.sleep(0.01)
            except OSError as error:
                raise LocalSessionLockError(
                    f"Cannot acquire local session lock: {lock_path}"
                ) from error
        yield
    finally:
        try:
            fcntl.flock(file_descriptor, fcntl.LOCK_UN)
        finally:
            os.close(file_descriptor)


def _reject_json_constant(value: str) -> NoReturn:
    raise ValueError(f"Non-finite JSON number is not supported: {value}")


def _read_local_session(session_json_path: Path) -> dict:
    _validated_regular_file(
        session_json_path, label="local JSON", max_bytes=MAX_LOCAL_JSON_BYTES
    )
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        file_descriptor = os.open(session_json_path, flags)
    except OSError as error:
        raise LocalSessionPathError(
            f"Cannot securely open local JSON: {session_json_path}"
        ) from error
    try:
        opened_stat = os.fstat(file_descriptor)
        if not stat.S_ISREG(opened_stat.st_mode) or opened_stat.st_nlink != 1:
            raise LocalSessionPathError(
                f"Local JSON changed to an unsafe file: {session_json_path}"
            )
        with os.fdopen(file_descriptor, "rb") as file:
            file_descriptor = -1
            raw = file.read(MAX_LOCAL_JSON_BYTES + 1)
        if len(raw) > MAX_LOCAL_JSON_BYTES:
            raise LocalSessionPathError(
                f"Local JSON exceeds the {MAX_LOCAL_JSON_BYTES}-byte limit: {session_json_path}"
            )
        try:
            decoded = raw.decode("utf-8")
        except UnicodeDecodeError as error:
            raise LocalSessionValidationError(
                f"Local JSON is not UTF-8: {session_json_path}"
            ) from error
        try:
            value = json.loads(decoded, parse_constant=_reject_json_constant)
        except json.JSONDecodeError as error:
            raise LocalSessionValidationError(
                f"Invalid local JSON: {session_json_path}"
            ) from error
        except ValueError as error:
            raise LocalSessionValidationError(
                f"Invalid local JSON value: {session_json_path}"
            ) from error
        if not isinstance(value, dict):
            raise LocalSessionValidationError(
                f"Local JSON must contain an object: {session_json_path}"
            )
        return value
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)


def _write_local_session(session_json_path: Path, session: dict) -> None:
    """Atomically replace a validated session manifest without following links."""
    parent = session_json_path.parent
    parent_stat = parent.lstat()
    if stat.S_ISLNK(parent_stat.st_mode) or not stat.S_ISDIR(parent_stat.st_mode):
        raise LocalSessionPathError(f"Session directory is unsafe: {parent}")
    existing_mode = 0o600
    try:
        existing_stat = session_json_path.lstat()
    except FileNotFoundError:
        existing_stat = None
    if existing_stat is not None:
        _validated_regular_file(
            session_json_path, label="local JSON", max_bytes=MAX_LOCAL_JSON_BYTES
        )
        existing_mode = stat.S_IMODE(existing_stat.st_mode)
    temporary_path: Optional[Path] = None
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=".session-", suffix=".tmp", dir=str(parent)
    )
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(file_descriptor, existing_mode)
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as file:
            file_descriptor = -1
            json.dump(session, file, ensure_ascii=False, indent=2, allow_nan=False)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary_path, session_json_path)
        temporary_path = None
        try:
            directory_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            pass
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


def _invalidate_generated_session_packages(session_json_path: Path) -> None:
    """Remove only the desktop-generated package caches before metadata changes."""
    exports_directory = session_json_path.parent / GENERATED_SESSION_PACKAGE_DIRECTORY
    try:
        exports_stat = exports_directory.lstat()
    except FileNotFoundError:
        return
    if stat.S_ISLNK(exports_stat.st_mode) or not stat.S_ISDIR(exports_stat.st_mode):
        raise LocalSessionPathError(
            f"Generated package directory is unsafe: {exports_directory}"
        )

    for name in GENERATED_SESSION_PACKAGE_NAMES:
        cache_path = exports_directory / name
        try:
            cache_stat = cache_path.lstat()
        except FileNotFoundError:
            continue
        if (
            stat.S_ISLNK(cache_stat.st_mode)
            or not stat.S_ISREG(cache_stat.st_mode)
            or cache_stat.st_nlink != 1
        ):
            raise LocalSessionPathError(
                f"Generated package cache is unsafe: {cache_path}"
            )
        try:
            cache_path.unlink()
        except OSError as error:
            raise LocalSessionPathError(
                f"Cannot invalidate generated package cache: {cache_path}"
            ) from error


def _local_session_paths(sessions_root: Optional[str] = None) -> list[Path]:
    root = _validated_local_root(
        _local_sessions_root(sessions_root), "sessions", allow_missing=True
    )
    if not root.exists():
        return []
    paths = []
    for child in root.iterdir():
        try:
            child_stat = child.lstat()
            if stat.S_ISLNK(child_stat.st_mode) or not stat.S_ISDIR(child_stat.st_mode):
                continue
            _validate_local_id(child.name, "session ID")
            paths.append(
                _validated_regular_file(
                    child / "session.json",
                    label="session manifest",
                    max_bytes=MAX_LOCAL_JSON_BYTES,
                )
            )
        except (
            FileNotFoundError,
            LocalSessionPathError,
            LocalSessionValidationError,
            OSError,
        ):
            continue
    return sorted(paths)


def _local_clip_paths(clips_root: Optional[str] = None) -> list[Path]:
    root = _validated_local_root(
        _local_clips_root(clips_root), "clips", allow_missing=True
    )
    if not root.exists():
        return []
    paths = []
    for child in root.iterdir():
        try:
            child_stat = child.lstat()
            if stat.S_ISLNK(child_stat.st_mode) or not stat.S_ISDIR(child_stat.st_mode):
                continue
            _validate_local_id(child.name, "CLIP ID")
            paths.append(
                _validated_regular_file(
                    child / "clip.json",
                    label="CLIP manifest",
                    max_bytes=MAX_LOCAL_JSON_BYTES,
                )
            )
        except (
            FileNotFoundError,
            LocalSessionPathError,
            LocalSessionValidationError,
            OSError,
        ):
            continue
    return sorted(paths)


def _expect_object(value: Any, path: str) -> dict:
    if not isinstance(value, dict):
        raise LocalSessionValidationError(f"{path} must be an object.")
    return value


def _expect_list(value: Any, path: str) -> list:
    if not isinstance(value, list):
        raise LocalSessionValidationError(f"{path} must be an array.")
    return value


def _expect_string(value: Any, path: str) -> str:
    if not isinstance(value, str):
        raise LocalSessionValidationError(f"{path} must be a string.")
    return value


def _expect_number(value: Any, path: str) -> float | int:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
    ):
        raise LocalSessionValidationError(f"{path} must be a finite number.")
    return value


def _expect_integer(value: Any, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise LocalSessionValidationError(f"{path} must be an integer.")
    return value


def _expect_bool(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        raise LocalSessionValidationError(f"{path} must be a boolean.")
    return value


def _expect_enum(value: Any, values: set[str], path: str) -> str:
    value = _expect_string(value, path)
    if value not in values:
        raise LocalSessionValidationError(f"{path} has unsupported value: {value}")
    return value


def _expect_date(value: Any, path: str) -> str:
    value = _expect_string(value, path)
    if not SWIFT_ISO8601_PATTERN.fullmatch(value):
        raise LocalSessionValidationError(
            f"{path} must be an ISO-8601 date supported by Swift."
        )
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise LocalSessionValidationError(
            f"{path} must be a valid ISO-8601 date."
        ) from error
    return value


def _validate_json_value(value: Any, path: str = "value") -> None:
    if value is None or isinstance(value, (str, bool, int)):
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            raise LocalSessionValidationError(f"{path} contains a non-finite number.")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_json_value(item, f"{path}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise LocalSessionValidationError(
                    f"{path} has a non-string object key."
                )
            _validate_json_value(item, f"{path}.{key}")
        return
    raise LocalSessionValidationError(
        f"{path} contains a value that cannot be represented as JSON."
    )


def _json_values_equal(left: Any, right: Any) -> bool:
    return json.dumps(
        left, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ) == json.dumps(right, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _optional(value: dict, key: str, path: str) -> Any:
    return value.get(key) if key in value else None


def _decoded_array(value: dict, key: str, path: str) -> list:
    """Match Swift decodeIfPresent(... ) ?? [] for legacy null arrays."""
    raw = value.get(key)
    return [] if raw is None else _expect_list(raw, f"{path}.{key}")


def _validate_transcript_segment(segment: Any, path: str) -> None:
    segment = _expect_object(segment, path)
    _validate_local_id(segment.get("id"), f"{path}.id")
    _expect_string(segment.get("speaker"), f"{path}.speaker")
    _expect_string(segment.get("text"), f"{path}.text")
    _expect_date(segment.get("timestamp"), f"{path}.timestamp")
    if _optional(segment, "endTimestamp", path) is not None:
        _expect_date(segment["endTimestamp"], f"{path}.endTimestamp")
    if _optional(segment, "speakerID", path) is not None:
        _expect_string(segment["speakerID"], f"{path}.speakerID")
    if _optional(segment, "source", path) is not None:
        _expect_enum(segment["source"], SESSION_SOURCE_VALUES, f"{path}.source")
    if _optional(segment, "identityStatus", path) is not None:
        _expect_enum(
            segment["identityStatus"], SESSION_IDENTITY_VALUES, f"{path}.identityStatus"
        )
    if _optional(segment, "uncertainty", path) is not None:
        for index, item in enumerate(
            _expect_list(segment["uncertainty"], f"{path}.uncertainty")
        ):
            _expect_string(item, f"{path}.uncertainty[{index}]")


def _validate_recap_section(section: Any, path: str) -> None:
    section = _expect_object(section, path)
    _validate_local_id(section.get("id"), f"{path}.id")
    # Swift's custom decoder maps unknown recap kinds to `.notes`; preserve any
    # string here so MCP can round-trip that forward-compatible behavior.
    _expect_string(section.get("kind"), f"{path}.kind")
    _expect_string(section.get("title"), f"{path}.title")
    _expect_string(section.get("summary"), f"{path}.summary")
    for index, bullet in enumerate(
        _expect_list(section.get("bullets"), f"{path}.bullets")
    ):
        _expect_string(bullet, f"{path}.bullets[{index}]")
    for key in ("anchorTimestamp",):
        if _optional(section, key, path) is not None:
            _expect_date(section[key], f"{path}.{key}")
    for key in ("startOffset", "endOffset"):
        if _optional(section, key, path) is not None:
            _expect_number(section[key], f"{path}.{key}")


def _validate_recap(recap: Any, path: str) -> None:
    recap = _expect_object(recap, path)
    _expect_string(recap.get("overview"), f"{path}.overview")
    if _optional(recap, "generatedAt", path) is not None:
        _expect_date(recap["generatedAt"], f"{path}.generatedAt")
    for index, section in enumerate(
        _expect_list(recap.get("sections"), f"{path}.sections")
    ):
        _validate_recap_section(section, f"{path}.sections[{index}]")


def _validate_attachment(attachment: Any, path: str) -> None:
    attachment = _expect_object(attachment, path)
    _validate_local_id(attachment.get("id"), f"{path}.id")
    _expect_enum(attachment.get("kind"), SESSION_ATTACHMENT_KIND_VALUES, f"{path}.kind")
    _expect_enum(
        attachment.get("source"), SESSION_ATTACHMENT_SOURCE_VALUES, f"{path}.source"
    )
    _expect_string(attachment.get("title"), f"{path}.title")
    _expect_date(attachment.get("timestamp"), f"{path}.timestamp")
    if _optional(attachment, "sessionOffset", path) is not None:
        _expect_number(attachment["sessionOffset"], f"{path}.sessionOffset")
    for key in ("fileName", "mimeType", "urlString", "note"):
        if _optional(attachment, key, path) is not None:
            _expect_string(attachment[key], f"{path}.{key}")
    if _optional(attachment, "transcriptSegmentID", path) is not None:
        _validate_local_id(
            attachment["transcriptSegmentID"], f"{path}.transcriptSegmentID"
        )


def _validate_capture_artifact(artifact: Any, path: str) -> None:
    artifact = _expect_object(artifact, path)
    _validate_local_id(artifact.get("id"), f"{path}.id")
    _expect_enum(artifact.get("kind"), SESSION_CAPTURE_KIND_VALUES, f"{path}.kind")
    _expect_string(artifact.get("title"), f"{path}.title")
    _expect_date(artifact.get("capturedAt"), f"{path}.capturedAt")
    if _optional(artifact, "sessionOffset", path) is not None:
        _expect_number(artifact["sessionOffset"], f"{path}.sessionOffset")
    for index, identifier in enumerate(
        _expect_list(artifact.get("attachmentIDs"), f"{path}.attachmentIDs")
    ):
        _validate_local_id(identifier, f"{path}.attachmentIDs[{index}]")
    if _optional(artifact, "notes", path) is not None:
        _expect_string(artifact["notes"], f"{path}.notes")
    if _optional(artifact, "transcriptSegmentID", path) is not None:
        _validate_local_id(
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
        if _optional(audio, key, path) is not None:
            _expect_string(audio[key], f"{path}.{key}")
    if _optional(audio, "importedFileName", path) is not None:
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
    if _optional(evidence, "parentContentHash", path) is not None:
        _expect_string(evidence["parentContentHash"], f"{path}.parentContentHash")
    _expect_string(evidence.get("runFileName"), f"{path}.runFileName")
    _expect_string(evidence.get("outboxFileName"), f"{path}.outboxFileName")
    for index, issue in enumerate(
        _expect_list(evidence.get("issues"), f"{path}.issues")
    ):
        _expect_string(issue, f"{path}.issues[{index}]")
    if _optional(evidence, "isComplete", path) is not None:
        _expect_bool(evidence["isComplete"], f"{path}.isComplete")
    if _optional(evidence, "speechCoverage", path) is not None:
        coverage = _expect_number(evidence["speechCoverage"], f"{path}.speechCoverage")
        if not 0 <= coverage <= 1:
            raise LocalSessionValidationError(
                f"{path}.speechCoverage must be between 0 and 1."
            )
    if _optional(evidence, "hasVerifiableTimestamps", path) is not None:
        _expect_bool(
            evidence["hasVerifiableTimestamps"],
            f"{path}.hasVerifiableTimestamps",
        )


def _validate_source_citation(citation: Any, path: str) -> None:
    citation = _expect_object(citation, path)
    _validate_local_id(citation.get("id"), f"{path}.id")
    if _optional(citation, "segmentID", path) is not None:
        _validate_local_id(citation["segmentID"], f"{path}.segmentID")
    _expect_string(citation.get("title"), f"{path}.title")
    _expect_string(citation.get("excerpt"), f"{path}.excerpt")


def _validate_recap_patch(patch: Any, path: str) -> None:
    patch = _expect_object(patch, path)
    if _optional(patch, "overview", path) is not None:
        _expect_string(patch["overview"], f"{path}.overview")
    for index, section in enumerate(
        _expect_list(patch.get("sections"), f"{path}.sections")
    ):
        section = _expect_object(section, f"{path}.sections[{index}]")
        _expect_string(section.get("kind"), f"{path}.sections[{index}].kind")
        _expect_string(section.get("title"), f"{path}.sections[{index}].title")
        _expect_string(section.get("summary"), f"{path}.sections[{index}].summary")
        for bullet_index, bullet in enumerate(
            _expect_list(section.get("bullets"), f"{path}.sections[{index}].bullets")
        ):
            _expect_string(bullet, f"{path}.sections[{index}].bullets[{bullet_index}]")


def _validate_edit_proposal(proposal: Any, path: str) -> None:
    proposal = _expect_object(proposal, path)
    _expect_string(proposal.get("assistantMessage"), f"{path}.assistantMessage")
    if _optional(proposal, "operation", path) is not None:
        _expect_enum(
            proposal["operation"],
            SESSION_DOCUMENT_OPERATION_VALUES,
            f"{path}.operation",
        )
    for key in ("sessionTitle", "documentMarkdown"):
        if _optional(proposal, key, path) is not None:
            _expect_string(proposal[key], f"{path}.{key}")
    if _optional(proposal, "recapPatch", path) is not None:
        _validate_recap_patch(proposal["recapPatch"], f"{path}.recapPatch")
    for index, patch in enumerate(_decoded_array(proposal, "transcriptPatches", path)):
        patch = _expect_object(patch, f"{path}.transcriptPatches[{index}]")
        _validate_local_id(
            patch.get("segmentID"), f"{path}.transcriptPatches[{index}].segmentID"
        )
        _expect_string(patch.get("text"), f"{path}.transcriptPatches[{index}].text")
    for index, rename in enumerate(_decoded_array(proposal, "speakerRenames", path)):
        rename = _expect_object(rename, f"{path}.speakerRenames[{index}]")
        _expect_string(rename.get("oldName"), f"{path}.speakerRenames[{index}].oldName")
        _expect_string(rename.get("newName"), f"{path}.speakerRenames[{index}].newName")
    for array_name in ("warnings",):
        for index, item in enumerate(_decoded_array(proposal, array_name, path)):
            _expect_string(item, f"{path}.{array_name}[{index}]")
    for index, citation in enumerate(_decoded_array(proposal, "sourceCitations", path)):
        _validate_source_citation(citation, f"{path}.sourceCitations[{index}]")


def _validate_document_chat(chat: Any, path: str) -> None:
    chat = _expect_object(chat, path)
    for index, message in enumerate(
        _expect_list(chat.get("messages"), f"{path}.messages")
    ):
        message = _expect_object(message, f"{path}.messages[{index}]")
        _validate_local_id(message.get("id"), f"{path}.messages[{index}].id")
        _expect_enum(
            message.get("role"),
            SESSION_CHAT_ROLE_VALUES,
            f"{path}.messages[{index}].role",
        )
        _expect_string(message.get("text"), f"{path}.messages[{index}].text")
        _expect_date(message.get("createdAt"), f"{path}.messages[{index}].createdAt")
        for citation_index, citation in enumerate(
            _decoded_array(message, "sourceCitations", f"{path}.messages[{index}]")
        ):
            _validate_source_citation(
                citation, f"{path}.messages[{index}].sourceCitations[{citation_index}]"
            )
    if _optional(chat, "pendingProposal", path) is not None:
        _validate_edit_proposal(chat["pendingProposal"], f"{path}.pendingProposal")
    if _optional(chat, "undoSnapshot", path) is not None:
        snapshot = _expect_object(chat["undoSnapshot"], f"{path}.undoSnapshot")
        _expect_string(snapshot.get("title"), f"{path}.undoSnapshot.title")
        if _optional(snapshot, "documentMarkdown", f"{path}.undoSnapshot") is not None:
            _expect_string(
                snapshot["documentMarkdown"], f"{path}.undoSnapshot.documentMarkdown"
            )
        _validate_recap(snapshot.get("recap"), f"{path}.undoSnapshot.recap")
        for index, segment in enumerate(
            _expect_list(
                snapshot.get("transcriptSegments"),
                f"{path}.undoSnapshot.transcriptSegments",
            )
        ):
            _validate_transcript_segment(
                segment, f"{path}.undoSnapshot.transcriptSegments[{index}]"
            )
        _expect_date(snapshot.get("createdAt"), f"{path}.undoSnapshot.createdAt")
    _expect_enum(chat.get("status"), SESSION_CHAT_STATUS_VALUES, f"{path}.status")
    if _optional(chat, "errorMessage", path) is not None:
        _expect_string(chat["errorMessage"], f"{path}.errorMessage")
    for key in ("createdAt", "updatedAt"):
        if _optional(chat, key, path) is not None:
            _expect_date(chat[key], f"{path}.{key}")


def _validate_local_session(session: Any, session_id: Optional[str] = None) -> dict:
    session = _expect_object(session, "session")
    _validate_json_value(session, "session")
    identifier = _validate_local_id(session.get("id"), "session.id")
    if session_id is not None:
        requested_id = _validate_local_id(session_id, "session ID")
        if identifier.casefold() != requested_id.casefold():
            raise LocalSessionValidationError("session.id must match its directory ID.")
    _expect_string(session.get("title"), "session.title")
    if session.get("titleOrigin") is not None:
        _expect_enum(
            session.get("titleOrigin"),
            SESSION_TITLE_ORIGIN_VALUES,
            "session.titleOrigin",
        )
    if session.get("processingError") is not None:
        _expect_string(session.get("processingError"), "session.processingError")
    _expect_date(session.get("startedAt"), "session.startedAt")
    _expect_enum(session.get("status"), SESSION_STATUS_VALUES, "session.status")
    if "transcriptSegments" in session and session["transcriptSegments"] is not None:
        for index, segment in enumerate(
            _expect_list(session["transcriptSegments"], "session.transcriptSegments")
        ):
            _validate_transcript_segment(
                segment, f"session.transcriptSegments[{index}]"
            )
    if "segments" in session and session["segments"] is not None:
        for index, segment in enumerate(
            _expect_list(session["segments"], "session.segments")
        ):
            _validate_transcript_segment(segment, f"session.segments[{index}]")
    if session.get("recap") is not None:
        _validate_recap(session.get("recap"), "session.recap")
    if session.get("attachments") is not None:
        for index, attachment in enumerate(
            _expect_list(session.get("attachments"), "session.attachments")
        ):
            _validate_attachment(attachment, f"session.attachments[{index}]")
    if session.get("captureArtifacts") is not None:
        for index, artifact in enumerate(
            _expect_list(session.get("captureArtifacts"), "session.captureArtifacts")
        ):
            _validate_capture_artifact(artifact, f"session.captureArtifacts[{index}]")
    if session.get("audioArtifacts") is not None:
        _validate_audio_artifacts(
            session.get("audioArtifacts"), "session.audioArtifacts"
        )
    if session.get("contentClassification") is not None:
        _validate_content_classification(
            session.get("contentClassification"), "session.contentClassification"
        )
    if session.get("transcriptionEvidence") is not None:
        _validate_transcription_evidence(
            session.get("transcriptionEvidence"), "session.transcriptionEvidence"
        )
    if session.get("latestTranscriptionAttempt") is not None:
        _validate_transcription_evidence(
            session.get("latestTranscriptionAttempt"),
            "session.latestTranscriptionAttempt",
        )
    if session.get("documentMarkdown") is not None:
        _expect_string(session.get("documentMarkdown"), "session.documentMarkdown")
    if session.get("documentChat") is not None:
        _validate_document_chat(session.get("documentChat"), "session.documentChat")
    return session


def _safe_bundle_filename(value: Any, path: str) -> str:
    value = _expect_string(value, path)
    if not value or value in {".", ".."} or "\x00" in value:
        raise LocalSessionValidationError(f"{path} must be a safe file name.")
    if (
        Path(value).name != value
        or "/" in value
        or "\\" in value
        or Path(value).is_absolute()
    ):
        raise LocalSessionValidationError(f"{path} must be a safe file name.")
    return value


def _validate_clip(clip: Any, clip_id: Optional[str] = None) -> dict:
    clip = _expect_object(clip, "CLIP")
    _validate_json_value(clip, "CLIP")
    identifier = _validate_local_id(clip.get("id"), "CLIP.id")
    if (
        clip_id is not None
        and identifier.casefold() != _validate_local_id(clip_id, "CLIP ID").casefold()
    ):
        raise LocalSessionValidationError("CLIP.id must match its directory ID.")
    _expect_string(clip.get("title"), "CLIP.title")
    _expect_date(clip.get("startedAt"), "CLIP.startedAt")
    if clip.get("endedAt") is not None:
        _expect_date(clip.get("endedAt"), "CLIP.endedAt")
    _expect_enum(
        clip.get("status"),
        {"recording", "processing", "ready", "failed"},
        "CLIP.status",
    )
    if clip.get("intent") is not None:
        _expect_string(clip.get("intent"), "CLIP.intent")
    for key in ("videoFileName", "transcriptFileName", "notesFileName"):
        _safe_bundle_filename(clip.get(key), f"CLIP.{key}")
    if clip.get("audioFileName") is not None:
        _safe_bundle_filename(clip.get("audioFileName"), "CLIP.audioFileName")
    for index, segment in enumerate(
        _expect_list(clip.get("transcriptSegments"), "CLIP.transcriptSegments")
    ):
        segment = _expect_object(segment, f"CLIP.transcriptSegments[{index}]")
        _validate_local_id(segment.get("id"), f"CLIP.transcriptSegments[{index}].id")
        _expect_number(
            segment.get("startOffset"), f"CLIP.transcriptSegments[{index}].startOffset"
        )
        _expect_number(
            segment.get("endOffset"), f"CLIP.transcriptSegments[{index}].endOffset"
        )
        _expect_string(segment.get("text"), f"CLIP.transcriptSegments[{index}].text")
    _expect_string(clip.get("postNotes"), "CLIP.postNotes")
    if clip.get("errorMessage") is not None:
        _expect_string(clip.get("errorMessage"), "CLIP.errorMessage")
    return clip


def _clip_artifact_path(
    clip_directory: Path, value: Any, field: str, fallback: str
) -> Path:
    filename = _safe_bundle_filename(
        value if value is not None else fallback, f"CLIP.{field}"
    )
    path = clip_directory / filename
    try:
        path.lstat()
    except FileNotFoundError:
        return path
    return _validated_regular_file(path, label=f"CLIP.{field}")


def _read_clip_artifact_prefix(path: Path, limit: int = 64 * 1024) -> bytes:
    try:
        file_stat = path.lstat()
        if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_nlink != 1:
            return b""
        with path.open("rb") as file:
            return file.read(limit)
    except OSError:
        return b""


def _has_valid_wav_container(path: Path) -> bool:
    size = path.stat().st_size
    if size < 44:
        return False
    data = _read_clip_artifact_prefix(path)
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return False
    declared_size = int.from_bytes(data[4:8], "little") + 8
    if declared_size > size:
        return False

    offset = 12
    has_format = False
    has_audio = False
    while offset + 8 <= len(data) and offset + 8 <= declared_size:
        chunk_name = data[offset : offset + 4]
        chunk_size = int.from_bytes(data[offset + 4 : offset + 8], "little")
        chunk_end = offset + 8 + chunk_size
        if chunk_end > declared_size:
            return False
        if chunk_name == b"fmt " and chunk_size >= 16:
            has_format = True
        if chunk_name == b"data" and chunk_size > 0:
            has_audio = True
        offset = chunk_end + (chunk_size % 2)
    return has_format and has_audio


def _has_valid_mov_container(path: Path) -> bool:
    size = path.stat().st_size
    if size < 16:
        return False
    data = _read_clip_artifact_prefix(path, limit=32)
    if len(data) < 12 or data[4:8] != b"ftyp":
        return False
    atom_size = int.from_bytes(data[:4], "big")
    if atom_size == 1:
        if len(data) < 16:
            return False
        atom_size = int.from_bytes(data[8:16], "big")
    return atom_size >= 16 and atom_size <= size


def _valid_clip_transcript_artifact(path: Path, clip_id: str) -> bool:
    try:
        transcript = _read_local_session(path)
        if transcript.get("id") != clip_id:
            return False
        segments = transcript.get("segments")
        if not isinstance(segments, list):
            return False
        for index, segment in enumerate(segments):
            segment_path = f"CLIP.transcript.segments[{index}]"
            segment = _expect_object(segment, segment_path)
            _validate_local_id(segment.get("id"), f"{segment_path}.id")
            _expect_number(segment.get("startOffset"), f"{segment_path}.startOffset")
            _expect_number(segment.get("endOffset"), f"{segment_path}.endOffset")
            _expect_string(segment.get("text"), f"{segment_path}.text")
        _expect_string(transcript.get("text"), "CLIP.transcript.text")
        return True
    except (OSError, ValueError, json.JSONDecodeError):
        return False


def _clip_artifact_readiness(clip: dict, clip_directory: Path, clip_id: str) -> dict:
    issues = []
    artifacts = (
        (
            "video",
            _clip_artifact_path(
                clip_directory,
                clip.get("videoFileName"),
                "videoFileName",
                "clip-video.mov",
            ),
        ),
        (
            "audio",
            _clip_artifact_path(
                clip_directory,
                clip.get("audioFileName"),
                "audioFileName",
                "clip-audio.wav",
            ),
        ),
        (
            "transcript",
            _clip_artifact_path(
                clip_directory,
                clip.get("transcriptFileName"),
                "transcriptFileName",
                "transcript.json",
            ),
        ),
    )
    for kind, path in artifacts:
        try:
            _validated_regular_file(path, label=f"CLIP {kind}")
            if path.stat().st_size == 0:
                raise LocalSessionPathError(f"CLIP {kind} is empty: {path}")
            if kind == "video" and path.suffix.lower() == ".mov":
                if not _has_valid_mov_container(path):
                    raise LocalSessionValidationError(
                        "CLIP video container is incomplete"
                    )
            elif kind == "audio" and path.suffix.lower() == ".wav":
                if not _has_valid_wav_container(path):
                    raise LocalSessionValidationError(
                        "CLIP audio container is incomplete"
                    )
            elif kind == "transcript" and not _valid_clip_transcript_artifact(
                path, clip_id
            ):
                raise LocalSessionValidationError("CLIP transcript artifact is invalid")
        except (OSError, ValueError, json.JSONDecodeError):
            issues.append(f"{kind} artifact is missing or invalid")

    return {
        "ready": not issues,
        "issues": issues,
        "media_playability": "unverified",
    }


def _session_segments(session: dict) -> list[dict]:
    segments = session.get("transcriptSegments")
    if segments is None:
        segments = session.get("segments")
    return (
        [segment for segment in segments if isinstance(segment, dict)]
        if isinstance(segments, list)
        else []
    )


def _segment_line(segment: dict) -> str:
    if not isinstance(segment, dict):
        return ""
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
    artifact_readiness = _clip_artifact_readiness(
        clip, clip_json_path.parent, clip_json_path.parent.name
    )
    stored_status = clip.get("status")
    effective_status = (
        "failed"
        if stored_status == "ready" and not artifact_readiness["ready"]
        else stored_status
    )
    video_path = _clip_artifact_path(
        clip_json_path.parent,
        clip.get("videoFileName"),
        "videoFileName",
        "clip-video.mov",
    )
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
        "status": effective_status,
        "stored_status": stored_status,
        "artifact_readiness": artifact_readiness,
        "intent": clip.get("intent"),
        "transcript_segment_count": len(segments),
        "transcript_preview": preview[:500],
        "clip_directory": str(clip_json_path.parent),
        "video_path": str(video_path),
    }


def list_local_sessions(
    sessions_root: Optional[str] = None, limit: int = 20, offset: int = 0
) -> list[dict]:
    sessions = []
    for session_json_path in _local_session_paths(sessions_root):
        try:
            session = _read_local_session(session_json_path)
            _validate_local_session(session, session_json_path.parent.name)
        except (OSError, ValueError, json.JSONDecodeError):
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
            _validate_clip(clip, clip_json_path.parent.name)
            summary = _clip_summary(clip, clip_json_path)
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        clips.append(summary)

    clips.sort(key=lambda clip: clip.get("started_at") or "", reverse=True)
    return clips[max(0, offset) : max(0, offset) + max(0, limit)]


def _resolve_local_session_json(
    session_id: str, sessions_root: Optional[str] = None
) -> Path:
    root = _validated_local_root(
        _local_sessions_root(sessions_root), "sessions", allow_missing=False
    )
    return _validated_bundle_json(root, session_id, "session.json", "local session")


def _resolve_local_clip_json(clip_id: str, clips_root: Optional[str] = None) -> Path:
    root = _validated_local_root(
        _local_clips_root(clips_root), "clips", allow_missing=False
    )
    return _validated_bundle_json(root, clip_id, "clip.json", "local CLIP")


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
    _validate_local_session(session, session_id)
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
    _validate_local_session(session, session_id)
    return {
        "id": str(session.get("id") or session_json_path.parent.name),
        "session": session,
        "session_directory": str(session_json_path.parent),
        "session_json_path": str(session_json_path),
    }


def get_local_clip(clip_id: str, clips_root: Optional[str] = None) -> dict:
    clip_json_path = _resolve_local_clip_json(clip_id, clips_root)
    clip = _read_local_session(clip_json_path)
    _validate_clip(clip, clip_id)
    clip_directory = clip_json_path.parent
    artifact_readiness = _clip_artifact_readiness(clip, clip_directory, clip_id)
    stored_status = clip.get("status")
    effective_status = (
        "failed"
        if stored_status == "ready" and not artifact_readiness["ready"]
        else stored_status
    )
    effective_clip = dict(clip)
    effective_clip["status"] = effective_status
    return {
        "id": str(clip.get("id") or clip_json_path.parent.name),
        "clip": effective_clip,
        "status": effective_status,
        "stored_status": stored_status,
        "artifact_readiness": artifact_readiness,
        "transcript_segments": _clip_transcript_segments(clip),
        "post_notes": clip.get("postNotes") or "",
        "clip_directory": str(clip_directory),
        "clip_json_path": str(clip_json_path),
        "video_path": str(
            _clip_artifact_path(
                clip_directory,
                clip.get("videoFileName"),
                "videoFileName",
                "clip-video.mov",
            )
        ),
        "audio_path": str(
            _clip_artifact_path(
                clip_directory,
                clip.get("audioFileName"),
                "audioFileName",
                "clip-audio.wav",
            )
        ),
        "transcript_path": str(
            _clip_artifact_path(
                clip_directory,
                clip.get("transcriptFileName"),
                "transcriptFileName",
                "transcript.json",
            )
        ),
        "notes_path": str(
            _clip_artifact_path(
                clip_directory, clip.get("notesFileName"), "notesFileName", "notes.md"
            )
        ),
    }


def _file_inventory_entry(file_path: Path, session_directory: Path) -> dict:
    file_stat = file_path.lstat()
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        raise LocalSessionPathError(f"File inventory entry is unsafe: {file_path}")
    if file_stat.st_nlink != 1:
        raise LocalSessionPathError(
            f"File inventory entry must not be hard-linked: {file_path}"
        )
    try:
        resolved = file_path.resolve(strict=True)
        resolved.relative_to(session_directory.resolve(strict=True))
    except (OSError, ValueError) as error:
        raise LocalSessionPathError(
            f"File inventory entry is outside its bundle: {file_path}"
        ) from error
    return {
        "path": str(file_path),
        "relative_path": file_path.relative_to(session_directory).as_posix(),
        "size_bytes": file_stat.st_size,
        "extension": file_path.suffix,
    }


def list_local_session_files(
    session_id: str, sessions_root: Optional[str] = None
) -> dict:
    session_json_path = _resolve_local_session_json(session_id, sessions_root)
    session_directory = session_json_path.parent
    files = []
    for file_path in sorted(session_directory.rglob("*")):
        if file_path.name == "session.json":
            continue
        try:
            files.append(_file_inventory_entry(file_path, session_directory))
        except (OSError, LocalSessionPathError):
            continue
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
        try:
            files.append(_file_inventory_entry(file_path, clip_directory))
        except (OSError, LocalSessionPathError):
            continue
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
            _validate_local_session(session, session_json_path.parent.name)
        except (OSError, ValueError, json.JSONDecodeError):
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
    with _local_session_lock(session_json_path):
        session = _read_local_session(session_json_path)
        _validate_local_session(session, session_id)
        old_title = str(session.get("title") or "")
        candidate = dict(session)
        candidate["title"] = new_title
        candidate["titleOrigin"] = "user"
        _validate_local_session(candidate, session_id)
        summary = _session_summary(candidate, session_json_path)
        _invalidate_generated_session_packages(session_json_path)
        _write_local_session(session_json_path, candidate)
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

    _validate_json_value(fields, "fields")
    if "id" in fields:
        raise ValueError("Cannot update protected session field(s): id")

    protected_fields = {
        "status",
        "startedAt",
        "endedAt",
        "transcriptSegments",
        "segments",
        "captureArtifacts",
        "audioArtifacts",
        "transcriptionEvidence",
        "latestTranscriptionAttempt",
    }
    blocked = sorted(protected_fields.intersection(fields.keys()))

    session_json_path = _resolve_local_session_json(session_id, sessions_root)
    with _local_session_lock(session_json_path):
        session = _read_local_session(session_json_path)
        _validate_local_session(session, session_id)
        candidate = dict(session)
        for key, value in fields.items():
            candidate[key] = value
        _validate_local_session(candidate, session_id)
        changed_protected = [
            key
            for key in blocked
            if key not in session or not _json_values_equal(session[key], fields[key])
        ]
        if changed_protected:
            raise ValueError(
                "Cannot update protected session field(s): "
                + ", ".join(changed_protected)
            )
        summary = _session_summary(candidate, session_json_path)
        _invalidate_generated_session_packages(session_json_path)
        _write_local_session(session_json_path, candidate)
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
                description="Atomically merge user-editable top-level JSON fields into a local Cepessa session.json file. Title, recap, document notes, document chat, and future user metadata are supported; capture and transcription-owned fields are rejected when changed.",
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
