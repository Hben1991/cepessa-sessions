# Sessions ↔ Cepessa

Sessions records and transcribes on this Mac. Cepessa is where that knowledge
should end up. This is the contract between them today, and the path to
Sessions living inside Cepessa.

## What exists now

**`SessionsHandoff`** — a SwiftPM library product of `desktop/Desktop`
(Foundation and CryptoKit only, macOS 26):

```swift
// Package.swift in Cepessa
.package(path: "<path to>/desktop/Desktop")
// target dependency
.product(name: "SessionsHandoff", package: "CepessaSessions")
```

```swift
import SessionsHandoff

let snapshot = try SessionsOutboxReader().snapshot()
for evidence in snapshot.evidence where evidence.isUsable {
  // evidence.session.title / startedAt
  // evidence.segments: speaker, activeText, start/end seconds, language
  // evidence.quality.isComplete — false means "do not treat as the full record"
}
// snapshot.rejected lists every file that was skipped, and why.
```

Resolving the package also fetches Sessions' transcription dependencies
(WhisperKit); only `SessionsHandoff` is compiled into Cepessa.

**The outbox** — `~/Library/Application Support/Cepessa/MeetingEvidenceOutbox/`

- One immutable JSON envelope per transcription revision, schema
  `meeting-evidence/v1`. Sessions never rewrites or deletes one in place, so a
  reader needs no lock.
- Identity: `evidenceId` is stable per recording; `revision` increases with
  each transcription attempt; `contentHash` is SHA-256 over the canonical
  envelope (sorted keys, bounded micro-unit numbers, the hash field removed).
  Consumers should key on `evidenceId`, keep the highest verified revision, and
  treat an identical `contentHash` as already ingested.
- The canonicalizer lives in `SessionsHandoff` and Sessions' own writer calls
  it, so writer and reader cannot drift. A contract test
  (`testPublishedEvidenceIsReadAndVerifiedByTheHandoffLibrary`) writes evidence
  through the real transcription coordinator and reads it back through the
  library.
- The local MCP index (`mcp/src/mcp_server_omi/local_brain.py`) reads the same
  outbox with the same hashing rules.

## What Cepessa needs to add

1. A meeting source: `SourceSystem` has no meeting case today. Add one and a
   source adapter that reads `SessionsOutboxReader().snapshot()` on launch and
   on a file-system event for the outbox directory.
2. Access: if Cepessa runs sandboxed, the outbox under the shared Application
   Support folder is outside its container. Either share an App Group
   container between the two apps and move the outbox there (Sessions writes
   through `LocalSessionFileLayout.meetingEvidenceOutboxDirectory`, one place
   to change), or have the owner grant the folder once with a security-scoped
   bookmark.
3. Honesty: surface `quality.isComplete == false` and `run.disposition ==
   "degraded"` as "partial transcript", never as a clean record.

## Toward embedding

The redesign prepared, but did not do, the larger step:

- **Tokens are shared by name.** `SessionsPalette` mirrors
  `CepessaBrandPalette` (`nightSky*`, `sunriseGold`, `cloudCoral`, `nova*`),
  `SessionsType` uses the same faces as `CepessaV10Typography`, and the motion
  constants follow `FirstLightMotion`. Inside Cepessa the Sessions views can
  point these names at Cepessa's own tokens.
- **The deployment floor matches** (macOS 26).
- **Capture is lease-based.** `LocalCaptureLifecycle` owns one generation-bound
  lease for the microphone and system audio, so a host app can share the
  pipeline without racing it.

Next step when embedding starts: split `desktop/Desktop/Sources/Meetings`
(models, services, audio, the app model) into a `SessionsCore` library target
with an explicit public surface, leaving the capsule, window and menu-bar code
in the app target. Cepessa would then depend on `SessionsCore` and host the
capsule and reader itself.
