import asyncio
import json
import os
import sys

import pytest
from conftest import make_id, segment, write_session
from mcp import ClientSession, types
from mcp.client.stdio import StdioServerParameters, stdio_client

from cepessa_sessions_mcp import __version__
from cepessa_sessions_mcp.server import SERVER_NAME, create_server

EXPECTED_TOOLS = {"list_sessions", "get_transcript", "search_transcripts"}
SESSION_ID = make_id("server:hebrew")
HEBREW_TEXT = "סיכום: מחר נשלח את ההצעה ללקוח."


def _list_tools() -> list[types.Tool]:
    server = create_server()
    handler = server.request_handlers[types.ListToolsRequest]
    result = asyncio.run(handler(types.ListToolsRequest(method="tools/list")))
    return result.root.tools


def _call(name: str, arguments: dict | None = None) -> types.CallToolResult:
    server = create_server()
    handler = server.request_handlers[types.CallToolRequest]
    request = types.CallToolRequest(
        method="tools/call",
        params=types.CallToolRequestParams(name=name, arguments=arguments),
    )
    return asyncio.run(handler(request)).root


def test_exactly_three_read_only_tools():
    tools = _list_tools()

    assert {tool.name for tool in tools} == EXPECTED_TOOLS
    assert len(tools) == 3
    for tool in tools:
        assert tool.annotations.readOnlyHint is True
        assert tool.annotations.openWorldHint is False
        assert tool.inputSchema["additionalProperties"] is False
        assert "sessions_root" not in tool.inputSchema["properties"]


def test_handshake_identity():
    options = create_server().create_initialization_options()

    assert options.server_name == SERVER_NAME == "cepessa-sessions"
    assert options.server_version == __version__
    assert "Read-only" in options.instructions


def test_tool_output_is_utf8_json(sessions_root):
    write_session(
        sessions_root,
        SESSION_ID,
        title="פגישה",
        segments=[segment("דנה", HEBREW_TEXT)],
    )

    result = _call("get_transcript", {"session_id": SESSION_ID})

    assert result.isError is False
    [content] = result.content
    assert HEBREW_TEXT in content.text  # raw UTF-8, not \u05xx escapes
    assert json.loads(content.text)["transcript"] == f"דנה: {HEBREW_TEXT}"


@pytest.mark.parametrize(
    ("name", "arguments", "message"),
    [
        ("list_sessions", {"limit": 0}, "Input validation error"),
        ("list_sessions", {"sessions_root": "/tmp"}, "Input validation error"),
        ("get_transcript", {"session_id": "../etc"}, "Input validation error"),
        ("search_transcripts", {"query": ""}, "Input validation error"),
        ("search_transcripts", {"query": "   "}, "blank"),
        ("get_transcript", {"session_id": make_id("missing")}, "not found"),
        ("update_local_session_title", {}, "Unknown tool"),
        ("get_memories", {}, "Unknown tool"),
    ],
)
def test_bad_calls_return_errors(sessions_root, name, arguments, message):
    result = _call(name, arguments)

    assert result.isError is True
    assert message in result.content[0].text


def test_stdio_handshake_end_to_end(sessions_root):
    write_session(sessions_root, SESSION_ID, segments=[segment("דנה", HEBREW_TEXT)])
    params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "cepessa_sessions_mcp"],
        env={**os.environ, "CEPESSA_SESSIONS_ROOT": str(sessions_root)},
    )

    async def run() -> tuple:
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                init = await session.initialize()
                tools = await session.list_tools()
                listed = await session.call_tool("list_sessions", {})
                found = await session.call_tool(
                    "search_transcripts", {"query": "ההצעה"}
                )
                return init, tools, listed, found

    init, tools, listed, found = asyncio.run(asyncio.wait_for(run(), timeout=60))

    assert init.serverInfo.name == "cepessa-sessions"
    assert {tool.name for tool in tools.tools} == EXPECTED_TOOLS
    assert json.loads(listed.content[0].text)["sessions"][0]["id"] == SESSION_ID
    assert json.loads(found.content[0].text)["results"][0]["id"] == SESSION_ID
