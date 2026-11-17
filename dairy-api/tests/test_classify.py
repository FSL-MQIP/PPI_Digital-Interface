"""Tests for classification endpoints."""

import pytest
from httpx import ASGITransport, AsyncClient

from app import app
from routers.classify import ClassifyInput
from services.classifier import MAX_LOG10_COUNT

FULL_FEATURES = {
    "spc_d7": 2.1,
    "spc_d14": 4.7,
    "spc_d21": 6.4,
    "tgn_d7": 1.0,
    "tgn_d14": 3.7,
    "tgn_d21": 5.3,
}


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest.mark.anyio
async def test_classify_single(client):
    """POST /classify with full features returns 200 with expected keys."""
    payload = {**FULL_FEATURES, "model_variant": "baseline"}
    resp = await client.post("/classify", json=payload)
    assert resp.status_code == 200
    data = resp.json()
    assert "prediction" in data
    assert "probabilities" in data
    assert "confidence" in data
    assert "variant_used" in data
    # prediction must be one of the three classes
    assert data["prediction"] in ("PPC", "no spoilage", "spore spoilage")
    # probabilities must have all three classes
    assert len(data["probabilities"]) == 3
    # confidence between 0 and 1
    assert 0.0 <= data["confidence"] <= 1.0


@pytest.mark.anyio
async def test_classify_batch(client):
    """POST /classify/batch with 2 samples returns predictions + summary."""
    payload = {
        "samples": [
            {**FULL_FEATURES},
            {**FULL_FEATURES, "spc_d21": 3.0, "tgn_d21": 1.5},
        ],
        "model_variant": "baseline",
    }
    resp = await client.post("/classify/batch", json=payload)
    assert resp.status_code == 200
    data = resp.json()
    assert "predictions" in data
    assert "summary" in data
    assert len(data["predictions"]) == 2
    summary = data["summary"]
    assert summary["total"] == 2
    assert "ppc_count" in summary
    assert "non_ppc_count" in summary
    assert "ppc_prevalence" in summary
    assert 0.0 <= summary["ppc_prevalence"] <= 1.0


@pytest.mark.anyio
async def test_variants(client):
    """GET /variants returns all 10 model variants."""
    resp = await client.get("/variants")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total_variants"] == 10
    assert len(data["variants"]) == 10


@pytest.mark.anyio
async def test_classify_missing_features(client):
    """POST /classify with only spc_d7 for baseline variant returns 400."""
    payload = {"spc_d7": 2.1, "model_variant": "baseline"}
    resp = await client.post("/classify", json=payload)
    assert resp.status_code == 400
    assert "Missing required features" in resp.json()["detail"]


@pytest.mark.anyio
async def test_classify_bad_variant(client):
    """POST /classify with nonexistent variant returns 400."""
    payload = {**FULL_FEATURES, "model_variant": "nonexistent"}
    resp = await client.post("/classify", json=payload)
    assert resp.status_code == 400
    assert "Unknown variant" in resp.json()["detail"]


# A raw plate count entered where its logarithm belongs. `classify_sample`
# computes `10 ** value`, so 4700000 raises OverflowError, which neither
# endpoint catches -- it escaped as an HTTP 500 naming nothing.
RAW_PLATE_COUNTS = {
    "spc_d7": 2100000,
    "spc_d14": 4700000,
    "spc_d21": 6400000,
    "tgn_d7": 1000,
    "tgn_d14": 3700000,
    "tgn_d21": 5300000,
}


@pytest.mark.anyio
async def test_classify_raw_plate_count_is_rejected(client):
    """POST /classify with raw counts returns 422 naming the offending field."""
    payload = {**RAW_PLATE_COUNTS, "model_variant": "baseline"}
    resp = await client.post("/classify", json=payload)
    assert resp.status_code == 422
    named = {tuple(err["loc"])[-1] for err in resp.json()["detail"]}
    assert "spc_d14" in named


@pytest.mark.anyio
async def test_classify_one_raw_count_among_logs_is_rejected(client):
    """One field out of unit is enough: the response names that field only."""
    payload = {**FULL_FEATURES, "spc_d14": 4700000, "model_variant": "baseline"}
    resp = await client.post("/classify", json=payload)
    assert resp.status_code == 422
    named = {tuple(err["loc"])[-1] for err in resp.json()["detail"]}
    assert named == {"spc_d14"}


@pytest.mark.anyio
async def test_classify_batch_raw_plate_count_is_rejected(client):
    """The batch endpoint bounds each sample, and names the sample and the field."""
    payload = {
        "samples": [{**FULL_FEATURES}, {**FULL_FEATURES, "spc_d14": 4700000}],
        "model_variant": "baseline",
    }
    resp = await client.post("/classify/batch", json=payload)
    assert resp.status_code == 422
    locations = {tuple(err["loc"]) for err in resp.json()["detail"]}
    assert ("body", "samples", 1, "spc_d14") in locations


@pytest.mark.anyio
async def test_classify_accepts_the_whole_measurable_range(client):
    """The bound rejects raw counts without rejecting anything a lab can measure."""
    payload = {
        **{field: MAX_LOG10_COUNT for field in FULL_FEATURES},
        "model_variant": "baseline",
    }
    resp = await client.post("/classify", json=payload)
    assert resp.status_code == 200


def test_the_endpoint_and_the_tool_share_one_bound():
    """The tool schema's bound is the endpoint's bound, not a second copy.

    Two literals would drift, and the drift is invisible: the tool would keep
    rejecting a raw count while the endpoint behind it went back to a 500.
    """
    from mcp_server.server import MAX_LOG10_COUNT as tool_bound

    assert tool_bound is MAX_LOG10_COUNT
    for field in FULL_FEATURES:
        schema = ClassifyInput.model_json_schema()["properties"][field]
        numeric = [b for b in schema["anyOf"] if b.get("type") == "number"][0]
        assert numeric["maximum"] == MAX_LOG10_COUNT
        assert numeric["minimum"] == 0
