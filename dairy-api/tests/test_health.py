"""Tests for /health.

These exist because /health twice reported a broken deployment as healthy
during PR #23. First `check_r_runtime()` ran `R -e "cat('ok')"`, which proves R
starts and nothing else, so an image built without lamW answered
`r_runtime: true` and every simulation failed. Then, with that fixed, `status`
was still derived from the R runtime alone, so a Space that had loaded none of
its classifier variants also answered healthy.

The endpoint is the deployment's own acceptance criterion -- issue #7 is
literally "confirm /health returns r_runtime: true on the Space" -- so a health
check that cannot fail makes the criterion worthless.
"""

import pytest
from httpx import ASGITransport, AsyncClient

from app import app
from services.classifier import ClassifierService


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest.mark.anyio
async def test_health_reports_every_declared_variant_loaded(client):
    r = await client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["classifier_models_declared"] == body["classifier_models_loaded"]
    assert body["classifier_missing"] == []


@pytest.mark.anyio
async def test_health_is_degraded_when_a_variant_is_missing(client, monkeypatch):
    # The failure this endpoint has to catch: the config declares variants that
    # were never loaded. Previously status came from the R runtime alone, so
    # this case reported healthy.
    import app as app_module

    real = app_module._classifier.health()
    monkeypatch.setattr(
        app_module._classifier,
        "health",
        lambda: {**real, "loaded": real["loaded"] - 1, "missing": ["scenario_5_day7"]},
    )

    body = (await client.get("/health")).json()
    assert body["status"] == "degraded"
    assert body["classifier_missing"] == ["scenario_5_day7"]


@pytest.mark.anyio
async def test_health_is_degraded_when_the_r_runtime_is_down(client, monkeypatch):
    import app as app_module

    monkeypatch.setattr(app_module._simulator, "check_r_runtime", lambda: False)

    body = (await client.get("/health")).json()
    assert body["status"] == "degraded"
    assert body["r_runtime"] is False


@pytest.mark.anyio
async def test_health_is_degraded_when_the_default_variant_is_undeclared(
    client, monkeypatch
):
    # The subtler failure, from PR #25 review. A config that never declares the
    # default variant is internally consistent -- declared equals loaded and
    # nothing is missing -- so a check built only on that comparison reports
    # healthy. Meanwhile /classify and /classify/batch both default to it and
    # return 400 for every request that names no variant.
    import app as app_module

    real = app_module._classifier.health()
    monkeypatch.setattr(
        app_module._classifier,
        "health",
        lambda: {**real, "declared": 9, "loaded": 9, "missing": [],
                 "default_loaded": False},
    )

    body = (await client.get("/health")).json()
    assert body["status"] == "degraded"
    assert body["classifier_default_loaded"] is False
    assert body["classifier_missing"] == []  # consistency is not usability


def test_the_routers_and_health_agree_on_the_default_variant():
    # /health asserts the default variant loaded; the routers decide what the
    # default IS. Were those two literals to drift apart, the health check would
    # guard a variant nothing actually requests.
    from routers.classify import ClassifyInput, BatchInput
    from services.classifier import DEFAULT_VARIANT

    assert ClassifyInput().model_variant == DEFAULT_VARIANT
    assert BatchInput(samples=[]).model_variant == DEFAULT_VARIANT
    assert ClassifierService().health()["default_variant"] == DEFAULT_VARIANT


def test_classifier_health_names_what_is_missing():
    # ClassifierService.health() is what /health reads. It must report the
    # declared set, not only what happened to load -- a service that loaded
    # nothing and a service with nothing declared are different failures.
    svc = ClassifierService()
    h = svc.health()
    assert h["declared"] > 0
    assert h["loaded"] == h["declared"]
    assert h["missing"] == []
