"""The MCP server mounted inside dairy-api, driven by a real MCP client.

Issue #56's trap: a mounted ASGI application's own lifespan does not run, so the
host application has to enter the session manager or every request to /mcp fails
with "Task group is not initialized". Every test here runs against a server the
`live_server` fixture actually started, so removing app.py's lifespan fails all
of them.
"""

import pytest
from httpx import AsyncClient
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from check_deployment import EXERCISE

# What the server must serve, read off check_deployment.py rather than restated.
# That map is already the answer to "every tool the deployment must serve", and a
# second copy here is a second thing to remember when a tool lands -- which is
# how a tool arrives with no deployment check behind it.
SERVED = set(EXERCISE)


@pytest.mark.anyio
async def test_a_first_request_after_a_cold_start_succeeds(live_server):
    """The handshake, against a server that has just started.

    `live_server` runs the app's lifespan, which is the only thing that enters
    the session manager. This is the acceptance criterion, and the test below
    shows what it is protecting against.
    """
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            result = await session.initialize()
            assert result.serverInfo.name == "milk-spoilage"


@pytest.mark.anyio
async def test_mcp_answers_at_the_url_the_plugin_carries(live_server):
    """/mcp itself, with no redirect. The plugin's .mcp.json points there.

    Mounting the MCP app at /mcp instead of registering its route would serve
    /mcp/ and answer /mcp with a 307, leaving the plugin's URL dependent on
    whether a given client follows redirects on POST.
    """
    async with AsyncClient(base_url=live_server, timeout=60) as client:
        response = await client.post(
            "/mcp",
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "0"},
                },
            },
            headers={
                "content-type": "application/json",
                "accept": "application/json, text/event-stream",
            },
        )
    assert response.status_code == 200
    assert "milk-spoilage" in response.text


@pytest.mark.anyio
async def test_mcp_answers_a_request_carrying_the_deployed_host(live_server):
    """A Host header that is not localhost. The Space sends one on every call.

    FastMCP enables DNS rebinding protection whenever its `host` setting is
    127.0.0.1, which is the default, and allow-lists localhost only. Every other
    test here reaches 127.0.0.1 and passes that guard without meaning to, so the
    deployed Space answered /mcp with "421 Invalid Host header" while the whole
    suite was green. This is the one test that sends what a deployment sends.
    """
    async with AsyncClient(base_url=live_server, timeout=60) as client:
        response = await client.post(
            "/mcp",
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "0"},
                },
            },
            headers={
                "host": "chenhaoq87-dairy-spoilage-api.hf.space",
                "origin": "https://claude.ai",
                "content-type": "application/json",
                "accept": "application/json, text/event-stream",
            },
        )
    assert response.status_code == 200, response.text


@pytest.mark.anyio
async def test_every_tool_the_deployment_check_exercises_lists(live_server):
    """The served set and check_deployment.py's map have to be the same set.

    A tool served here but absent from that map ships with nothing verifying it
    against the deployment; one in the map but not served turns the drift check
    red for a tool that does not exist.
    """
    async with streamable_http_client(f"{live_server}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listed = await session.list_tools()
    assert {tool.name for tool in listed.tools} == SERVED


@pytest.mark.anyio
async def test_every_existing_route_still_answers_on_the_same_port(live_server):
    """The mount must not shadow, reorder or break anything already served."""
    async with AsyncClient(base_url=live_server, timeout=60) as client:
        root = await client.get("/")
        assert root.status_code == 200
        assert root.json()["endpoints"]["mcp"] == "/mcp"

        variants = await client.get("/variants")
        assert variants.status_code == 200
        assert variants.json()["total_variants"] == 10

        methods = await client.get("/simulate/methods")
        assert methods.status_code == 200

        # The MCP endpoint is a plain Starlette route on FastAPI's router rather
        # than an APIRoute, so schema generation has to skip it rather than
        # choke on it.
        schema = await client.get("/openapi.json")
        assert schema.status_code == 200
        assert "/variants" in schema.json()["paths"]

        classify = await client.post(
            "/classify",
            json={
                "spc_d7": 2.1, "spc_d14": 4.7, "spc_d21": 6.4,
                "tgn_d7": 1.0, "tgn_d14": 3.7, "tgn_d21": 5.3,
                "model_variant": "baseline",
            },
        )
        assert classify.status_code == 200
        assert classify.json()["prediction"] in (
            "PPC", "no spoilage", "spore spoilage"
        )


@pytest.mark.anyio
async def test_health_reports_a_build_identity(live_server):
    """Whatever it holds, /health has to carry the field the drift check reads."""
    async with AsyncClient(base_url=live_server, timeout=60) as client:
        health = (await client.get("/health")).json()
    assert "payload_digest" in health["build"]
    assert "commit" in health["build"]
