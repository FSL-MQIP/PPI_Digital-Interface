import pytest
from httpx import AsyncClient, ASGITransport
from app import app


@pytest.fixture
def client():
    transport = ASGITransport(app=app)
    return AsyncClient(transport=transport, base_url="http://test")


@pytest.mark.asyncio
async def test_simulate_baseline(client):
    resp = await client.post("/simulate", json={"seed": 42}, timeout=120)
    assert resp.status_code == 200
    data = resp.json()
    assert "spoilage_summary" in data
    assert "shelf_life" in data
    assert "economics" in data
    assert "plot" in data
    assert len(data["spoilage_summary"]) == 5  # days 7,14,21,28,35
    assert data["shelf_life"]["total_days"] > 0
    assert data["economics"]["shelf_life_value_usd"] >= 0
    assert data["plot"].startswith("data:image/png;base64,")


@pytest.mark.asyncio
async def test_simulate_returns_the_daily_spoilage_series(client):
    """ADR 012 reads the comparison at the baseline's pre-consumer day.

    `spoilage_summary` cannot serve that. Its days come from `config$output_days`,
    which no request key reaches, and the shipped supply chain exits retail at
    8.25 days -- a day that set never reports. So the response carries the daily
    series `run_model()` already builds for the shelf-life calculation.
    """
    # n_units = 3 deliberately: a lot's percentage is 100 * spoiled / n_units, so
    # a divisor of 100 always terminates and hides a rounding mismatch between
    # daily_spoilage and economics.pct_spoiled_at_retail. 3 gives 33.3333...
    resp = await client.post("/simulate", json={
        "config": {"n_lots": 2, "n_units": 3, "sim_duration": 12},
        "seed": 42,
    }, timeout=300)
    assert resp.status_code == 200
    data = resp.json()

    rows = {row["day"]: row for row in data["daily_spoilage"]}
    assert sorted(rows) == list(range(0, 13)), "every simulated day must be present"

    # The day the comparison is read at, and a day `spoilage_summary` skips.
    # Read it off the response rather than flooring `pre_consumer_days`: the run
    # floors full precision and the response rounds to one decimal, so 8.9546 d
    # comes back as 9.0 and flooring gives the wrong day.
    pre_consumer_day = data["shelf_life"]["pre_consumer_day"]
    assert pre_consumer_day in rows
    assert pre_consumer_day not in {row["day"] for row in data["spoilage_summary"]}

    # That day is where the run reads pct_spoiled_at_retail, off this same
    # series -- so inside the horizon the two are one number, not two. Exact
    # equality, not approx: routes 2 and 3 promise the agent one number, and
    # approx would pass while the response carried 33.3333... against 33.33.
    assert pre_consumer_day <= 12, "this assertion holds in-horizon only"
    assert (
        rows[pre_consumer_day]["median_pct"]
        == data["economics"]["pct_spoiled_at_retail"]
    )

    # quantile() names its result "25%" / "75%", and a named value serialises as
    # an object rather than a number if the name survives to toJSON.
    for field in ("median_pct", "P25", "P75"):
        value = rows[pre_consumer_day][field]
        assert isinstance(value, (int, float)), f"{field} came back as {value!r}"


@pytest.mark.asyncio
async def test_a_horizon_shorter_than_the_first_output_day_still_answers(client):
    """`spoilage_summary` reports days 7, 14, 21, 28 and 35 and drops what the run
    never reached, so a horizon under 7 leaves it empty.

    The bridge built its rows with `1:nrow()`, and `1:0` counts DOWN to c(1, 0) --
    so it indexed row 1 of an empty frame and round(row$sd, 2) died on the NULL.
    Measured before the fix: sim_duration = 4 returned HTTP 500.
    """
    resp = await client.post("/simulate", json={
        "config": {"n_lots": 2, "n_units": 3, "sim_duration": 4},
        "seed": 42,
    }, timeout=300)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["spoilage_summary"] == []
    assert [row["day"] for row in data["daily_spoilage"]] == list(range(0, 5))


@pytest.mark.asyncio
async def test_simulate_with_intervention(client):
    resp = await client.post("/simulate", json={
        "interventions": {"spore_reduction": "microfiltration"},
        "seed": 42,
    }, timeout=120)
    assert resp.status_code == 200
    data = resp.json()
    assert data["scenario"]["interventions_applied"]["spore_reduction"] == "microfiltration"


@pytest.mark.asyncio
async def test_scenarios_list(client):
    resp = await client.get("/scenarios")
    assert resp.status_code == 200
    data = resp.json()
    assert "interventions" in data
    assert "disruptions" in data
    assert "s1_cooling_failure" in data["disruptions"]["presets"]


@pytest.mark.asyncio
async def test_simulate_methods(client):
    resp = await client.get("/simulate/methods")
    assert resp.status_code == 200
    data = resp.json()
    assert "Lau" in data["methods"]
    assert "WARM" in data["methods"]


@pytest.mark.asyncio
async def test_health_checks_both_runtimes(client):
    resp = await client.get("/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] in ("healthy", "degraded")
    assert "r_runtime" in data
    assert "classifier_models_loaded" in data
    assert data["classifier_models_loaded"] == 10


# --- Disruption validation -------------------------------------------------
# These reject at the Pydantic layer, so no R subprocess runs and they are fast.


@pytest.mark.asyncio
async def test_profile_csv_disruption_is_rejected(client):
    """profile_csv hands its `path` to read.csv, so the API must not accept it."""
    resp = await client.post("/simulate", json={
        "disruptions": {"retail": {"type": "profile_csv", "path": "/etc/passwd"}},
        "seed": 42,
    })
    assert resp.status_code == 422
    assert "profile_csv" in resp.text
    # The caller is told where the measured traces actually live.
    assert "preset" in resp.text


@pytest.mark.asyncio
async def test_unknown_disruption_type_is_rejected(client):
    resp = await client.post("/simulate", json={
        "disruptions": {"retail": {"type": "teleport", "temp": 20}},
        "seed": 42,
    })
    assert resp.status_code == 422
    assert "teleport" in resp.text


@pytest.mark.asyncio
async def test_missing_disruption_type_is_rejected(client):
    resp = await client.post("/simulate", json={
        "disruptions": {"retail": {"temp": 20, "duration": 0.5}},
        "seed": 42,
    })
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_non_object_disruption_is_rejected(client):
    resp = await client.post("/simulate", json={
        "disruptions": {"retail": "s1_cooling_failure"},
        "seed": 42,
    })
    assert resp.status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize("spec", [
    {"type": "temp_spike", "temp": 20, "duration": 0.25},
    {"type": "delay", "duration_delta": 0.5, "temp": 15},
    {"type": "temp_shift", "temp_delta": 2},
    {"type": "preset", "name": "s1_cooling_failure"},
])
async def test_supported_disruption_types_pass_validation(client, spec):
    """The four served types must survive the validator.

    A 422 here means the validator rejected the body. Any other status means it
    reached the model, which is what this test is checking for.
    """
    resp = await client.post("/simulate", json={
        "disruptions": {"processing_facility": spec}, "seed": 42,
    }, timeout=180)
    assert resp.status_code != 422, resp.text


@pytest.mark.asyncio
async def test_r_failure_does_not_leak_stderr(client, monkeypatch):
    """A failed run must not return the R subprocess's stderr to the caller."""
    from routers import simulate as simulate_router

    secret = "/app/r_bridge/run_simulation.R:149 could not find function 'foo'"

    def boom(**kwargs):
        raise RuntimeError(f"R simulation failed: {secret}")

    monkeypatch.setattr(simulate_router.simulator, "run", boom)

    resp = await client.post("/simulate", json={"seed": 42})
    assert resp.status_code == 500
    assert secret not in resp.text
    assert "run_simulation.R" not in resp.text
