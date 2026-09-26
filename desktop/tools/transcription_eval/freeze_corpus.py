#!/usr/bin/env python3
"""Create or validate a safe, read-only corpus inventory manifest.

Despite the name, this command deliberately does not copy, lock, or modify the
source corpus. Vault creation is a separate reviewed operation.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.transcription_eval.corpus import (  # noqa: E402
    CorpusSafetyError,
    build_manifest,
    load_manifest,
    validate_manifest,
    write_manifest,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory = subparsers.add_parser("inventory", help="Write a protected corpus manifest.")
    inventory.add_argument("--source", required=True, type=Path)
    inventory.add_argument("--output", required=True, type=Path)
    inventory.add_argument("--mode", choices=("metadata", "hash"), default="hash")
    inventory.add_argument("--seed", default="cepessa-transcription-eval-v1")

    validate = subparsers.add_parser("validate", help="Validate a corpus against an existing manifest.")
    validate.add_argument("--manifest", required=True, type=Path)
    validate.add_argument("--source", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "inventory":
            manifest = build_manifest(args.source, mode=args.mode, seed=args.seed)
            output = write_manifest(manifest, args.output)
            print(
                json.dumps(
                    {
                        "status": "created",
                        "output": str(output),
                        "inventory_mode": manifest["inventory_mode"],
                        "file_count": manifest["summary"]["file_count"],
                        "total_bytes": manifest["summary"]["total_bytes"],
                        "manifest_sha256": manifest["manifest_sha256"],
                    },
                    sort_keys=True,
                )
            )
            return 0

        manifest = load_manifest(args.manifest)
        result = validate_manifest(manifest, source_root=args.source)
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        return 0 if result["valid"] else 2
    except (CorpusSafetyError, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(json.dumps({"status": "error", "error": str(error)}, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
