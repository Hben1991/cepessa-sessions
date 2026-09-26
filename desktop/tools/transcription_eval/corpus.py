"""Safe inventory and validation for a private transcription corpus.

This module never copies or edits source files. It rejects filesystem shapes that
could make a supposedly read-only inventory escape the selected root or share
mutable file content with another path.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Any, Iterable

MANIFEST_VERSION = 1
DEFAULT_SPLITS = (
    ("development", 0.35),
    ("locked", 0.80),
    ("stress", 1.0),
)


class CorpusSafetyError(ValueError):
    """Raised when a corpus cannot be inventoried without unsafe filesystem behavior."""


def _resolved(path: Path, *, strict: bool) -> Path:
    try:
        return path.expanduser().resolve(strict=strict)
    except (OSError, RuntimeError) as error:
        raise CorpusSafetyError(f"Could not resolve path {path}: {error}") from error


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _validate_source_root(source_root: Path) -> Path:
    expanded = source_root.expanduser()
    try:
        source_lstat = expanded.lstat()
    except OSError as error:
        raise CorpusSafetyError(f"Source root is not readable: {expanded}") from error
    if stat.S_ISLNK(source_lstat.st_mode):
        raise CorpusSafetyError("Source root must not be a symbolic link.")

    resolved = _resolved(expanded, strict=True)
    if not resolved.is_dir():
        raise CorpusSafetyError("Source root must be a directory.")
    return resolved


def _validate_output_path(output_path: Path, source_root: Path) -> Path:
    expanded = output_path.expanduser()
    output_parent = _resolved(expanded.parent, strict=False)
    resolved_output = output_parent / expanded.name
    if _is_within(resolved_output, source_root):
        raise CorpusSafetyError("Manifest output must be outside the source root.")
    if resolved_output == source_root:
        raise CorpusSafetyError("Manifest output must not replace the source root.")
    return resolved_output


def _sha256_file(
    path: Path,
    expected_stat: os.stat_result,
    chunk_size: int = 1024 * 1024,
) -> str:
    digest = hashlib.sha256()
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as handle:
        opened_stat = os.fstat(handle.fileno())
        if not stat.S_ISREG(opened_stat.st_mode):
            raise CorpusSafetyError(f"File changed to a non-regular file while hashing: {path}")
        if opened_stat.st_nlink != 1:
            raise CorpusSafetyError(f"File became hard-linked while hashing: {path}")
        if (opened_stat.st_dev, opened_stat.st_ino) != (
            expected_stat.st_dev,
            expected_stat.st_ino,
        ):
            raise CorpusSafetyError(f"File changed while hashing: {path}")
        while chunk := handle.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def _relative_posix(path: Path, source_root: Path) -> str:
    try:
        relative = path.relative_to(source_root)
    except ValueError as error:
        raise CorpusSafetyError(f"Path escaped source root: {path}") from error
    if relative == Path(".") or ".." in relative.parts:
        raise CorpusSafetyError(f"Invalid relative corpus path: {relative}")
    return relative.as_posix()


def _walk_regular_files(source_root: Path) -> Iterable[tuple[Path, os.stat_result]]:
    pending = [source_root]
    while pending:
        directory = pending.pop()
        try:
            directory_stat = directory.lstat()
        except OSError as error:
            raise CorpusSafetyError(f"Could not inspect directory {directory}: {error}") from error
        if stat.S_ISLNK(directory_stat.st_mode) or not stat.S_ISDIR(directory_stat.st_mode):
            raise CorpusSafetyError(f"Directory changed while inventorying: {directory}")
        if not _is_within(_resolved(directory, strict=True), source_root):
            raise CorpusSafetyError(f"Directory escaped source root: {directory}")
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as error:
            raise CorpusSafetyError(f"Could not enumerate {directory}: {error}") from error

        child_directories: list[Path] = []
        for entry in entries:
            path = Path(entry.path)
            try:
                entry_stat = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise CorpusSafetyError(f"Could not inspect {path}: {error}") from error

            if stat.S_ISLNK(entry_stat.st_mode):
                raise CorpusSafetyError(f"Symbolic links are not allowed: {_relative_posix(path, source_root)}")
            if stat.S_ISDIR(entry_stat.st_mode):
                resolved_directory = _resolved(path, strict=True)
                if not _is_within(resolved_directory, source_root):
                    raise CorpusSafetyError(f"Directory escaped source root: {path}")
                child_directories.append(resolved_directory)
                continue
            if not stat.S_ISREG(entry_stat.st_mode):
                raise CorpusSafetyError(f"Only regular files and directories are allowed: {path}")
            if entry_stat.st_nlink != 1:
                raise CorpusSafetyError(
                    f"Hard-linked files are not allowed: {_relative_posix(path, source_root)} "
                    f"(link count {entry_stat.st_nlink})"
                )
            resolved_file = _resolved(path, strict=True)
            if not _is_within(resolved_file, source_root):
                raise CorpusSafetyError(f"File escaped source root: {path}")
            current_stat = resolved_file.lstat()
            if (
                stat.S_ISLNK(current_stat.st_mode)
                or not stat.S_ISREG(current_stat.st_mode)
                or current_stat.st_nlink != 1
                or (current_stat.st_dev, current_stat.st_ino)
                != (entry_stat.st_dev, entry_stat.st_ino)
            ):
                raise CorpusSafetyError(f"File changed while inventorying: {path}")
            yield resolved_file, current_stat

        pending.extend(reversed(child_directories))


def _track_role(path: str) -> str | None:
    basename = Path(path).name.lower()
    if basename == "mic.wav":
        return "microphone"
    if basename == "system.wav":
        return "system"
    if basename == "mixed.wav":
        return "mixed"
    if basename == "session.json":
        return "session_metadata"
    return None


def _selection_units(files: list[dict[str, Any]], seed: str) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for file_record in files:
        relative_path = Path(file_record["path"])
        unit_id = relative_path.parts[0] if len(relative_path.parts) > 1 else "_root"
        grouped.setdefault(unit_id, []).append(file_record)

    units: list[dict[str, Any]] = []
    for unit_id, unit_files in grouped.items():
        selector_hash = hashlib.sha256(f"{seed}\0{unit_id}".encode("utf-8")).hexdigest()
        selector_value = int(selector_hash[:16], 16) / float(0xFFFFFFFFFFFFFFFF)
        suggested_split = DEFAULT_SPLITS[-1][0]
        for split_name, upper_bound in DEFAULT_SPLITS:
            if selector_value < upper_bound:
                suggested_split = split_name
                break
        units.append(
            {
                "unit_id": unit_id,
                "selector_hash": selector_hash,
                "selector_value": round(selector_value, 12),
                "suggested_split": suggested_split,
                "file_count": len(unit_files),
                "total_bytes": sum(int(file_record["size_bytes"]) for file_record in unit_files),
            }
        )
    return sorted(units, key=lambda unit: (unit["selector_hash"], unit["unit_id"]))


def _manifest_content_hash(manifest: dict[str, Any]) -> str:
    hashable = {key: value for key, value in manifest.items() if key != "manifest_sha256"}
    encoded = json.dumps(hashable, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def build_manifest(
    source_root: Path | str,
    *,
    mode: str = "hash",
    seed: str = "cepessa-transcription-eval-v1",
) -> dict[str, Any]:
    """Build a deterministic metadata or metadata+hash manifest.

    Metadata mode never opens regular file content. Hash mode reads content only
    to calculate SHA-256 and does not parse audio, transcripts, or JSON.
    """

    if mode not in {"metadata", "hash"}:
        raise ValueError("mode must be 'metadata' or 'hash'")
    resolved_root = _validate_source_root(Path(source_root))

    files: list[dict[str, Any]] = []
    for path, path_stat in _walk_regular_files(resolved_root):
        relative_path = _relative_posix(path, resolved_root)
        record: dict[str, Any] = {
            "path": relative_path,
            "size_bytes": path_stat.st_size,
            "mtime_ns": path_stat.st_mtime_ns,
            "mode": stat.S_IMODE(path_stat.st_mode),
        }
        role = _track_role(relative_path)
        if role is not None:
            record["role"] = role
        if mode == "hash":
            record["sha256"] = _sha256_file(path, path_stat)
        files.append(record)

    files.sort(key=lambda record: record["path"])
    manifest: dict[str, Any] = {
        "manifest_version": MANIFEST_VERSION,
        "inventory_mode": mode,
        "source": {
            "root": str(resolved_root),
            "root_name": resolved_root.name,
        },
        "files": files,
        "summary": {
            "file_count": len(files),
            "total_bytes": sum(int(record["size_bytes"]) for record in files),
        },
        "selection": {
            "algorithm": "sha256-unit-v1",
            "seed": seed,
            "unit": "first_path_component",
            "split_thresholds": [
                {"name": split_name, "upper_bound": upper_bound}
                for split_name, upper_bound in DEFAULT_SPLITS
            ],
            "units": _selection_units(files, seed),
        },
    }
    manifest["manifest_sha256"] = _manifest_content_hash(manifest)
    return manifest


def write_manifest(manifest: dict[str, Any], output_path: Path | str) -> Path:
    source_root = _validate_source_root(Path(manifest["source"]["root"]))
    resolved_output = _validate_output_path(Path(output_path), source_root)
    resolved_output.parent.mkdir(parents=True, exist_ok=True)
    verified_parent = _resolved(resolved_output.parent, strict=True)
    verified_output = verified_parent / resolved_output.name
    if _is_within(verified_output, source_root):
        raise CorpusSafetyError("Manifest output must be outside the source root.")
    resolved_output = verified_output

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{resolved_output.name}.",
        suffix=".tmp",
        dir=resolved_output.parent,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, resolved_output)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise
    return resolved_output


def load_manifest(manifest_path: Path | str) -> dict[str, Any]:
    with Path(manifest_path).expanduser().open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("manifest_version") != MANIFEST_VERSION:
        raise ValueError(f"Unsupported manifest version: {manifest.get('manifest_version')}")
    expected_hash = manifest.get("manifest_sha256")
    actual_hash = _manifest_content_hash(manifest)
    if expected_hash != actual_hash:
        raise ValueError("Manifest content hash does not match its contents.")
    return manifest


def validate_manifest(
    manifest: dict[str, Any],
    *,
    source_root: Path | str | None = None,
) -> dict[str, Any]:
    """Validate file set, safe topology, metadata, and hashes when present."""

    selected_root = Path(source_root) if source_root is not None else Path(manifest["source"]["root"])
    current = build_manifest(
        selected_root,
        mode=manifest["inventory_mode"],
        seed=manifest["selection"]["seed"],
    )
    expected_files = {record["path"]: record for record in manifest["files"]}
    actual_files = {record["path"]: record for record in current["files"]}

    missing = sorted(set(expected_files) - set(actual_files))
    unexpected = sorted(set(actual_files) - set(expected_files))
    changed: list[dict[str, Any]] = []
    compared_fields = ["size_bytes", "mtime_ns", "mode"]
    if manifest["inventory_mode"] == "hash":
        compared_fields.append("sha256")

    for path in sorted(set(expected_files) & set(actual_files)):
        differences = {
            field: {"expected": expected_files[path].get(field), "actual": actual_files[path].get(field)}
            for field in compared_fields
            if expected_files[path].get(field) != actual_files[path].get(field)
        }
        if differences:
            changed.append({"path": path, "differences": differences})

    return {
        "valid": not missing and not unexpected and not changed,
        "inventory_mode": manifest["inventory_mode"],
        "source_root": str(_validate_source_root(selected_root)),
        "missing": missing,
        "unexpected": unexpected,
        "changed": changed,
        "expected_manifest_sha256": manifest["manifest_sha256"],
        "actual_manifest_sha256": current["manifest_sha256"],
    }
