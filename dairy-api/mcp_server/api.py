"""Loopback client for dairy-api.

ADR 016 co-hosts the MCP server inside the FastAPI app that serves dairy-api,
because a Docker Space routes one port. The tools still reach the API the way
any client would -- over HTTP, to 127.0.0.1 -- rather than importing the
services behind it. That keeps the tool surface a client of a published API, so
what the tools exercise is what an external caller gets.

The base URL is read per call, not at import, so a caller can point the tools at
a different host by setting DAIRY_API_BASE_URL.
"""

from __future__ import annotations

import os
from typing import Any

import httpx

# /simulate takes about 40 seconds at the production default on free CPU-basic,
# so the default is set for the whole client rather than per call.
DEFAULT_TIMEOUT = 120.0


def base_url() -> str:
    """Where dairy-api answers. Loopback, on the port uvicorn was told to bind."""
    override = os.environ.get("DAIRY_API_BASE_URL")
    if override:
        return override.rstrip("/")
    return f"http://127.0.0.1:{os.environ.get('PORT', '7860')}"


def timeout() -> float:
    """How long a call waits. Read per call, so a deployment can raise it.

    The simulation tools bound their run size against this before sending, so a
    deployment that raises the timeout also raises what those tools accept.
    """
    return float(os.environ.get("DAIRY_API_TIMEOUT", DEFAULT_TIMEOUT))


class ApiError(RuntimeError):
    """dairy-api answered, and said no."""


async def _request(method: str, path: str, **kwargs: Any) -> Any:
    async with httpx.AsyncClient(base_url=base_url(), timeout=timeout()) as client:
        response = await client.request(method, path, **kwargs)

    if response.status_code >= 400:
        # FastAPI puts the reason in `detail`. Surface it: a tool that reports
        # only a status code makes the agent guess at what to fix.
        try:
            detail = response.json().get("detail", response.text)
        except ValueError:
            detail = response.text
        raise ApiError(f"{method} {path} returned {response.status_code}: {detail}")

    return response.json()


async def get(path: str) -> Any:
    return await _request("GET", path)


async def post(path: str, body: dict[str, Any]) -> Any:
    return await _request("POST", path, json=body)
