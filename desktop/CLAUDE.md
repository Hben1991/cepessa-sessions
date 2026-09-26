# Sessions desktop — agent notes

The repository-wide guide is the root `CLAUDE.md`. This file keeps the
desktop-specific contracts.

## Build

- `./run.sh` packages `build/Sessions Dev.app` (Debug, bundle
  `me.cepessa.sessions-dev`, data root `build/dev-data`); `--launch` opens it;
  `--test-root /abs/path` uses fixture data.
- `./run.sh --production` builds Release and installs `/Applications/Sessions.app`
  (bundle `me.cepessa.sessions`) — only with the owner's approval.
- There is no Xcode project; do not use `xcodebuild`. Pass a stable
  `--scratch-path` for your lane.
- Automate only the dev bundle (`agent-swift connect --bundle-id me.cepessa.sessions-dev`).

## Local Sessions reliability architecture

- `LocalCaptureLifecycle` owns a single generation-bound capture lease.
  Generation tokens protect a newer capture from late asynchronous cleanup.
- Finished-session evidence is published to `MeetingEvidenceOutbox/` and read
  by Cepessa through the `SessionsHandoff` library; the canonicalizer there is
  the single definition of the content hash (see `CEPESSA-INTEGRATION.md`).
- `CepessaMicrophoneCaptureHelper` is packaged under `Contents/Helpers`.
  `MicrophoneCaptureProcess` accepts capture only after the helper handshake and
  valid PCM, then uses a bounded drain and forced termination fallback on stop.
- `LocalSessionStore` serializes each session with a checked file lock, merges
  non-overlapping top-level edits from a loaded baseline, rejects overlapping
  edits as conflicts, and publishes metadata atomically. Recovery warnings do
  not imply that original files were deleted or repaired successfully.
- Imports are normalized to `imported.wav` and retain evidence kind `imported`.
  Mixed audio is a degraded fallback and is never sufficient for complete
  evidence. Ready status depends on verified transcript coverage and timing.
- Transcription attempts publish canonical, content-hashed immutable run and
  outbox records atomically. Recovery may reconstruct a missing outbox from its
  exact run; mismatched or corrupt evidence must not be silently overwritten.
- The Hebrew speech model and the speaker models install through their
  provisioners (pinned revision, size, SHA-256, manifest). Automatic install
  never runs against a fixture root.
- UI status follows the evidence disposition. Partial attempts show a warning,
  playback resolves the saved local source, search includes transcript and
  captured context, and attachments stay anchored to session timeline entries.

These are local source contracts. A green local build or test run is not proof
of an installed, signed, or production app.

## Changelog

After a user-visible change, append one line to `unreleased` in
`CHANGELOG.json` ("Fixed X", "Added Y"; no trailing period).
