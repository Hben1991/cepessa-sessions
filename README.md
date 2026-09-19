# Cepessa Sessions

Cepessa Sessions is a local macOS app for recording sessions, importing audio,
reading transcripts, and capturing short screen clips. The active desktop app
transcribes after a recording stops or an audio file is imported. It retains
source audio, transcript timing, speaker annotations, attachments, and evidence
for each transcription attempt.

The reader distinguishes checked transcripts from incomplete attempts and older
transcripts without completeness evidence. A checked transcript is not a promise
of word-perfect recognition: review the audio when wording matters.

## Local development

Requires macOS 14 or later and Xcode. System audio capture requires macOS 14.4 or
later; capture also needs the relevant macOS permissions and an available audio
input. Local transcription and speaker separation need their model files.

```bash
git clone https://github.com/Hben1991/cepessa-sessions.git
cd cepessa-sessions/desktop
./run.sh
```

This builds and packages `Sessions Dev.app` with an isolated development data
root. Use `./run.sh --launch` to launch it. The script does not install the app,
start backend services, or change the production app. Installation with
`--install` targets only `Sessions Dev.app`.

See [desktop/README.md](desktop/README.md) for commands, data isolation, keyboard
shortcuts, and the capture, persistence, and transcription contracts.

## Source map

| Area | Purpose |
|---|---|
| [desktop](desktop/) | Active SwiftUI macOS app and local build runner |
| [mcp](mcp/) | Session access and evidence retrieval for MCP clients |
| [DESIGN.md](DESIGN.md) | Current desktop visual and interaction rules |
| [docs](docs/) | Product and developer documentation, including historical material |

The repository also retains mobile, backend, firmware, and SDK source from its
broader history. Their presence does not mean the current macOS app provides
mobile or wearable support, live transcription, generated recaps, or document
chat. Recap generation and document chat are inactive in the current desktop
implementation.

Build and test results describe the source and the specific app artifact tested.
They do not verify an installed production app or a capture device that was not
available during testing.

## License

MIT — see [LICENSE](LICENSE).
