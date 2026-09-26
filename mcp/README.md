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
- `offset` (integer, ≥ 0, default 0)

As in the app, the search covers each session's title and spoken text,
case-insensitively; speaker names are not searched. A session matches when that
text contains the whole query or every word of it. `totalMatches` counts every
matching session; use `offset` to page past `limit`.

Output:

```json
{
  "query": "תקציב",
  "totalMatches": 3,
  "offset": 0,
  "limit": 10,
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
          "snippet": "נתחיל בתקציב."
        }
      ]
    }
  ]
}
```

At most three snippets are returned per session, taken from the spoken text;
each is cut to about 120 characters on either side of the match. A session
that matched on its title alone has none.

## Sessions root

The server reads `<root>/<session UUID>/session.json`. The roots are:

1. `CEPESSA_SESSIONS_ROOT`, when set, and nothing else;
2. otherwise the app's two stores, in the app's order:
   `~/Library/Application Support/Cepessa/Sessions`, then
   `~/Library/Application Support/Cepessa Legacy/Meetings/Sessions`. A session
   in the first hides one with the same ID in the second, unless the first copy
   cannot be read.

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
- Each read opens the root, then the session folder, then `session.json`, each
  relative to the one before and none through a link. No folder can be swapped
  for a link between a check and the read. `session.json` must be a regular
  file with a single hard link, at most 32 MiB.
- `session.json` must be UTF-8 JSON (no `NaN`/`Infinity`, no unpaired
  surrogates, at most 512 levels deep) and must decode under the same rules as
  the app's Swift models, including matching its folder ID. The earliest
  recordings' offset times (`"12:34"`) and missing segment IDs are converted
  the way the app converts them. A session that fails any check is skipped by
  `list_sessions` and `search_transcripts` (and counted in `skippedCount`);
  `get_transcript` returns an error for it.
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
