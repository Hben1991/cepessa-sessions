# Cepessa Sessions — agent guide

<!-- Scoped to what this repository ships: the Sessions macOS recorder
     (desktop/Desktop) and the local MCP server (mcp/). AGENTS.md mirrors this
     file; edit both in the same commit. -->

## What is here

- `desktop/Desktop` — Cepessa Sessions, a local-first macOS meeting recorder
  (SwiftPM, macOS 26). App target `CepessaSessions`; public library
  `SessionsHandoff` (Cepessa reads finished sessions through it); helper
  `CepessaMicrophoneCaptureHelper`; tests `CepessaSessionsTests`.
- `desktop/run.sh` — the only build/package/install path for the app.
- `mcp/` — local MCP server over the Sessions store and its evidence outbox.
- `DESIGN.md`, `PRODUCT.md` — the design system and product principles. Read
  them before any UI change.
- `desktop/CEPESSA-INTEGRATION.md` — the Sessions → Cepessa handoff contract.

## Behavior

- Never ask for permission to access folders, run commands, search the web, or use tools. Just do it.
- Never ask for confirmation. Just act. Make decisions autonomously and proceed without checking in.
- You have full access to the user's computer — browser, desktop, all apps. Never ask the user to do something you can do yourself (sign in, click buttons, dismiss dialogs, etc.).

## Computer Control (clicking, typing, screenshots)

You have multiple MCP tools for controlling the Mac. Use the **right tool for each job** — don't bounce between tools.

### For clicking at coordinates — use `cliclick` (FASTEST)
```bash
cliclick c:X,Y        # click
cliclick dc:X,Y       # double-click
cliclick rc:X,Y       # right-click
cliclick m:X,Y        # move mouse
cliclick t:"text"     # type text
cliclick p            # print current mouse position
cliclick kd:cmd ku:cmd  # key down/up
```
`cliclick` uses CGEvent, handles Retina correctly, works across all displays. No MCP overhead.

### For screenshots — use `codriver`
- `mcp__codriver__desktop_screenshot` — capture screen (use `scale: 0.5` for speed)
- `mcp__codriver__desktop_ocr` — find text positions on screen
- `mcp__codriver__desktop_windows` — list/focus windows

### Workflow: screenshot → find target → click
1. Take screenshot with `codriver` to see the screen
2. Identify the coordinates of what to click (use OCR if needed)
3. Click with `cliclick c:X,Y` via Bash — instant, reliable

### For native macOS app testing — use `agent-swift`
Use for the running Sessions Dev app (`agent-swift connect --bundle-id me.cepessa.sessions-dev`).

### For browser interaction — priority order:
1. **`playwright`** MCP — headless browser, most reliable for web automation
2. **`claude-in-chrome`** — for existing browser tabs (only when extension is connected)
3. **`codriver` screenshot + `cliclick`** — fallback if browser tools fail

### Rules:
- NEVER try 3+ different click tools for the same action — pick one and commit
- For multi-monitor: always check coordinates against the screenshot scale factor
- `codriver` screenshots at `scale: 0.5` means multiply coordinates by 2 before clicking
- Prefer `cliclick` over `automac`/`mac-use-mcp` click — they have coordinate bugs on multi-monitor
- When a tool errors (e.g., "helper binary not found", "extension not connected"), immediately switch to the fallback — don't retry the broken tool

## Build and run

- Dev build (Debug, `Sessions Dev.app`, bundle `me.cepessa.sessions-dev`, isolated
  data root `desktop/build/dev-data`): `cd desktop && ./run.sh [--launch]`.
- Explicit fixture data: `./run.sh --launch --test-root /absolute/path`. Never
  point `--test-root` at `~/Library/Application Support/Cepessa`.
- Production (Release, `/Applications/Sessions.app`, bundle `me.cepessa.sessions`):
  `./run.sh --production`. Only with Ben's approval for that install.
- Pass a stable `--scratch-path` per agent lane (Claude:
  `/private/tmp/claude-derived-data/<name>`). No UUID/timestamp copies.
- `desktop/scripts/test-run-safety.sh` checks run.sh's guards; run it after
  editing run.sh. `desktop/scripts/` is gitignored — add new files with `git add -f`.

## Test

- App: `xcrun swift test --package-path desktop/Desktop --scratch-path <lane>`.
  Live TypeSafe tests skip without `TYPESAFE_API_KEY`.
- Design review renders (every surface, light and dark):
  `CEPESSA_RENDER_FIXTURES=/abs/dir xcrun swift test ... --filter SessionsFixtureRenderTests`.
- MCP: `cd mcp && uv run --frozen pytest -q`; lint with `uv run --frozen ruff check`.
- A green test run is source evidence, not proof of the installed app. Report
  source, tests, installed app, and live runs separately.

## Safety rules

- Never read, modify or delete the owner's real data under
  `~/Library/Application Support/Cepessa` without explicit approval; use
  fixture roots for development and QA.
- Never quit, kill or replace `/Applications/Sessions.app` without approval;
  automate only the dev bundle `me.cepessa.sessions-dev`.
- Keep stored-session compatibility: the session model still carries recap and
  document-chat fields that nothing edits; never drop fields from saved JSON.
- Evidence in `MeetingEvidenceOutbox/` is immutable and content-hashed; the
  canonicalizer in `SessionsHandoff` is the only definition of that hash.
- Capture goes through `LocalCaptureLifecycle`'s single lease; never start
  microphone or system-audio capture outside it.
- The speech model and speaker models install through their provisioners
  (pinned revision, size and SHA-256); never place unverified model files.

## Design

- Follow `DESIGN.md`: Theme tokens (`SessionsPalette`, `SessionsType`,
  `SessionsMotion`, `SessionsSurfaces`, `SessionsOrb`), identity light kept apart
  from status signals, Hebrew right-to-left everywhere, Reduce Motion /
  Transparency / Increase Contrast respected.
- The floating capsule's panel mechanics (bleed, grow → morph → settle, no clicks
  while moving, top-centre anchor, even widths) are load-bearing; keep them.

## Git

- Work on a feature branch; land changes through a PR. Never push to `main`.
- Never squash-merge; use a regular merge.
- Commit and push only when asked. Group commits by change.
- End commit messages with the co-author line the harness provides.
