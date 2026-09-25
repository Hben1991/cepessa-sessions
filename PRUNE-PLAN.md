# Removing the Omi leftovers — proposal

Status: **proposal, nothing deleted.** Branch `claude/prune-omi-leftovers` (off
`main` at `c107b94a4`). Execute only after Ben approves, and after
[#4](https://github.com/Hben1991/cepessa-sessions/pull/4) (the Sessions
redesign) is merged — then rebase this branch onto `main`.

The repo is a fork of the Omi monorepo. The product is now only **Cepessa
Sessions** (`desktop/Desktop`, packaged by `desktop/run.sh`) and the **local
MCP server** (`mcp/`). Evidence below comes from a read-only inventory of both
`main` and the redesign branch (`git grep` over every path; file:line cited).

## 0. Do first, before merging #4

`.github/workflows/desktop_auto_release.yml` runs on every push to `main` that
touches `desktop/**` (`:3-9`). It deploys `desktop/Backend-Rust` to Cloud Run
(dev, then prod), pushes a `v*-macos` tag, and auto-merges a changelog PR
(`:239-269`). On this fork it has been cancelled four times after 24 h without
a runner (runs 35466187283, 30258064776, 29702552598, 29683837593) — it asks
for `ubuntu-latest-m` (`:30`). Merging #4 will queue it again; if a runner ever
picks it up it will fail on missing secrets or, worse, push a tag that
`codemagic.yaml` (`omi-desktop-swift-release`, `:1863-1891`) would try to build.

Recommendation: delete `desktop_auto_release.yml` (and
`desktop_backend_auto_dev.yml`) in a one-commit PR merged **before** #4, or
disable them in the Actions settings.

## 1. What Sessions and MCP actually depend on

**Sessions** (`desktop/Desktop`, `desktop/run.sh`, `desktop/scripts`)
- Nothing outside `desktop/`: no reference to `app/`, `backend/`, `omi/`,
  `sdks/`, `plugins/`, `web/`, `docs/`, `legacy/`, `tools/`, root `scripts/` or
  root `Package.swift` on either branch. (Only hit: a path-traversal test string,
  `Tests/LocalSessionSpeakerAnnotationStoreSafetyTests.swift:186`.)
- Package: local `Vendor/whisper.spm`, `argmax-oss-swift` 0.18.0 (+ its pins).
- `run.sh` (after #4) uses only `Desktop/Info.plist`, `Desktop/Branding/AppIcon.icns`,
  `Desktop/Cepessa-{Dev,Release}.entitlements`, and the vendored whisper Metal files.
  On `main` it still uses `desktop/omi_icon.icns` (`run.sh:241`) — gone after #4.
- Outside the repo: `~/Library/Application Support/Cepessa`, TypeWhisper model
  folders, and `/Users/ben/Documents/App/General/__MODELS__`
  (`LocalMeetingFileLayout.swift:726,748,767`).

**MCP** (`mcp/`)
- Imports only the standard library, `mcp`, `pydantic`, `requests` and its own
  `local_brain`; nothing from elsewhere in the repo (`pyproject.toml:19-24`).
- Reads `~/Library/Application Support/Cepessa/Sessions` and
  `MeetingEvidenceOutbox` (`server.py:84,448`, `local_brain.py:17,220,377`).
- 6 of its 18 tools still call the Omi cloud (`api.omi.me`, `OMI_API_KEY`):
  `get_memories`, `create_memory`, `delete_memory`, `edit_memory`,
  `get_conversations`, `get_conversation_by_id` (`server.py:79,137-142,1738-1798`).
- Tests: `cd mcp && uv run --frozen pytest -q` (102 passed on #4). No CI runs them.

**CI:** no workflow builds or tests `desktop/Desktop` or `mcp/`.

## 2. Delete — nothing in Sessions or MCP points here

| Path | Size (tracked) | Why it is safe |
|---|---:|---|
| `plugins/` | 208 MB | Omi plugin apps. Only root `package.json`, `gcp_apps_js.yml`, `gcp_plugins.yml` reference it. |
| `omi/` | 113 MB | Omi firmware/hardware, incl. `firmware/FLASH_3.0.8/{MAC,WINDOWS}/bootloader烧录.bat` (the odd quoted names). |
| `sdks/` | 76 MB | Omi SDKs. Root `Package.swift:31` (`path: "sdks/swift"`) is the only Swift user; nothing builds it. |
| `docs/` | 75 MB | Omi Mintlify docs; `deploy_docs.yml`, `sync-docs.yml` only. |
| `app/` | 43 MB | Omi Flutter app; `lint.yml`, `codemagic.yaml`, `scripts/pre-commit` only. |
| `omiGlass/` | 42 MB | Omi glasses; root `package.json`, `sync-docs.yml`. |
| `web/` | 17 MB | Omi web apps; `gcp_admin/app/frontend/personas.yml`, `lint.yml`. |
| `backend/` | 17 MB | Omi backend; `gcp_backend*.yml`, `lint.yml`, `scripts/pre-commit`. |
| `legacy/` | 2 MB | Old Flutter desktop. |
| `figma/` | <1 MB | Omi onboarding Figma plugin (`onboarding_figma_sync.yml`). |
| root `scripts/` | <1 MB | `pre-commit` formats only app/backend/web/omi/omiGlass (`:4-80`); the rest is Omi analytics/firmware/Codemagic. |
| root `Package.swift`, `Package.resolved` | — | the "omi-lib" iOS SDK package (`sdks/swift`). |
| root `package.json`, `package-lock.json` | — | expo/ioredis/dotenv for omiGlass, plugins, web. |
| `community-plugins.json`, `community-plugin-stats.json` | — | Omi plugin store data. |
| `TEST.md`, `HANDOFF-exports-after-import.md` | — | Omi testing notes / an old handoff. |
| `codemagic.yaml` | — | Omi mobile + desktop release pipelines; its app ID is upstream Omi's (`scripts/cm-builds.sh:8`); the desktop workflow builds the old Omi app and would fail. |
| `desktop/Backend-Rust`, `desktop/Auth-Python`, `desktop/agent-cloud`, `desktop/acp-bridge` | — | Omi desktop backend/auth/agents; not in `Package.swift` or `run.sh`. |
| `desktop/e2e`, `desktop/demo`, `desktop/prototypes`, `desktop/docs` | — | Omi desktop tests, demos, prototypes, docs; no callers. |
| `desktop/dmg-assets`, `desktop/omi_icon.icns` | — | used only by `codemagic.yaml` (and `main`'s `run.sh`, fixed by #4). |
| `desktop/.env.example`, `desktop/.auto-release-trigger`, `desktop/.release-trigger`, `desktop/PLAN.md` | — | nothing reads them; the trigger files only feed the auto-release workflow. |
| `desktop/.github/` | — | `sync-to-monorepo`, `test-install`; GitHub never runs nested workflow folders. |
| `desktop/scripts/test-focus.sh` | — | targets "Omi Dev" and a notification that no longer exists. |
| `desktop/Desktop/ObjCExceptionCatcher`, `Cepessa.entitlements`, `Node.entitlements`, `embedded*.provisionprofile` | — | not in `Package.swift` or `run.sh`; only `codemagic.yaml:1940,2165,2194`. |

Together roughly 590 MB of the working tree. The `.git` history (1.0 GB) keeps
every removed blob unless history is rewritten — see decision 7.

## 3. CI

Remove all 26 workflows in `.github/workflows/`:

- **Would deploy or push on this fork:** `desktop_auto_release`,
  `desktop_backend_auto_dev`, `gcp_backend_auto_dev`,
  `gcp_backend_pusher_auto_deploy`, `gcp_backend_agent_proxy_auto_deploy`,
  `gcp_admin`, `gcp_app`, `gcp_frontend`, `gcp_personas`, `gcp_apps_js`,
  `gcp_plugins` (push triggers on removed trees; several already failed on
  missing GCP secrets, e.g. runs 29683837610, 24665503950).
- **Manual GCP deploys:** `gcp_backend`, `gcp_backend_agent_proxy`,
  `gcp_backend_listen_helm`, `gcp_backend_pusher`, `gcp_diarizer`,
  `gcp_models`, `gcp_notifications_job`.
- **Omi repo automation:** `lint` (formats only removed trees), `main` (Omi
  project board), `pr-declined-comment` (Omi-branded comment), `sync-docs`,
  `deploy_docs`, `onboarding_figma_sync`, `entellegence_issues`,
  `entelligence-pr-reviewer`.
- Plus `.github/ISSUE_TEMPLATE/*` (Omi bounties) and `.github/issue-assets/`.

Replace with one workflow, `sessions-ci.yml`, on pull requests and pushes to
`main`:

- `mcp`: `ubuntu-latest`, `uv run --frozen pytest -q` and `ruff check` in `mcp/`.
- `desktop` (see decision 4): `macos` runner, `swift build --build-tests`, `swift
  test`, `desktop/scripts/test-run-safety.sh`. The package needs the macOS 26
  SDK; confirm a GitHub-hosted image with Xcode 26+ is available first.

## 4. Root agent guides

`CLAUDE.md` and `AGENTS.md` on this branch are rewritten for Sessions (see the
files). Removed: Omi backend import rules and service map, Flutter l10n and
agent-flutter, Firebase, Codemagic, backend deploy and `RELEASE` /
`RELEASEWITHBACKEND` commands, Mintlify docs maintenance, Omi logging runbooks.
`desktop/CLAUDE.md` (Sentry, PostHog, Codemagic, emailing Omi users) should
then shrink to desktop build notes or be folded into the root guide — do that
after #4 merges, since #4 edits it.

Also stale and Omi-oriented: `README.md` (Omi's), `.cursor/` rules and hooks,
`.cursorignore`, `.gemini/config.yaml`, `ISSUE_TRIAGE_GUIDE.MD`, and the root
`.gitignore` sections for removed trees (`:47-216`).

## 5. Keep

- `desktop/Desktop`: `Package.swift`/`.resolved`, `Sources`, `Tests`,
  `SessionsHandoff`, `MicrophoneCaptureHelper`, `Vendor`, `Info.plist`,
  `Cepessa-Dev.entitlements`, `Cepessa-Release.entitlements`, `Branding`.
- `desktop/run.sh`, `desktop/scripts/test-run-safety.sh`, `desktop/.gitignore`,
  `desktop/README.md`, `desktop/CEPESSA-INTEGRATION.md`, `desktop/CHANGELOG.json`
  (decision 3).
- `mcp/`: `src`, `tests`, `pyproject.toml`, `uv.lock`, `.python-version`.
- Root: `.gitignore` (trimmed), `DESIGN.md`, `PRODUCT.md`, `CLAUDE.md`,
  `AGENTS.md`, `README.md` (rewritten), and **`LICENSE`** — Omi is MIT; the
  copyright notice must stay with code derived from it.

## 6. Decisions for Ben

1. **Order:** remove `desktop_auto_release.yml` before merging #4 (recommended),
   or disable Actions for the repo until the prune lands?
2. **MCP's Omi cloud side:** remove the 6 `api.omi.me` tools, `Dockerfile`,
   `release.sh` (pushes `omiai/mcp-server` to Docker Hub), `examples/`,
   `.env.template` — or keep them?
3. **`desktop/CHANGELOG.json`:** keep as the Sessions release notes (only the
   Omi release pipeline reads it today) or drop it?
4. **Desktop CI:** worth a macOS runner (billed minutes, needs Xcode 26+ image),
   or MCP-only CI and local testing for the app?
5. **Cepessa material with no callers:** `tools/transcription_eval`, `qa/`,
   `outputs/` — keep (move under `desktop/`?) or delete?
6. **Agent rules in the old root guide** that look like yours rather than
   Omi's: "Behavior" (never ask permission/confirmation), "Computer Control"
   (cliclick/codriver), and git rules (PR-only, no squash, *one commit per
   file*, "always work in a worktree"). The draft keeps Behavior, Computer
   Control and PR-only/no-squash, and drops one-commit-per-file. Confirm.
7. **History:** leave the 1 GB history as is (recommended; deletion is a normal
   commit), or rewrite it with `git filter-repo` into a small repo (breaks
   every clone, fork and open PR)?
8. **Machine-specific paths in Swift:** `/Users/ben/Documents/App/General/__MODELS__`
   and the TypeWhisper model folders — keep as personal fallbacks, or remove
   now that the app installs its own model?

## 7. Execution, once approved

1. PR A (tiny, merge first): delete `desktop_auto_release.yml` and
   `desktop_backend_auto_dev.yml`.
2. Merge #4; rebase this branch onto `main`.
3. PR B: the deletions in §2 and §3 as separate commits (trees, root files,
   desktop leftovers, workflows), the new `sessions-ci.yml`, the rewritten
   `CLAUDE.md`/`AGENTS.md`/`README.md`, trimmed `.gitignore`.
4. Verify on the branch: `desktop/run.sh --dry-run`,
   `desktop/scripts/test-run-safety.sh`, `swift build --build-tests` and
   `swift test` in `desktop/Desktop`, `uv run --frozen pytest -q` in `mcp/`,
   and `git grep` for each removed path name returning nothing outside history.
