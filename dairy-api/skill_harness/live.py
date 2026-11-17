"""One MCP tool call to the pinned target, synchronously.

The live half of this harness exercises the tool surface the way a
practitioner's assistant does: a real MCP client, over streamable HTTP, to the
mounted server. Nothing imports the tool functions -- issues #38 and #42 were
both a deployment answering differently from the repository, and only a call
that leaves the process can see that.

The server is stateless (a free-tier Space sleeps and restarts), so each call
opens its own session; there is no server-side state a shared session would
keep. The prediction tools run a real simulation, so the timeout is generous.
"""

from __future__ import annotations

import asyncio
import json
from datetime import timedelta
from typing import Any, Optional

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

_CALL_TIMEOUT = timedelta(seconds=300)


async def _one(base_url: str, tool: str, arguments: Optional[dict]) -> Any:
    async with streamable_http_client(f"{base_url}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            return await session.call_tool(
                tool, arguments or {}, read_timeout_seconds=_CALL_TIMEOUT
            )


async def _tools(base_url: str) -> list:
    async with streamable_http_client(f"{base_url}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            return (await session.list_tools()).tools


def call(base_url: str, tool: str, arguments: Optional[dict] = None) -> dict:
    """Call one tool and return its structured result. Fails the test on error."""
    result = asyncio.run(_one(base_url, tool, arguments))
    assert not result.isError, (
        f"{tool} refused or errored where the procedure expects an answer: "
        f"{text_of(result)}"
    )
    return data_of(result)


def call_text(base_url: str, tool: str, arguments: Optional[dict] = None) -> str:
    """Call one tool that answers in prose, and return the prose."""
    result = asyncio.run(_one(base_url, tool, arguments))
    assert not result.isError, (
        f"{tool} refused or errored where the procedure expects an answer: "
        f"{text_of(result)}"
    )
    return text_of(result)


def refusal(base_url: str, tool: str, arguments: Optional[dict] = None) -> str:
    """Call one tool the procedure says must refuse, and return the refusal text."""
    result = asyncio.run(_one(base_url, tool, arguments))
    assert result.isError, (
        f"{tool} answered where the procedure requires a refusal -- a refusal "
        f"that silently succeeds looks like an answer: {data_of(result)!r}"
    )
    return text_of(result)


def tool_names(base_url: str) -> set[str]:
    return {tool.name for tool in asyncio.run(_tools(base_url))}


def text_of(result) -> str:
    return "".join(
        block.text for block in result.content if getattr(block, "text", None)
    )


def data_of(result) -> dict:
    return result.structuredContent or json.loads(text_of(result))
