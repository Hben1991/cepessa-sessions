# cepessa-sessions-mcp

Read-only MCP server for Cepessa Sessions transcripts.

It lists, reads and searches the transcripts that the Cepessa Sessions app
stores on this Mac. It has three tools, all read-only. It makes no network
calls and never writes to the Sessions store.

## Tools

All results are JSON text (UTF-8; Hebrew and other non-ASCII text is returned
as is). Sessions are sorted newest first by `startedAt`.

### `list_sessions`

Inputs:

- `limit` (integer, 1–200, default 20)
- `offset` (integer, ≥ 0, default 0)

Output:

```json
{
  "total": 42,
  "offset": 0,
  "limit": 20,
  "skippedCount": 0,
  "sessions": [
    {
      "id": "0B1F…",
      "title": "פגישת תכנון",
      "startedAt": "2026-06-11T08:00:00Z",
      "status": "ready",
      "segmentCount": 118,
      "hasTranscript": true
    }
  ]
}
```

`status` is one of `recording`, `transcribing`, `ready`, `failed`.
`hasTranscript` is true when at least one segment has non-blank text.
`skippedCount` counts session folders that failed the safety or format checks
below and were left out.

### `get_transcript`

Inputs:

- `session_id` (string, UUID from `list_sessions` or `search_transcripts`)

Output:

```json
{
  "id": "0B1F…",
  "title": "פגישת תכנון",
  "startedAt": "2026-06-11T08:00:00Z",
  "status": "ready",
  "segmentCount": 2,
  "segments": [
    {
      "id": "5C2A…",
      "speaker": "דנה",
      "text": "נתחיל בתקציב.",
      "timestamp": "2026-06-11T08:00:01Z",
      "endTimestamp": "2026-06-11T08:00:04Z"
    }
  ],
  "transcript": "דנה: נתחיל בתקציב.\nYou: …"
}
```

`segments` are returned as stored; `endTimestamp` is `null` when the app did
not record one. `transcript` is one `Speaker: text` line per non-blank segment
(an empty speaker label is shown as `Speaker`).

### `search_transcripts`

Inputs:

- `query` (string, 1–500 characters)
- `limit` (integer, 1–50, default 10)

A session matches when its transcript contains the whole query, or every word
of it, case-insensitively. Speaker labels are searched too.

Output:

```json
{
  "query": "תקציב",
  "totalMatches": 3,
  "skippedCount": 0,
  "results": [
    {
      "id": "0B1F…",
      "title": "פגישת תכנון",
      "startedAt": "2026-06-11T08:00:00Z",
      "status": "ready",
      "segmentCount": 118,
      "hasTranscript": true,
      "matchingSegmentCount": 4,
      "snippets": [
        {
          "segmentId": "5C2A…",
          "speaker": "דנה",
          "timestamp": "2026-06-11T08:00:01Z",
          "snippet": "דנה: נתחיל בתקציב."
        }
      ]
    }
  ]
}
```

At most three snippets are returned per session; each is cut to about 120
characters on either side of the match.

## Sessions root

The server reads `<root>/<session UUID>/session.json`. The root is:

1. `CEPESSA_SESSIONS_ROOT`, when set;
2. otherwise `~/Library/Application Support/Cepessa/Sessions`.

Tools cannot choose a different root per call. To serve a fixture or a dev
build's data, set `CEPESSA_SESSIONS_ROOT` in the server's environment.

## Read-only guarantee and safety checks

- No tool writes, renames, locks or deletes anything, and the code has no path
  that opens a file for writing. The tests check this on a store whose files
  and folders are all read-only.
- Reads take no lock: the app replaces `session.json` atomically, so a reader
  always sees a whole file.
- The root must be a real directory, not a symlink.
- Session IDs must be UUIDs; any other name (including `../`) is rejected.
- A session folder must be a real directory directly under the root, and
  `session.json` must be a regular file with a single hard link, at most 32 MiB,
  opened with no-follow and checked again after opening.
- `session.json` must be UTF-8 JSON (no `NaN`/`Infinity`) and must decode
  under the same rules as the app's Swift models, including matching its folder
  ID. A session that fails any check is skipped by `list_sessions` and
  `search_transcripts` (and counted in `skippedCount`); `get_transcript` returns
  an error for it.
- Transcript text is meeting content. Clients should treat it as data, not as
  instructions.

## Install and run

Requires [uv](https://docs.astral.sh/uv/). From this directory:

```bash
uv run cepessa-sessions-mcp        # stdio server; -v / -vv logs to stderr
```

### Claude Code

```bash
claude mcp add cepessa-sessions -- uv --directory "/path/to/Cepessa Sessions/mcp" run cepessa-sessions-mcp
```

### Claude Desktop, Claude Code (`.mcp.json`) and similar clients

```json
{
  "mcpServers": {
    "cepessa-sessions": {
      "command": "uv",
      "args": [
        "--directory",
        "/path/to/Cepessa Sessions/mcp",
        "run",
        "cepessa-sessions-mcp"
      ],
      "env": {
        "CEPESSA_SESSIONS_ROOT": "/Users/you/Library/Application Support/Cepessa/Sessions"
      }
    }
  }
}
```

`env` is optional; leave it out to use the default root.

### Debugging

```bash
npx @modelcontextprotocol/inspector uv --directory "/path/to/Cepessa Sessions/mcp" run cepessa-sessions-mcp
```

## Test

Tests build fixture sessions in temporary directories and never read the real
store.

```bash
uv run --frozen pytest -q
uv run --frozen ruff check
uv run --frozen ruff format --check
```

## License

MIT. See [LICENSE](LICENSE). This server started as a fork of an MIT-licensed
MCP server; its original copyright notice is kept in `LICENSE`.
