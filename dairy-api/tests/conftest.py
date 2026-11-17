"""A real uvicorn on a loopback port, for the tests that need the whole stack.

The MCP tools reach dairy-api over loopback HTTP (ADR 016), and the mounted MCP
route only works once the host application's lifespan has entered its session
manager. Neither is visible to an in-process ASGI transport, so the tests that
care about them drive a server that was actually started.

One server for the whole session, in its own thread. A StreamableHTTPSessionManager
runs once per instance and refuses a second run(), which is what production does
too -- one process, one lifespan.
"""

from __future__ import annotations

import os
import threading
import time

import pytest
import uvicorn

from app import app


@pytest.fixture
def anyio_backend():
    return "asyncio"


class _Server(uvicorn.Server):
    def install_signal_handlers(self) -> None:
        """No-op: the server runs off the main thread, where signals do not land."""


@pytest.fixture(scope="session")
def live_server():
    """Serve the app on an ephemeral loopback port and yield its base URL.

    DAIRY_API_BASE_URL is set for the duration, which is how the tools find the
    API -- the same environment variable a deployment would set.
    """
    config = uvicorn.Config(app, host="127.0.0.1", port=0, log_level="warning")
    server = _Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()

    deadline = time.monotonic() + 60
    while not server.started:
        if not thread.is_alive():
            raise RuntimeError("the test server exited during startup")
        if time.monotonic() > deadline:
            raise RuntimeError("the test server did not start within 60s")
        time.sleep(0.02)

    port = server.servers[0].sockets[0].getsockname()[1]
    base_url = f"http://127.0.0.1:{port}"
    previous = os.environ.get("DAIRY_API_BASE_URL")
    os.environ["DAIRY_API_BASE_URL"] = base_url
    try:
        yield base_url
    finally:
        if previous is None:
            os.environ.pop("DAIRY_API_BASE_URL", None)
        else:
            os.environ["DAIRY_API_BASE_URL"] = previous
        server.should_exit = True
        thread.join(timeout=30)
