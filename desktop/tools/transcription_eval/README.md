# Cepessa transcription evaluation

This directory contains a local-only, dependency-free harness for protected
transcription evaluation. It does not include private recordings or transcripts.

## Inventory without reading file content

```bash
python3 tools/transcription_eval/freeze_corpus.py inventory \
  --source "/path/to/source" \
  --output "/path/outside/source/corpus.json" \
  --mode metadata
```

Metadata mode uses filesystem metadata only. Hash mode additionally reads raw
bytes to calculate SHA-256; it does not decode audio or parse transcripts.

The command refuses:

- manifest output inside the source tree;
- a symbolic-link source root or any symbolic link inside it;
- hard-linked regular files;
- sockets, devices, FIFOs, or other special files;
- any resolved path outside the selected source root.

It never copies, locks, deletes, renames, or edits source files. A reviewed vault
copy is a separate operation.

## Validate a frozen inventory

```bash
python3 tools/transcription_eval/freeze_corpus.py validate \
  --manifest "/path/to/corpus.json" \
  --source "/path/to/source"
```

Hash manifests validate content plus metadata. Metadata manifests validate file
set, sizes, modification times, modes, and safe filesystem topology.

## Score JSONL

```bash
python3 tools/transcription_eval/report.py \
  --gold "/path/to/gold.jsonl" \
  --hypothesis "/path/to/hypothesis.jsonl" \
  --output "/tmp/transcription-quality.json" \
  --pretty
```

The aggregate report contains no transcript text or person names. It reports
WER, CER, deletion/insertion rates, critical-term recall/precision, diarization
components, turn-boundary metrics, and identity precision/recall/abstention.
Clip, split, track, speaker, and identity identifiers are not emitted raw.
Shareable clip/group identifiers use stable domain-separated SHA-256
pseudonyms, and private speaker-assignment mappings are omitted. These stable
pseudonyms are intentionally linkable across reports; this is pseudonymization,
not anonymization.

When both top-level `text` and segment text are supplied, their normalized
content must agree. Segment text is the canonical scoring source so text and
speaker metrics cannot silently evaluate different transcripts.

Report writes are atomic. The command refuses an output path that resolves to,
symlinks to, or hard-links to either the gold or hypothesis input.

Schemas describe the corpus manifest and JSONL record shapes. The Python code
performs semantic checks used by its tests; schema validation can be added by a
caller that already uses a JSON Schema validator.
