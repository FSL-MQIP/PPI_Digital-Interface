"""Unified Dairy API — Milk spoilage classification and simulation.

Also the host for the milk-spoilage MCP server, mounted at /mcp (ADR 016). A
Docker Space routes one port, so both surfaces are served by one process.
"""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from build_info import build_info
from mcp_server.server import mcp, mcp_app
from routers.classify import router as classify_router
from routers.simulate import router as simulate_router
from services.classifier import ClassifierService
from services.simulator import SimulatorService


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Enter the MCP session manager for the lifetime of the host application.

    A mounted ASGI application's own lifespan does not run -- Starlette sends
    the lifespan scope to the outermost app only. So the session manager
    StreamableHTTPSessionManager.run() sets up is the host's responsibility, and
    without this every request to /mcp fails on the first call after a cold
    start with "Task group is not initialized".
    """
    async with mcp.session_manager.run():
        yield


app = FastAPI(
    title="Dairy Spoilage API",
    description=(
        "Milk spoilage classification (ML) and supply chain simulation (R model). "
        "Designed for LLM agent consumption."
    ),
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    max_age=3600,
)

app.include_router(classify_router)
app.include_router(simulate_router)

# FastMCP builds a Starlette application whose one route is the MCP endpoint.
# Register that route on this application rather than mounting the Starlette app
# around it: a Mount at /mcp matches /mcp/ only, and a client posting to /mcp --
# the URL the plugin's .mcp.json carries -- gets a 307 it may not follow.
# Registered after the routers, so nothing here can shadow an API route.
app.router.routes.extend(mcp_app.routes)

_classifier = ClassifierService()
_simulator = SimulatorService()


@app.get("/")
async def root():
    return {
        "service": "Dairy Spoilage API",
        "version": "1.0.0",
        "endpoints": {
            "classify": "/classify",
            "classify_batch": "/classify/batch",
            "variants": "/variants",
            "simulate": "/simulate",
            "scenarios": "/scenarios",
            "methods": "/simulate/methods",
            "health": "/health",
            "mcp": "/mcp",
            "docs": "/docs",
        },
    }


@app.get("/health")
async def health():
    # status must reflect BOTH halves of this service. It used to be derived
    # from the R runtime alone, so a deployment that had loaded none of its
    # classifier variants still answered "healthy" -- and since issue #7's
    # acceptance criterion is "confirm /health returns r_runtime: true", that
    # would have signed off a Space where every classification fails.
    r_ok = _simulator.check_r_runtime()
    classifier = _classifier.health()

    # `declared > 0 and not missing` is not sufficient on its own. A config that
    # never declares the default variant is internally consistent by that test --
    # declared equals loaded, nothing missing -- while every /classify and
    # /classify/batch call that names no variant returns 400, because both
    # default to it. Reproduced: dropping baseline from the config gave
    # {'declared': 9, 'loaded': 9, 'missing': []} and a healthy status beside a
    # 400 on the documented example request.
    classifier_ok = (
        classifier["declared"] > 0
        and not classifier["missing"]
        and classifier["default_loaded"]
    )

    return {
        "status": "healthy" if (r_ok and classifier_ok) else "degraded",
        # Not part of `status`: a deployment behind the repository is running
        # perfectly well, and only a caller holding the repository can tell that
        # it is stale. check_deployment.py is that caller.
        "build": build_info(),
        "r_runtime": r_ok,
        "classifier_models_loaded": classifier["loaded"],
        "classifier_models_declared": classifier["declared"],
        "classifier_missing": classifier["missing"],
        "classifier_default_variant": classifier["default_variant"],
        "classifier_default_loaded": classifier["default_loaded"],
        "classifier_classes": ["PPC", "no spoilage", "spore spoilage"],
    }
