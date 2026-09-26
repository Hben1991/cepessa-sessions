# Cepessa Sessions

Cepessa's recorder: a local-first macOS app that records microphone and system
audio, lets you pin screenshots and files to moments of a session, and
transcribes on this Mac when the recording stops. Transcripts are readable,
searchable, and honest about what could not be verified — review the audio when
wording matters.

Finished sessions are published as hash-verified evidence that Cepessa reads
through the `SessionsHandoff` library, and a read-only MCP server exposes the
transcripts to agents.

## Build

Requires macOS 26 and Xcode command-line tools.

```bash
git clone https://github.com/Hben1991/cepessa-sessions.git
cd cepessa-sessions/desktop
./run.sh            # Debug build of Sessions Dev.app with an isolated data root
./run.sh --launch   # build and launch it
```

`./run.sh --production` builds Release and installs `/Applications/Sessions.app`.
See [desktop/README.md](desktop/README.md) for commands, data isolation, tests,
and the capture, persistence and transcription contracts.

## Source map

| Area | Purpose |
|---|---|
| [desktop/Desktop](desktop/Desktop/) | The SwiftUI app, the `SessionsHandoff` library, tests |
| [desktop/run.sh](desktop/run.sh) | Build, package, sign and install |
| [desktop/tools/transcription_eval](desktop/tools/transcription_eval/) | Transcription quality evaluation |
| [mcp](mcp/) | Read-only MCP server for session transcripts |
| [DESIGN.md](DESIGN.md), [PRODUCT.md](PRODUCT.md) | Design system and product principles |
| [desktop/CEPESSA-INTEGRATION.md](desktop/CEPESSA-INTEGRATION.md) | The handoff to Cepessa |

Build and test results describe the source and the artifact tested. They do not
verify an installed app or a capture device that was not available during
testing.

## License

MIT — see [LICENSE](LICENSE).
