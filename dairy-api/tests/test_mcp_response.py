"""What the API's raw response becomes before an agent reads it.

The raw response is shaped for a program that already knows the API's
conventions -- that -1 means "past the horizon", that the dollars scale with
`n_units` and not with `n_lots`, that `pct_spoiled_at_retail` was read at a whole
day the caller has to find in another field. An agent does not know any of that,
and every convention it has to remember is one it can get wrong.

Pure, so it runs without a server or an R subprocess. The two fixtures below are
shaped like real /simulate responses; tests/test_mcp_tools.py checks a real one.
"""

from __future__ import annotations

import pytest

from mcp_server.facility import Facility, Run, plan
from mcp_server.response import Bound, reshape

RUN = Run(seed=42, lots=4, containers_per_lot=50, days=40)


def raw(**overrides) -> dict:
    """A /simulate response that finished inside the horizon."""
    body = {
        "spoilage_summary": [
            {"day": 7, "median_pct": 2.0, "mean_pct": 2.5, "sd": 1.1, "P5": 0.0, "P95": 6.0},
            {"day": 14, "median_pct": 60.0, "mean_pct": 58.0, "sd": 9.0, "P5": 40.0, "P95": 80.0},
        ],
        "daily_spoilage": [
            {"day": d, "median_pct": float(d), "P25": 0.0, "P75": float(d) * 2}
            for d in range(0, 41)
        ],
        "shelf_life": {
            "total_days": 12,
            "consumer_days": 3.7,
            "pre_consumer_days": 8.3,
            "pre_consumer_day": 8,
            "threshold_pct": 25,
        },
        "economics": {
            "shelf_life_value_usd": 5.63,
            "pct_spoiled_at_retail": 8.0,
            "co2e_kg": 12.5,
        },
        "plot": "data:image/png;base64," + "A" * 40000,
        "warnings": [],
        "scenario": {"interventions_applied": {}, "disruptions_applied": {}},
    }
    body.update(overrides)
    return body


def truncated_raw() -> dict:
    """A run whose lot never crossed the criterion inside the horizon."""
    return raw(
        shelf_life={
            "total_days": -1,
            "consumer_days": -1,
            "pre_consumer_days": 8.3,
            "pre_consumer_day": 8,
            "threshold_pct": 25,
        },
        economics={
            "shelf_life_value_usd": 0,
            "pct_spoiled_at_retail": 4.0,
            "co2e_kg": 9.0,
        },
    )


def out(body: dict, facility: Facility | None = None, run: Run = RUN):
    return reshape(body, plan(run, facility))


# ---------------------------------------------------------------------------
# Shelf life — a number, or a bound, never a bare -1
# ---------------------------------------------------------------------------

def test_a_finished_run_returns_shelf_life_as_numbers():
    life = out(raw()).shelf_life
    assert life.total_days == 12
    assert life.consumer_days == 3.7
    assert life.truncated is False
    assert life.horizon_days == 40


def test_a_truncated_run_returns_a_bound_rather_than_minus_one():
    """-1 read as a number is a shelf life of minus one day."""
    life = out(truncated_raw()).shelf_life
    assert isinstance(life.total_days, Bound)
    assert life.total_days.more_than_days == 40
    assert life.truncated is True


def test_the_two_bounds_do_not_share_one_number():
    """consumer_days is bounded by the horizon LESS the supply-chain window."""
    life = out(truncated_raw()).shelf_life
    assert isinstance(life.consumer_days, Bound)
    assert life.consumer_days.more_than_days == pytest.approx(40 - 8.3)


def test_a_shorter_horizon_moves_both_bounds():
    short = Run(seed=42, lots=4, containers_per_lot=50, days=20)
    life = out(truncated_raw(), run=short).shelf_life
    assert life.total_days.more_than_days == 20
    assert life.consumer_days.more_than_days == pytest.approx(20 - 8.3)


def test_a_horizon_shorter_than_the_supply_chain_does_not_bound_below_zero():
    """"More than -4.3 days at the consumer" is not a bound.

    The run ended before the product reached a consumer at all, and the note for
    that case is what carries the meaning.
    """
    four_days = Run(seed=42, lots=4, containers_per_lot=50, days=4)
    life = out(truncated_raw(), run=four_days).shelf_life
    assert life.consumer_days.more_than_days == 0


def test_a_truncated_run_says_its_dollar_figure_is_a_placeholder():
    """The run reports $0, not "unknown" -- and the better the plant, the likelier it is."""
    result = out(truncated_raw())
    assert result.economics.shelf_life_value_usd == 0
    assert any("0" in note and "horizon" in note for note in result.notes)


# ---------------------------------------------------------------------------
# Economics — per container, because n_lots enters neither figure
# ---------------------------------------------------------------------------

def test_economics_returns_per_container_figures_beside_the_totals():
    economics = out(raw()).economics
    assert economics.shelf_life_value_usd == 5.63
    assert economics.shelf_life_value_usd_per_container == pytest.approx(5.63 / 50)
    assert economics.co2e_kg == 12.5
    assert economics.co2e_kg_per_container == pytest.approx(12.5 / 50)
    assert economics.containers_priced == 50


def test_the_raw_figures_scale_with_containers_and_the_per_container_ones_do_not():
    """Raising n_units for a steadier estimate must not double the reported benefit."""
    fifty = out(raw()).economics
    hundred = out(
        raw(economics={"shelf_life_value_usd": 11.26, "pct_spoiled_at_retail": 8.0, "co2e_kg": 25.0}),
        run=Run(seed=42, lots=4, containers_per_lot=100, days=40),
    ).economics
    assert hundred.shelf_life_value_usd == 2 * fifty.shelf_life_value_usd
    assert hundred.shelf_life_value_usd_per_container == pytest.approx(
        fifty.shelf_life_value_usd_per_container
    )


# ---------------------------------------------------------------------------
# Retail exit — the figure with the day it was read at
# ---------------------------------------------------------------------------

def test_retail_spoilage_returns_with_the_day_it_was_evaluated_on():
    retail = out(raw()).economics.pct_spoiled_at_retail
    assert retail.percent == 8.0
    assert retail.evaluated_on_day == 8
    assert retail.measured is True


def test_retail_spoilage_past_the_horizon_is_not_reported_as_clean_product():
    """The run reports 0 as a placeholder when it has no daily result to read."""
    result = out(
        raw(
            shelf_life={
                "total_days": -1,
                "consumer_days": -1,
                "pre_consumer_days": 44.0,
                "pre_consumer_day": 44,
                "threshold_pct": 25,
            },
            economics={"shelf_life_value_usd": 0, "pct_spoiled_at_retail": 0, "co2e_kg": 0},
        )
    )
    retail = result.economics.pct_spoiled_at_retail
    assert retail.measured is False
    assert retail.percent is None
    assert any("before the product reached the consumer" in n for n in result.notes)


def test_inside_the_horizon_retail_spoilage_is_the_daily_row_at_that_day():
    """Routes 2 and 3 tell the agent the two are one number, so they must agree."""
    result = out(raw())
    day = result.economics.pct_spoiled_at_retail.evaluated_on_day
    row = next(r for r in result.daily_spoilage if r.day == day)
    assert row.median_pct == result.economics.pct_spoiled_at_retail.percent


# ---------------------------------------------------------------------------
# The series, and the field that is not worth an agent's context
# ---------------------------------------------------------------------------

def test_the_reshaped_response_carries_the_daily_series():
    result = out(raw())
    assert [row.day for row in result.daily_spoilage] == list(range(0, 41))
    assert result.daily_spoilage[8].P25 is not None


def test_the_lot_spread_view_survives_with_its_own_days():
    summary = out(raw()).spoilage_summary
    assert [row.day for row in summary] == [7, 14]
    assert summary[1].P95 == 80.0


def test_the_base64_plot_is_dropped():
    """40 KB of base64 an agent cannot display, on every call."""
    assert "plot" not in out(raw()).model_dump()


# ---------------------------------------------------------------------------
# The comparability verdict, so the agent stops deciding it
# ---------------------------------------------------------------------------

def test_a_baseline_run_is_comparable_at_retail_exit():
    verdict = out(raw()).comparability
    assert verdict.pct_spoiled_at_retail_comparable is True
    assert verdict.pre_consumer_duration_changed is False


def test_a_scenario_that_lengthens_a_pre_consumer_stage_is_not():
    result = out(raw(), Facility(stage_durations={"retail": 8.0}))
    verdict = result.comparability
    assert verdict.pct_spoiled_at_retail_comparable is False
    assert verdict.stages_changed == ["retail"]
    assert "daily_spoilage" in verdict.verdict


def test_a_consumer_stage_change_leaves_the_comparison_intact():
    verdict = out(raw(), Facility(stage_durations={"consumer": 20.0})).comparability
    assert verdict.pct_spoiled_at_retail_comparable is True


def test_a_temperature_only_scenario_leaves_the_comparison_intact():
    verdict = out(raw(), Facility(stage_temperatures={"retail": {"shift": 2.0}})).comparability
    assert verdict.pct_spoiled_at_retail_comparable is True


# ---------------------------------------------------------------------------
# What the run was actually configured with
# ---------------------------------------------------------------------------

def test_every_response_echoes_the_seed_and_the_run_size():
    scenario = out(raw()).scenario
    assert scenario.seed == 42
    assert scenario.lots == 4
    assert scenario.containers_per_lot == 50
    assert scenario.horizon_days == 40


def test_the_response_states_the_published_band_the_category_resolved_to():
    """ADR 012: state the number rather than hide it behind a name."""
    scenario = out(raw(), Facility(plant_category="long")).scenario
    assert scenario.ppc_frequency_range == (0.125, 0.294)
    assert "long" in scenario.ppc_frequency_source


def test_the_applied_records_come_through_from_the_run():
    applied = {
        "interventions_applied": {"stage_temp_overrides": {"retail": {"temp_delta": -2.5}}},
        "disruptions_applied": {"consumer": {"type": "delay", "duration_delta": 1, "temp": 9}},
    }
    scenario = out(raw(scenario=applied)).scenario
    assert scenario.interventions_applied == applied["interventions_applied"]
    assert scenario.disruptions_applied == applied["disruptions_applied"]


def test_warnings_come_through_untouched():
    result = out(raw(warnings=["PPC solves terminated early; treat these results as suspect"]))
    assert result.warnings == [
        "PPC solves terminated early; treat these results as suspect"
    ]


def test_one_warning_is_still_a_list():
    """toJSON(auto_unbox = TRUE) unboxes a length-one character vector.

    So one warning arrives as a bare string and two arrive as an array. Route 2
    tells the agent to read `warnings` as a list either way.
    """
    assert out(raw(warnings="Total supply chain duration exceeds sim_duration")).warnings == [
        "Total supply chain duration exceeds sim_duration"
    ]


def test_an_empty_applied_record_is_an_object_not_an_array():
    """R writes an empty named list as [], which is not what the schema promises."""
    scenario = out(
        raw(scenario={"interventions_applied": [], "disruptions_applied": []})
    ).scenario
    assert scenario.interventions_applied == {}
    assert scenario.disruptions_applied == {}


def test_the_notes_the_mapping_produced_reach_the_response():
    result = out(raw(), Facility(stage_temperatures={"retail": {"shift": -2.5}}))
    assert any("within-stage" in note for note in result.notes)
