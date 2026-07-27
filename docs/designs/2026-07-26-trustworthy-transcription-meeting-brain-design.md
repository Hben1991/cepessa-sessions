# Trustworthy Transcription and Meeting Brain

## Outcome

Cepessa Sessions records meetings without destroying source evidence, produces a
truthful Hebrew-English transcript with stable speaker clusters, and exposes
source-cited meeting retrieval through MCP. Sessions remains useful offline.
When Cepessa is available, the same versioned meeting evidence is imported into
the canonical `WorkspaceBrain`.

The system prefers uncertainty and a stable `SPEAKER_n` label over a confident
but incorrect word or person name.

## Settled Product Requirements

- The meeting brain both answers questions and prepares bounded context for
  another agent.
- Transcription is local-first. Optional cloud retries are allowed only for
  explicitly flagged spans and must never prevent a complete local result.
- Final transcript quality is the first target; live transcription is a later
  projection.
- Speaker clusters must remain stable through a meeting. Actual names require
  evidence; unresolved identities remain stable anonymous speakers.
- `WorkspaceBrain` is canonical for cross-source knowledge. Sessions standalone
  mode is a rebuildable projection over meeting evidence, not a second mutable
  business brain.
- Existing recordings are immutable benchmark input. Evaluation must never
  call the app's in-place retranscription path.
- Brain retrieval is read-only first. Future mutations require typed operations,
  revision checks, exact-diff approval receipts, and audit records.

## Approach Registry

| ID | Mechanism | Status | Reason |
| --- | --- | --- | --- |
| A1 | Mixed-master ASR plus mic/system energy labels | Rejected | Destroys source separation, cannot diarize remote speakers, and can mark empty output ready. |
| A2 | Independent mic/system ASR with capture completeness gates | Active | Required reliability substrate; must preserve wall-clock gaps and mute semantics. |
| A3 | WhisperKit multilingual Turbo, benchmarked against smaller models | Active | Best current Hebrew-English local candidate. Model size alone is not a selection criterion. |
| A4 | Offline per-source diarization with stable anonymous clusters | Active | Required before any personal identity resolution. |
| A5 | Screen OCR, calendar, or roster as speaker identity | Rejected as authority | Retained only as candidate-name evidence. |
| A6 | Open-set voice identity with explicit enrollment | Blocked for promotion | Requires consent, domain calibration, spoof tests, and near-zero false-name evidence. |
| A7 | Generative replacement transcript | Rejected | Can silently change names, numbers, negation, ownership, or decisions. |
| A8 | Immutable raw ASR plus constrained revisions | Active | Auditable, reversible, and compatible with exact citations. |
| A9 | Independent mutable Sessions and WorkspaceBrain graphs | Rejected | Creates two authorities and irreconcilable graph-level conflicts. |
| A10 | Meeting evidence ledger plus standalone and canonical projections | Survives audit | Supports offline use without truth divergence. |
| A11 | Legacy knowledge graph and generic MCP field mutation | Rejected | Missing provenance/time/revisions and violates least privilege. |

## Architecture

### 1. Capture and transcription

`mic.wav`, `system.wav`, and `mixed.wav` remain immutable source artifacts.
Microphone and system tracks are transcribed independently. The mixed track is
an audit or explicit fallback artifact, never the default inference input.

Capture diagnostics record expected and actual duration, callback gaps, writer
errors, source silence, mute intervals, and teardown completion. A source that
is missing, stalled, malformed, untimed, materially truncated, or unexpectedly
silent cannot silently produce a ready session.

The first local model candidate is WhisperKit's compressed multilingual
Large-v3 model. Smaller models are promoted only if the frozen benchmark proves
near-non-inferiority across Hebrew, English, code-switching, omissions,
hallucinations, names, timestamps, latency, and memory.

### 2. Diarization and identity

Diarization runs independently on every source that can contain multiple
people. Each cluster receives a stable `sessionSpeakerID`; `SPEAKER_01` is only
its presentation label. Reprocessing matches new clusters to previous clusters
by turn overlap and embedding similarity and surfaces topology conflicts.

Identity evidence is revisioned and modality-specific:

1. user confirmation;
2. calibrated enrolled voice match with open-set rejection;
3. repeated time-aligned active-speaker visual observations;
4. meeting roster or calendar candidate;
5. contextual inference.

Weak or conflicting evidence keeps the anonymous label. Screen content never
binds a name by itself. Biometric enrollment is a separate explicit action and
is never implied by correcting a display label.

### 3. Evidence ledger

Every accepted transcript creates a full `MeetingEvidenceEnvelopeV1` snapshot:

- stable `cepessa-session://<session-id>/transcript` source reference;
- monotonic revision, parent hash, and content hash;
- immutable capture inventory and hashes;
- model, engine, parameters, language, warnings, and quality diagnostics;
- stable segments with raw ASR, active text, source channel, timings,
  speaker-cluster ID, identity state, confidence, and uncertainty;
- corrections and deterministic transcript-render offset map.

The current `session.json` remains a compatibility materialized view. New
revisions and Brain outbox envelopes are append-only and written atomically.
Transcript tombstones withdraw derived knowledge but do not delete audio.

### 4. Standalone and canonical Brain

Sessions builds a local, rebuildable meeting projection for text/entity/time
retrieval. It owns no independent cross-source business truth.

When Cepessa is available, it imports full evidence snapshots through a
`CepessaSessionsBrainSourceAdapter` and `SourceAnalysisPipeline`. Full meetings
are mixed-authorship evidence and therefore enter the untrusted/reviewed path.
Stable-source replacement withdraws obsolete meeting-derived consequences
before reingestion while preserving corroborating evidence from other sources.

Synchronization is full-snapshot and receipt-based:

1. Sessions atomically saves a revision and outbox envelope.
2. Cepessa validates schema, hashes, bounds, tenant, revision, and trust.
3. Cepessa ingests through `SourceAnalysisPipeline`.
4. A receipt is written only after retrieval, graph, open-loop, and episode
   postconditions pass.
5. Sessions marks the revision synchronized after observing that receipt.

### 5. MCP

Phase-one Brain tools are typed and read-only:

- `brain_status`
- `search_meeting_brain`
- `prepare_agent_context`
- `get_meeting_evidence`
- `resolve_participant`

Every result declares standalone/canonical mode, freshness, omissions,
conflicts, uncertainty, and exact session/segment/time citations. Absolute
paths, arbitrary roots, biometric templates, and unbounded raw session JSON are
not returned by Brain tools.

## Protected Corpus

Original recordings under
`~/Library/Application Support/Cepessa/Sessions` are never modified. A frozen
evaluation vault records relative path, size, modification time, and SHA-256.
Benchmark outputs live in a separate run directory. Source hashes are verified
before and after every run.

The evaluation layers are:

- all-session capture-integrity inventory;
- frozen human-gold Hebrew/English/code-switch clips split by whole session;
- silence and noise controls;
- full-corpus shadow processing without WER claims;
- fresh 30/60/120-minute dev-app hardware soaks.

## Acceptance Contract

- At least 25% relative WER improvement over current main.
- Overall WER at most 12%, Hebrew at most 13%, English spans at most 8%, and
  code-switch WER at most 15% on the locked set.
- Deletions at most 3%, insertions at most 2%, and named/technical term recall
  at least 95%.
- Zero output on clean-silence controls.
- Offline DER at most 10%, overlap-heavy DER at most 15%, and stable anonymous
  speaker assignment at least 98%.
- Named identity precision at least 99% with zero false confident names on the
  locked set; abstention counts as correct safety behavior.
- No incomplete, stalled, untimed, malformed, or unexpectedly silent source can
  become ready.
- Standalone and canonical answers cite the same immutable meeting evidence.
- Original source hashes remain unchanged.

Unit tests and short fixtures are regression evidence, not production proof.
Promotion additionally requires real dev-app calls, real installed models, MCP
client invocation, relaunch recovery, and 30/60/120-minute hardware soaks.

## Implementation Graph

1. Add evidence, capture-diagnostic, stable-speaker, and transcript-revision
   contracts with backward-compatible decoding.
2. Implement independent-source transcription, merge/deduplication, coverage
   gates, truthful readiness, and immutable outbox generation.
3. Add the protected-corpus validation and scoring harness.
4. Add standalone read-only meeting-Brain MCP tools and remove arbitrary Brain
   mutation/root traversal from the trusted surface.
5. Add the Cepessa Sessions source adapter and real headless Brain-store loading.
6. Add offline diarization behind a protocol and benchmark the eligible local
   model packages before selecting a runtime dependency.
7. Add participant-candidate observations, stable anonymous correction, and
   opt-in voice-profile contracts.
8. Run focused tests, protected-corpus shadow evaluation, dev UI/runtime proof,
   and a fresh adversarial audit.

## Protected Actions

This implementation does not install or stop production apps, delete or rewrite
recordings, commit, push, merge, open a PR, publish externally, enroll biometric
profiles, or upload audio to cloud providers.
