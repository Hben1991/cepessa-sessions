# mcp-server-omi: A OMI MCP server

## Overview

A Model Context Protocol server for Omi interaction and automation. This server provides tools to read, search, and manipulate Memories and Conversations.

### Tools
1. `get_memories`
   - Retrieve a list of user memories
   - Inputs:
     - `limit` (number, optional): Maximum number of memories to retrieve (default: 100)
     - `categories` (array of MemoryFilterOptions, optional): Categories of memories to retrieve (default: [])
   - Returns: JSON object containing list of memories

2. `create_memory`
   - Create a new memory
   - Inputs:
     - `content` (string): Content of the memory
     - `category` (MemoryFilterOptions): Category of the memory
   - Returns: Created memory object

3. `delete_memory`
   - Delete a memory by ID
   - Inputs:
     - `memory_id` (string): ID of the memory to delete
   - Returns: Status of the operation

4. `edit_memory`
   - Edit a memory's content
   - Inputs:
     - `memory_id` (string): ID of the memory to edit
     - `content` (string): New content for the memory
   - Returns: Status of the operation

5. `get_conversations`
   - Retrieve a list of user conversations
   - Inputs:
     - `start_date` (string, optional): Filter after this date (`yyyy-mm-dd`)
     - `end_date` (string, optional): Filter before this date (`yyyy-mm-dd`)
     - `categories` (array, optional): Categories of conversations to retrieve (default: [])
     - `limit` (number, optional): Maximum number of conversations to retrieve (default: 20)
     - `offset` (number, optional): Pagination offset (default: 0)
   - Returns: List of conversation metadata. Use `get_conversation_by_id` for full transcripts.

6. `get_conversation_by_id`
   - Retrieve a cloud Omi conversation by ID, including transcript segments
   - Inputs:
     - `conversation_id` (string): ID of the conversation
   - Returns: Conversation metadata and transcript segments

7. `list_local_sessions`
   - List Cepessa Sessions stored locally on this Mac
   - Inputs:
     - `sessions_root` (string, optional): Path to the Cepessa Sessions root. Defaults to `CEPESSA_SESSIONS_ROOT` or `~/Library/Application Support/Cepessa/Sessions`
     - `limit` (number, optional): Maximum number of sessions to retrieve (default: 20)
     - `offset` (number, optional): Pagination offset (default: 0)
   - Returns: Local session IDs, titles, timestamps, status, transcript counts, and previews

8. `get_local_session_transcript`
   - Retrieve a local Cepessa Session transcript directly from `session.json`
   - Inputs:
     - `session_id` (string): Local Cepessa Session ID
     - `sessions_root` (string, optional): Override local sessions root
   - Returns: Session metadata, markdown transcript, recap, document markdown, and the source `session.json` path

9. `search_local_session_transcripts`
   - Search locally stored Cepessa Session transcripts
   - Inputs:
     - `query` (string): Case-insensitive words to search for
     - `sessions_root` (string, optional): Override local sessions root
     - `limit` (number, optional): Maximum number of matching sessions to return (default: 10)
   - Returns: Matching local sessions with transcript snippets

10. `update_local_session_title`
   - Rename a local Cepessa Session by writing the `title` field in the app's `session.json`
   - Inputs:
     - `session_id` (string): Local Cepessa Session ID
     - `title` (string): New non-empty title
     - `sessions_root` (string, optional): Override local sessions root
   - Returns: Updated local session metadata and source `session.json` path

11. `get_local_session_data`
   - Retrieve the full raw local Cepessa Session JSON
   - Inputs:
     - `session_id` (string): Local Cepessa Session ID
     - `sessions_root` (string, optional): Override local sessions root
   - Returns: Full `session.json`, the session directory, and the source path. This is the future-compatible surface for new app-backed session fields.

12. `list_local_session_files`
   - List every file in a local Cepessa Session directory
   - Inputs:
     - `session_id` (string): Local Cepessa Session ID
     - `sessions_root` (string, optional): Override local sessions root
   - Returns: Local paths, relative paths, sizes, and extensions for images, audio, exports, attachments, and future feature files.

13. `update_local_session_fields`
   - Atomically merge top-level JSON fields into a local `session.json`
   - Inputs:
     - `session_id` (string): Local Cepessa Session ID
     - `fields` (object): Top-level fields to write
     - `sessions_root` (string, optional): Override local sessions root
   - Returns: Updated local session metadata and changed field names. Protected identity fields such as `id` are rejected.

14. `list_local_clips`
   - List Cepessa CLIPS stored locally on this Mac
   - Inputs:
     - `clips_root` (string, optional): Path to the Cepessa CLIPS root. Defaults to `CEPESSA_CLIPS_ROOT` or `~/Library/Application Support/Cepessa/Clips`
     - `limit` (number, optional): Maximum number of clips to retrieve (default: 20)
     - `offset` (number, optional): Pagination offset (default: 0)
   - Returns: CLIP IDs, titles, timestamps, status, transcript counts, previews, and media paths

15. `get_local_clip`
   - Retrieve a local Cepessa CLIP bundle for agent inspection
   - Inputs:
     - `clip_id` (string): Local Cepessa CLIP ID
     - `clips_root` (string, optional): Override local CLIPS root
   - Returns: CLIP manifest JSON, transcript segments, post notes, and paths to video/audio/transcript/notes files

16. `list_local_clip_files`
   - List every file in a local Cepessa CLIP directory
   - Inputs:
     - `clip_id` (string): Local Cepessa CLIP ID
     - `clips_root` (string, optional): Override local CLIPS root
   - Returns: Local paths, relative paths, sizes, and extensions for the CLIP agent packet

17. `brain_status`
   - Refresh and report the rebuildable local meeting-evidence index
   - Returns: Index schema, session/segment counts, incremental refresh counts, and safety flags

18. `search_meeting_brain`
   - Search Hebrew, English, or mixed meeting evidence
   - Inputs:
     - `query` (string): Terms to find in transcript evidence
     - `limit` (number, optional): Maximum matching segments (default: 10)
   - Returns: Exact cited segments. Every citation includes logical source reference, session, revision, segment, time, and source kind.

19. `prepare_agent_context`
   - Build a bounded context packet for another agent
   - Inputs:
     - `query` (string): Question or topic
     - `token_budget` (number, optional): Maximum estimated evidence tokens (default: 2000)
     - `limit` (number, optional): Maximum search hits considered (default: 20)
   - Returns: Cited transcript segments and an explicit instruction-injection policy

20. `get_meeting_evidence`
   - Retrieve cited evidence from an exact session or transcript segment
   - Inputs:
     - `session_id` (string): Local Cepessa Session ID
     - `segment_id` (string, optional): Exact segment ID
     - `context_segments` (number, optional): Neighboring segments around the anchor (default: 2)
   - Returns: Session revision and cited transcript evidence

21. `resolve_participant`
   - Explain possible stored speaker-label matches with transcript citations
   - Inputs:
     - `name` (string): Name or speaker label to investigate
     - `limit` (number, optional): Maximum candidates (default: 10)
   - Returns: Unresolved candidates and evidence. This tool never binds an identity or performs biometric matching.

## Configuration

### API Key

To use the Omi MCP server, you need an API key. You can generate one in the Omi app under `Settings > Developer > MCP`. The API key can be provided with each tool call. If not provided, the server will use the `OMI_API_KEY` environment variable as a fallback.

The local Cepessa Session tools do not require `OMI_API_KEY`; they read/write `session.json` files and list session artifacts from this Mac. By default they use:

```bash
~/Library/Application Support/Cepessa/Sessions
```

The local Cepessa CLIPS tools also do not require `OMI_API_KEY`; they read local CLIP packets from:

```bash
~/Library/Application Support/Cepessa/Clips
```

To point agents at another local app build or a test fixture:

```bash
export CEPESSA_SESSIONS_ROOT="/path/to/Cepessa/Sessions"
export CEPESSA_CLIPS_ROOT="/path/to/Cepessa/Clips"
```

The meeting-brain tools build a retained in-memory SQLite projection and never open
an index file. For sessions using `TranscriptionEvidence`, discovery uses the global
flat `<base>/MeetingEvidenceOutbox`, where each JSON file is the full immutable
envelope. The consumer requires its per-session archived Run to be byte-identical,
then verifies the canonical full-evidence hash (all envelope fields except
`contentHash`), revision linkage, transcript byte offsets, timestamps, independent
microphone/system integrity and SHA-256 provenance, session and run readiness, and
the complete quality gate before citing the exact run and revision. Failed,
degraded, incomplete, or corrupt evidence is quarantined per session; an invalid
new revision withdraws that session’s older projection without blocking unrelated
ready meetings. Older sessions are indexed from `session.json` only when the
session status is `ready`, and every resulting citation is explicitly marked
`legacy-session-json`.

Meeting-brain source files are opened read-only with no-follow, single-hardlink, and
inode-stability checks. The tools never expose absolute source paths or biometric
data and reject symlink/path escapes. The projection is rebuilt from session
evidence for each MCP request; `CEPESSA_MEETING_BRAIN_DB` is intentionally ignored.

### Usage with Claude Desktop

Add this to your `claude_desktop_config.json`:

<details>
<summary>Using docker</summary>

Install docker, https://orbstack.dev/ is great.

Replace `your_api_key_here` with the key you generated in the Omi app.

```json
"mcpServers": {
  "omi": {
    "command": "docker",
    "args": ["run", "--rm", "-i", "-e", "OMI_API_KEY=your_api_key_here", "omiai/mcp-server"]
  }
}
```
</details>

<details>
<summary>Using uvx for local Cepessa transcripts</summary>

From this repository checkout:

```json
"mcpServers": {
  "cepessa-sessions": {
    "command": "uvx",
    "args": ["--from", "/Users/ben/Documents/App/General/Cepessa Sessions/mcp", "mcp-server-omi"]
  }
}
```

If you want both cloud Omi tools and local Cepessa transcript tools:

```json
"mcpServers": {
  "cepessa-sessions": {
    "command": "uvx",
    "args": ["--from", "/Users/ben/Documents/App/General/Cepessa Sessions/mcp", "mcp-server-omi"],
    "env": {
      "OMI_API_KEY": "your_api_key_here",
      "CEPESSA_SESSIONS_ROOT": "/Users/ben/Library/Application Support/Cepessa/Sessions"
    }
  }
}
```
</details>

<details>
<summary>Using Codex</summary>

Add this to `~/.codex/config.toml`:

```toml
[mcp_servers.cepessa_sessions]
command = "uvx"
args = ["--from", "/Users/ben/Documents/App/General/Cepessa Sessions/mcp", "mcp-server-omi"]
startup_timeout_sec = 30
```

After restarting Codex, ask it to use the `cepessa_sessions` MCP server, then call `list_local_sessions`, `search_local_session_transcripts`, `get_local_session_transcript`, `list_local_clips`, or `get_local_clip`.
</details>

<details>
<summary>Using pip installation</summary>

Requires python >= 3.11.6. 
- Check `python --version`, and `brew list --versions | grep python` (you might have other versions of python installed)
- Get the path of the python version (`which python`) or with brew

```json
"mcpServers": {
  "omi": {
    "command": "/opt/homebrew/bin/python3.12",
    "args": ["-m", "mcp_server_omi"]
  }
}
```
</details>

## Debugging

You can use the MCP inspector to debug the server. For uvx installations:

```
npx @modelcontextprotocol/inspector uvx mcp-server-omi
```

Or if you've installed the package in a specific directory or are developing on it:

```
cd path/to/servers/src/omi
npx @modelcontextprotocol/inspector uv run mcp-server-omi
```

Running `tail -n 20 -f ~/Library/Logs/Claude/mcp-server-omi.log` will show the logs from the server and may
help you debug any issues.

## Advanced

### Custom Backend URL

If you are self-hosting the Omi backend, you can specify the API endpoint by setting the `OMI_API_BASE_URL` environment variable.

```bash
export OMI_API_BASE_URL="https://your-backend-url.com"
```

## License

This MCP server is licensed under the MIT License. This means you are free to use, modify, and distribute the software, subject to the terms and conditions of the MIT License. For more details, please see the LICENSE file in the project repository.
