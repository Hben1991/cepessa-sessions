# Sessions Desktop

Local-first macOS session capture and transcription app built with SwiftUI.

## Structure

```
Desktop/          Swift/SwiftUI macOS app (SPM package)
scripts/          Local build safety checks
```

## Development

Requires macOS 14.0+ and Xcode command-line tools. The desktop package vendors
its pinned whisper.cpp source and uses a checked-in SwiftPM lockfile.

```bash
# Build and package desktop/build/Sessions Dev.app without launching it
./run.sh

# Build, package, and launch the isolated dev app
./run.sh --launch

# Build against an explicit synthetic or QA data root
./run.sh --launch --test-root /absolute/path/to/sessions-fixtures

# Verify the build script's production guards without building
./scripts/test-run-safety.sh
```

The default bundle is `Sessions Dev.app`, identifier
`me.cepessa.sessions-dev`, and URL scheme `cepessa-sessions-dev`. It always
uses an isolated data root; the default is `desktop/build/dev-data`.

The app's **Sessions** menu opens the library with `Command-O`, imports audio
with `Shift-Command-I`, and opens Clips with `Shift-Command-L`. The application
Settings command and floating controls share the same window (`Command-,`).

`./run.sh` does not start backend services, copy credentials, choose an external
endpoint, stop another app, or write to `/Applications`. `--install` explicitly
targets only `/Applications/Sessions Dev.app`. Use `--env-file` when a local
environment file is intentionally required.

SwiftPM uses `/private/tmp/codex-derived-data/cepessa-sessions-reliability` with
four jobs by default. Pass `--sign-identity` or set
`SESSIONS_DEV_SIGN_IDENTITY` to use a stable local identity; otherwise the app
uses an ad hoc signature without distribution entitlements. Stable identities
use `Desktop/Cepessa-Dev.entitlements`, which omits the provisioning-dependent
Sign in with Apple entitlement.

## Local sessions reliability contracts

- **Capture ownership:** Sessions and CLIPS acquire one shared, generation-bound
  capture lease before starting asynchronous work. A stale completion cannot
  release a newer capture. Microphone audio runs in the packaged
  `CepessaMicrophoneCaptureHelper`; startup requires its handshake and a valid
  PCM frame. Stop sends `STOP`, drains final frames for a bounded interval, and
  terminates a helper that does not exit.
- **Session writes:** Each session package has a checked per-session file lock.
  Saves merge non-overlapping top-level changes against their loaded baseline;
  overlapping edits fail with a conflict instead of reporting a false success.
  Metadata writes are atomic. Load and repair failures surface warnings while
  leaving the original session files in place.
- **Transcription evidence:** Imported media is normalized to `imported.wav`
  and recorded as source kind `imported`. A `mixed.wav` fallback is degraded
  evidence and cannot make a transcript complete. Ready status requires usable
  segments plus verified coverage and timing. Each attempt writes a canonical,
  content-hashed immutable run and outbox artifact through atomic publication.
  Retry can restore a missing outbox from the matching run; corrupt or changed
  evidence is preserved or rejected before fresh transcription.
- **Truthful review:** A degraded or failed attempt keeps its warning visible;
  when a prior ready transcript exists, it remains readable with the newer
  attempt recorded separately. The reader uses saved local audio for playback,
  and library search covers transcript and captured context. Attachments remain
  tied to their session and transcript timeline.

These are source and local test contracts. Packaging a dev app does not install
or validate a production build.

## License

MIT
