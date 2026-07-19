import logging

from mcp_server_omi import server
from mcp_server_omi.server import (
    ConversationCategory,
    MemoryCategory,
    get_conversations,
    get_memories,
)


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def json(self):
        return self.payload


def test_get_memories_passes_pagination_and_categories(monkeypatch):
    calls = []

    def fake_get(url, params, headers):
        calls.append({"url": url, "params": params, "headers": headers})
        return FakeResponse([{"id": "memory-1", "content": "Remember this"}])

    monkeypatch.setattr(server.requests, "get", fake_get)

    result = get_memories(
        logging.getLogger("test"),
        "test-key",
        offset=2,
        limit=5,
        categories=[MemoryCategory.core, MemoryCategory.work],
    )

    assert result == [{"id": "memory-1", "content": "Remember this"}]
    assert calls == [
        {
            "url": f"{server.base_url}memories",
            "params": {"offset": 2, "limit": 5, "categories": "core,work"},
            "headers": {"Authorization": "Bearer test-key"},
        }
    ]


def test_get_conversations_passes_date_filters_and_categories(monkeypatch):
    calls = []

    def fake_get(url, params, headers):
        calls.append({"url": url, "params": params, "headers": headers})
        return FakeResponse([{"id": "conversation-1", "title": "Demo"}])

    monkeypatch.setattr(server.requests, "get", fake_get)

    result = get_conversations(
        logging.getLogger("test"),
        "test-key",
        start_date="2026-06-01",
        end_date="2026-06-02",
        categories=[ConversationCategory.business],
        limit=10,
        offset=3,
    )

    assert result == [{"id": "conversation-1", "title": "Demo"}]
    assert calls == [
        {
            "url": f"{server.base_url}conversations",
            "params": {
                "limit": 10,
                "offset": 3,
                "start_date": "2026-06-01T00:00:00",
                "end_date": "2026-06-02T23:59:59",
                "categories": "business",
            },
            "headers": {"Authorization": "Bearer test-key"},
        }
    ]
