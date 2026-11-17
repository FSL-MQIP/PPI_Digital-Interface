"""The skill harness: every procedure in plugin/skills/milk-spoilage, executed.

Issue #33. Two halves, and they fail differently:

- The **pure half** imports the client modules behind the tools and runs with
  no API, no R runtime, no network and no assembled build context -- so it is
  available in a worktree at exactly the moment a route file is being edited,
  which dairy-api/tests is not (its conftest imports `app`).

- The **live half** executes the procedures over a real MCP client against a
  named target. It runs only when a target is given, and it pins the target
  first: a stale deployment fails the whole half rather than certifying prose
  against code nobody is running (issues #38 and #42).

Run it:

    python -m pytest dairy-api/skill_harness                      # pure half
    python -m pytest dairy-api/skill_harness --skill-target local
    python -m pytest dairy-api/skill_harness --skill-target https://chenhaoq87-dairy-spoilage-api.hf.space

`local` serves this checkout in-process, which pins it by construction. A URL
is pinned by comparing its /health payload digest against this checkout's --
which needs the build context assembled (`bash dairy-api/build.sh`).
"""

from __future__ import annotations

import os
import sys
import threading
import time
from pathlib import Path

import pytest

_API = Path(__file__).resolve().parents[1]
if str(_API) not in sys.path:
    sys.path.insert(0, str(_API))

from skill_harness import live  # noqa: E402  (needs the path above)


def pytest_addoption(parser):
    parser.addoption(
        "--skill-target",
        default=os.environ.get("SKILL_TARGET"),
        help=(
            "Where the live half runs: 'local' for an in-process server from "
            "this checkout, or a base URL pinned via its /health payload "
            "digest. Absent, the live half is skipped."
        ),
    )


def pytest_report_header(config):
    choice = config.getoption("--skill-target")
    if not choice:
        return "skill harness target: none (pure half only; live procedures skip)"
    return f"skill harness target: {choice}"


def _local_server():
    """This checkout, served in-process. Pinned to the repository by construction.

    A deliberate twin of dairy-api/tests/conftest.py's live_server: that
    conftest imports `app` at module level, so sharing it would cost this
    harness the run-anywhere property its pure half exists for.
    """
    import uvicorn

    from app import app  # imported lazily: the pure half must not need it

    class _Server(uvicorn.Server):
        def install_signal_handlers(self) -> None:
            """No-op: the server runs off the main thread, where signals do not land."""

    config = uvicorn.Config(app, host="127.0.0.1", port=0, log_level="warning")
    server = _Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()

    deadline = time.monotonic() + 60
    while not server.started:
        if not thread.is_alive():
            raise RuntimeError("the in-process server exited during startup")
        if time.monotonic() > deadline:
            raise RuntimeError("the in-process server did not start within 60s")
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


def _normalized(path: Path) -> bytes:
    return path.read_bytes().replace(b"\r\n", b"\n")


def _stale_assembly() -> list[str]:
    """Guidance whose assembled copy differs from the source tree it came from.

    The digest hashes the *assembled* build context, so an edited route file
    with a stale `dairy-api/guidance/` matches a Space that is stale the same
    way -- the pin would compare two identical stale things and pass. Found by
    running exactly that: a route-file edit, no rebuild, and a green pin
    against a deployment serving the old sentence.

    An absent `dairy-api/guidance/` is fine: read_guidance then falls back to
    the source trees themselves, which cannot be stale.
    """
    if not (_API / "guidance").is_dir():
        return []
    repo = _API.parent
    pairs = [
        (repo / "plugin" / "skills" / "milk-spoilage" / "routes",
         _API / "guidance" / "routes"),
        (repo / "docs" / "reference", _API / "guidance" / "reference"),
    ]
    stale = []
    for source_dir, assembled_dir in pairs:
        for source in sorted(source_dir.glob("*.md")):
            assembled = assembled_dir / source.name
            if not assembled.is_file() or _normalized(assembled) != _normalized(source):
                stale.append(source.relative_to(repo).as_posix())
    return stale


def _pinned(url: str) -> str:
    """A remote target, allowed only once it is shown to be this checkout.

    The digest is the same one check_deployment.py compares after a deploy. A
    target that reports none cannot be shown to be anything, which for this
    harness is the same failure as being stale: a green run would certify the
    route files against code nobody can identify.
    """
    import httpx

    from payload import CONTEXT, digest

    url = url.rstrip("/")
    if not (CONTEXT / "models" / "variants").is_dir():
        pytest.fail(
            "No build context to pin the target against. Run "
            "`bash dairy-api/build.sh` first, or use --skill-target local.",
            pytrace=False,
        )
    try:
        health = httpx.get(f"{url}/health", timeout=120).json()
    except Exception as exc:  # noqa: BLE001 -- any failure here fails the pin
        pytest.fail(f"{url}/health did not answer, so the target cannot be "
                    f"pinned: {exc}", pytrace=False)

    deployed = (health.get("build") or {}).get("payload_digest")
    local = digest(CONTEXT)
    if deployed is None:
        pytest.fail(
            f"{url} reports no payload digest, so it cannot be shown to be "
            "this checkout. Redeploy it, or serve this checkout with "
            "--skill-target local.",
            pytrace=False,
        )
    if deployed != local:
        pytest.fail(
            f"{url} is stale relative to this repository.\n"
            f"  deployed: {deployed}\n"
            f"  local:    {local}\n"
            "A green run against it would certify the route files against "
            "code nobody is running. Redeploy, or check out the commit it is "
            "running.",
            pytrace=False,
        )
    return url


@pytest.fixture(scope="session")
def target(request):
    """The named, pinned target the live half runs against."""
    choice = request.config.getoption("--skill-target")
    if not choice:
        pytest.skip(
            "live procedure: needs --skill-target (local, or a base URL)"
        )
    stale = _stale_assembly()
    if stale:
        pytest.fail(
            "The assembled build context is stale relative to the repository, "
            "so any target would serve or pin against old guidance. Run "
            "`bash dairy-api/build.sh`, then re-run. Stale: " + ", ".join(stale),
            pytrace=False,
        )
    if choice == "local":
        yield from _local_server()
    else:
        yield _pinned(choice)


# ---------------------------------------------------------------------------
# The expensive runs, shared across tests. Each is one real simulation; every
# response field a route file names is asserted somewhere against these.
#
# Seeds: the route files' measured examples say "same seed" without naming it,
# and they come from two measurement sessions. ADR 012's tables -- route 4's
# gate rows and route 3's 6.06 kg CO2e -- reproduce at seed 7; issue #32's
# retail-exit example (18 and 37 at day 8) reproduces at seed 42. Both were
# recovered by sweeping seeds against the current model, so a failure below
# means the model moved, not that the example was never reproducible.
# ---------------------------------------------------------------------------

RUN_4x50x20 = {"seed": 42, "lots": 4, "containers_per_lot": 50, "days": 20}
RUN_4x50x40 = {"seed": 42, "lots": 4, "containers_per_lot": 50, "days": 40}
ADR012_RUN = {"seed": 7, "lots": 4, "containers_per_lot": 50, "days": 40}


def synthetic_raw(**overrides):
    """A /simulate response shaped like the bridge's, for pure reshaping checks."""
    raw = {
        "shelf_life": {
            "total_days": 12.0,
            "consumer_days": 3.7,
            "pre_consumer_days": 8.3,
            "pre_consumer_day": 8,
            "threshold_pct": 25,
        },
        "economics": {
            "shelf_life_value_usd": 16.12,
            "co2e_kg": 6.06,
            "pct_spoiled_at_retail": 18.0,
        },
        "daily_spoilage": [],
        "spoilage_summary": [],
        "scenario": {"interventions_applied": [], "disruptions_applied": []},
        "warnings": [],
    }
    for key, value in overrides.items():
        if isinstance(value, dict):
            raw[key] = {**raw[key], **value}
        else:
            raw[key] = value
    return raw


@pytest.fixture(scope="session")
def default_medium(target):
    """Route 2's own worked call, at the shipped defaults."""
    return live.call(
        target, "predict_default", {"run": {"seed": 42}, "plant_category": "medium"}
    )


@pytest.fixture(scope="session")
def long20_baseline(target):
    """Route 3's truncation example, baseline."""
    return live.call(
        target, "predict_default", {"run": RUN_4x50x20, "plant_category": "long"}
    )


@pytest.fixture(scope="session")
def long20_micro(target):
    """Route 3's truncation example, microfiltration run."""
    return live.call(
        target,
        "model_an_intervention",
        {
            "run": RUN_4x50x20,
            "intervention": {"reduce_spores": "microfiltration"},
            "facility": {"plant_category": "long"},
        },
    )


@pytest.fixture(scope="session")
def med40_baseline(target):
    """Issue #32's retail-exit example, baseline."""
    return live.call(target, "predict_default", {"run": RUN_4x50x40})


@pytest.fixture(scope="session")
def adr012_medium_baseline(target):
    """Route 4's masked-lever example, medium baseline (ADR 012, seed 7)."""
    return live.call(target, "predict_default", {"run": ADR012_RUN})


@pytest.fixture(scope="session")
def adr012_medium_micro(target):
    """Route 4's masked-lever example, medium microfiltration run."""
    return live.call(
        target,
        "model_an_intervention",
        {"run": ADR012_RUN, "intervention": {"reduce_spores": "microfiltration"}},
    )


@pytest.fixture(scope="session")
def adr012_long_baseline(target):
    """Route 4's long-plant example, baseline (ADR 012, seed 7)."""
    return live.call(
        target, "predict_default", {"run": ADR012_RUN, "plant_category": "long"}
    )


@pytest.fixture(scope="session")
def adr012_long_micro(target):
    """Route 4's long-plant example, microfiltration run."""
    return live.call(
        target,
        "model_an_intervention",
        {
            "run": ADR012_RUN,
            "intervention": {"reduce_spores": "microfiltration"},
            "facility": {"plant_category": "long"},
        },
    )


@pytest.fixture(scope="session")
def med40_retail_warm(target):
    """Route 3's retail-exit example: retail stated 3 C above baseline."""
    return live.call(
        target,
        "predict_customize",
        {
            "run": RUN_4x50x40,
            "facility": {"stage_temperatures": {"retail": {"shift": 3}}},
        },
    )
