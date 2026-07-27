from __future__ import annotations

import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

from tools.transcription_eval.corpus import (
    CorpusSafetyError,
    build_manifest,
    load_manifest,
    validate_manifest,
    write_manifest,
)
from tools.transcription_eval.freeze_corpus import main


class CorpusManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.source = self.root / "source"
        self.output = self.root / "manifests" / "corpus.json"
        session = self.source / "SESSION-A"
        session.mkdir(parents=True)
        (session / "mic.wav").write_bytes(b"RIFF-synthetic-mic")
        (session / "system.wav").write_bytes(b"RIFF-synthetic-system")
        (session / "session.json").write_text('{"synthetic":true}\n', encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_metadata_mode_does_not_open_source_file_content(self) -> None:
        original_open = Path.open

        def guarded_open(path: Path, *args: object, **kwargs: object):
            if path.is_relative_to(self.source):
                raise AssertionError(f"metadata mode opened source content: {path}")
            return original_open(path, *args, **kwargs)

        with mock.patch("pathlib.Path.open", autospec=True, side_effect=guarded_open):
            manifest = build_manifest(self.source, mode="metadata")

        self.assertEqual(manifest["inventory_mode"], "metadata")
        self.assertTrue(all("sha256" not in record for record in manifest["files"]))
        self.assertEqual(manifest["summary"]["file_count"], 3)

    def test_hash_mode_is_deterministic_and_records_roles(self) -> None:
        first = build_manifest(self.source, mode="hash", seed="fixed")
        second = build_manifest(self.source, mode="hash", seed="fixed")

        self.assertEqual(first, second)
        self.assertEqual(len(first["manifest_sha256"]), 64)
        roles = {record["path"]: record.get("role") for record in first["files"]}
        self.assertEqual(roles["SESSION-A/mic.wav"], "microphone")
        self.assertEqual(roles["SESSION-A/system.wav"], "system")
        self.assertEqual(roles["SESSION-A/session.json"], "session_metadata")
        self.assertEqual(first["selection"]["units"][0]["unit_id"], "SESSION-A")

    def test_manifest_output_inside_source_is_rejected_without_creating_file(self) -> None:
        manifest = build_manifest(self.source, mode="metadata")
        forbidden_output = self.source / "corpus.json"

        with self.assertRaisesRegex(CorpusSafetyError, "outside the source root"):
            write_manifest(manifest, forbidden_output)

        self.assertFalse(forbidden_output.exists())

    def test_manifest_output_through_symlinked_parent_into_source_is_rejected(self) -> None:
        alias = self.root / "source-alias"
        alias.symlink_to(self.source, target_is_directory=True)
        manifest = build_manifest(self.source, mode="metadata")

        with self.assertRaisesRegex(CorpusSafetyError, "outside the source root"):
            write_manifest(manifest, alias / "corpus.json")

        self.assertFalse((self.source / "corpus.json").exists())

    def test_symbolic_link_inside_source_is_rejected(self) -> None:
        outside = self.root / "outside.wav"
        outside.write_bytes(b"private")
        (self.source / "SESSION-A" / "escape.wav").symlink_to(outside)

        with self.assertRaisesRegex(CorpusSafetyError, "Symbolic links are not allowed"):
            build_manifest(self.source, mode="metadata")

    def test_symbolic_link_source_root_is_rejected(self) -> None:
        alias = self.root / "source-alias"
        alias.symlink_to(self.source, target_is_directory=True)

        with self.assertRaisesRegex(CorpusSafetyError, "Source root must not be a symbolic link"):
            build_manifest(alias, mode="metadata")

    def test_hard_link_inside_source_is_rejected(self) -> None:
        target = self.source / "SESSION-A" / "mic.wav"
        os.link(target, self.source / "SESSION-A" / "mic-copy.wav")

        with self.assertRaisesRegex(CorpusSafetyError, "Hard-linked files are not allowed"):
            build_manifest(self.source, mode="metadata")

    def test_special_file_is_rejected(self) -> None:
        fifo = self.source / "SESSION-A" / "audio.pipe"
        os.mkfifo(fifo)

        with self.assertRaisesRegex(CorpusSafetyError, "Only regular files and directories"):
            build_manifest(self.source, mode="metadata")

    def test_hash_manifest_validation_detects_content_change(self) -> None:
        manifest = build_manifest(self.source, mode="hash")
        target = self.source / "SESSION-A" / "mic.wav"
        target.write_bytes(b"RIFF-synthetic-mic-changed")

        result = validate_manifest(manifest)

        self.assertFalse(result["valid"])
        self.assertEqual(result["changed"][0]["path"], "SESSION-A/mic.wav")
        self.assertIn("sha256", result["changed"][0]["differences"])

    def test_validation_detects_added_and_missing_files(self) -> None:
        manifest = build_manifest(self.source, mode="metadata")
        (self.source / "SESSION-A" / "mic.wav").unlink()
        (self.source / "SESSION-A" / "mixed.wav").write_bytes(b"RIFF-mixed")

        result = validate_manifest(manifest)

        self.assertEqual(result["missing"], ["SESSION-A/mic.wav"])
        self.assertEqual(result["unexpected"], ["SESSION-A/mixed.wav"])

    def test_written_manifest_round_trips_and_tampering_is_rejected(self) -> None:
        manifest = build_manifest(self.source, mode="hash")
        written = write_manifest(manifest, self.output)
        self.assertEqual(load_manifest(written), manifest)

        tampered = json.loads(written.read_text(encoding="utf-8"))
        tampered["summary"]["file_count"] = 999
        written.write_text(json.dumps(tampered), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "content hash"):
            load_manifest(written)

    def test_inventory_and_validate_cli_round_trip_metadata_mode(self) -> None:
        output = StringIO()
        with redirect_stdout(output):
            inventory_exit = main(
                [
                    "inventory",
                    "--source",
                    str(self.source),
                    "--output",
                    str(self.output),
                    "--mode",
                    "metadata",
                    "--seed",
                    "test-seed",
                ]
            )
            validate_exit = main(
                [
                    "validate",
                    "--manifest",
                    str(self.output),
                    "--source",
                    str(self.source),
                ]
            )

        self.assertEqual(inventory_exit, 0)
        self.assertEqual(validate_exit, 0)
        self.assertIn('"status": "created"', output.getvalue())
        self.assertIn('"valid": true', output.getvalue())
        self.assertEqual(load_manifest(self.output)["inventory_mode"], "metadata")


if __name__ == "__main__":
    unittest.main()
