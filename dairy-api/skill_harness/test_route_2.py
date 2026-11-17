"""Route 2 -- shelf-life prediction: the call, the PPC frequency, the read.

Route 2 owns the prediction call and how to read its result; routes 3, 4 and 5
all run through it. So this file carries the largest share of the harness: the
band resolution rules, the facility mapping, the two spoilage criteria, and
every response field the fields table names.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from mcp_server.facility import (
    _SECONDS_PER_CONTAINER_DAY,
    Facility,
    Run,
    StageTemperature,
    plan,
)
from mcp_server.response import Bound, reshape
from mcp_server.supply_chain import (
    BASELINE,
    DEFAULT_PLANT_CATEGORY,
    PPC_BANDS,
    STAGES,
    category_for_prevalence,
)
from skill_harness import live
from skill_harness.claims import claim
from skill_harness.conftest import synthetic_raw

DOC = "routes/2-shelf-life-prediction.md"

RUN = Run(seed=42)


# ---------------------------------------------------------------------------
# Step 1 -- the PPC frequency
# ---------------------------------------------------------------------------

def test_the_three_categories_and_the_shipped_default():
    with claim(DOC, "| `long` | 0–33% of lots come back PPC-positive |"):
        assert category_for_prevalence(0.0) == "long"
        assert category_for_prevalence(0.33) == "long"
    with claim(DOC, "| `medium` | 34–66% — **the shipped default** |"):
        assert category_for_prevalence(0.34) == "medium"
        assert category_for_prevalence(0.66) == "medium"
        assert DEFAULT_PLANT_CATEGORY == "medium"
        assert plan(RUN).ppc_frequency_range == PPC_BANDS["medium"]
        assert "shipped default" in plan(RUN).ppc_frequency_source
    with claim(DOC, "| `short` | 67–100% |"):
        assert category_for_prevalence(0.67) == "short"
        assert category_for_prevalence(1.0) == "short"


def test_the_resolved_band_comes_back_in_scenario():
    with claim(
        DOC,
        "**The band a category resolves to comes back in the response**, as "
        "`scenario.ppc_frequency_range` with `scenario.ppc_frequency_source` "
        "saying where it came from.",
    ):
        request = plan(RUN, Facility(plant_category="long"))
        assert request.ppc_frequency_range == PPC_BANDS["long"]
        assert "long" in request.ppc_frequency_source
        prediction = reshape(synthetic_raw(), request)
        assert prediction.scenario.ppc_frequency_range == PPC_BANDS["long"]
        assert prediction.scenario.ppc_frequency_source == request.ppc_frequency_source


def test_observed_ppc_is_a_proportion_never_a_percentage():
    with claim(
        DOC,
        "`facility.observed_ppc` takes **one proportion per lot** — a lot that "
        "came back 45% PPC is `0.45`, never `45`.",
    ):
        Facility(observed_ppc=[0.45])
        with pytest.raises(ValidationError):
            Facility(observed_ppc=[45])


def test_a_disagreeing_range_across_lots_beats_the_band():
    with claim(
        DOC,
        "The tool prefers a range observed across two or more lots that "
        "disagree, because that is the facility-specific input Su et al. "
        "explicitly sanction, and falls back to the published band otherwise.",
    ):
        ranged = plan(RUN, Facility(observed_ppc=[0.2, 0.5]))
        assert ranged.ppc_frequency_range == (0.2, 0.5)
        assert "sanction" in ranged.ppc_frequency_source

        single = plan(RUN, Facility(observed_ppc=[0.5]))
        assert single.ppc_frequency_range == PPC_BANDS["medium"]
        assert "one lot cannot place a facility" in single.ppc_frequency_source

        agreeing = plan(RUN, Facility(observed_ppc=[0.4, 0.4]))
        assert agreeing.ppc_frequency_range == PPC_BANDS["medium"]
        assert "collapsed to a point" in agreeing.ppc_frequency_source


def test_a_stated_category_beats_the_category_a_lot_implies():
    with claim(
        DOC,
        "**Two judgements stay yours.** The tool prefers a stated "
        "`plant_category` over the category an observation implies, and it "
        "never sees how many samples a lot carried.",
    ):
        request = plan(RUN, Facility(observed_ppc=[0.8], plant_category="medium"))
        assert request.ppc_frequency_range == PPC_BANDS["medium"]
        assert "short" in request.ppc_frequency_source  # the implied category, named
        # No field carries a sample count, so the second judgement cannot move
        # server-side.
        assert set(Facility.model_fields) == {
            "plant_category", "observed_ppc", "ppc_range",
            "stage_temperatures", "stage_durations", "extra_legs",
        }


def test_a_collapsed_pair_is_accepted_and_said_in_notes_not_warnings():
    with claim(
        DOC,
        "The tool accepts the pair rather than refusing it, and says so in "
        "**`notes`** — not in `warnings`, which carries the run's own messages.",
    ):
        request = plan(RUN, Facility(ppc_range=(0.5, 0.5)))
        assert any("deletes the uncertainty" in note for note in request.notes)
        prediction = reshape(synthetic_raw(), request)
        assert any("deletes the uncertainty" in note for note in prediction.notes)
        assert prediction.warnings == []


def test_a_pair_at_zero_deletes_ppc_from_the_simulation():
    with claim(
        DOC,
        "**a pair at zero deletes PPC from the simulation entirely**, so every "
        "figure downstream describes a facility that does not exist.",
    ):
        request = plan(RUN, Facility(ppc_range=(0.0, 0.0)))
        assert any(
            "deletes PPC from the simulation" in note for note in request.notes
        )


# ---------------------------------------------------------------------------
# Step 2 -- the run
# ---------------------------------------------------------------------------

def test_the_run_defaults_and_the_required_seed():
    with claim(DOC, "| `seed` | none | required, and reported back |"):
        with pytest.raises(ValidationError):
            Run()
    with claim(DOC, "| `lots` | 10 | lots simulated |"):
        assert RUN.lots == 10
    with claim(
        DOC, "| `containers_per_lot` | 100 | containers per lot, every one a half-gallon |"
    ):
        assert RUN.containers_per_lot == 100
    with claim(DOC, "| `days` | 40 | days simulated from production |"):
        assert RUN.days == 40


def test_the_default_run_costs_about_forty_seconds():
    with claim(DOC, "The default run takes roughly **40 seconds**."):
        assert 10 * 100 * 40 * _SECONDS_PER_CONTAINER_DAY == pytest.approx(40.0)


# ---------------------------------------------------------------------------
# Step 3 -- the processor's own supply chain
# ---------------------------------------------------------------------------

def test_the_baseline_table_matches_the_shipped_chain():
    rows = {
        "processing_facility": "| `processing_facility` | 1.70 °C | 2.4264 d |",
        "transportation_facility_to_retail":
            "| `transportation_facility_to_retail` | 4.55 °C | 0.3299 d |",
        "retail": "| `retail` | 6.50 °C | 5.4583 d |",
        "transportation_retail_to_home":
            "| `transportation_retail_to_home` | 8.50 °C | 0.0400 d |",
        "consumer": "| `consumer` | 6.50 °C | 27.9583 d |",
    }
    stated = {
        "processing_facility": (1.70, 2.4264),
        "transportation_facility_to_retail": (4.55, 0.3299),
        "retail": (6.50, 5.4583),
        "transportation_retail_to_home": (8.50, 0.0400),
        "consumer": (6.50, 27.9583),
    }
    for stage, quote in rows.items():
        with claim(DOC, quote):
            level, days = stated[stage]
            assert round(BASELINE[stage]["level"], 2) == level
            assert BASELINE[stage]["days"] == days


def test_the_pre_consumer_window_sums_to_8_25_days():
    with claim(
        DOC,
        "The first four sum to **8.25 days** before the product reaches a "
        "consumer — the part of shelf life the processor controls.",
    ):
        window = sum(BASELINE[stage]["days"] for stage in STAGES[:-1])
        assert round(window, 2) == 8.25


def test_the_five_stages_are_fixed_in_number_order_and_name():
    with claim(
        DOC, "**The number of stages, their order and their names are fixed at five.**"
    ):
        assert STAGES == (
            "processing_facility",
            "transportation_facility_to_retail",
            "retail",
            "transportation_retail_to_home",
            "consumer",
        )
        with pytest.raises(ValidationError):
            Facility(stage_temperatures={"warehouse": StageTemperature(shift=1.0)})


def test_state_exactly_one_of_shift_flat_cap():
    with claim(DOC, "State exactly one of the three for a stage."):
        with pytest.raises(ValidationError):
            StageTemperature(shift=-1.0, flat=4.0)
        with pytest.raises(ValidationError):
            StageTemperature()


def test_shift_is_signed_against_the_baseline():
    with claim(
        DOC,
        "`shift` is **signed against the baseline above**, so a processor "
        'saying "our retail case runs at 4 °C, not 6.5" is a `shift` of `-2.5`.',
    ):
        assert StageTemperature(shift=-2.5).level(BASELINE["retail"]["level"]) == 4.0


def test_flat_discards_the_measured_shape_and_the_notes_say_so():
    with claim(
        DOC,
        "Reaching for `flat: 4.0` there delivers the same mean as a flat line "
        "— the daily door-opening and defrost cycle in the baseline's measured "
        "trace disappears, and the run reports growth for a case that never varies.",
    ):
        request = plan(
            RUN, Facility(stage_temperatures={"retail": StageTemperature(flat=4.0)})
        )
        override = request.body["interventions"]["stage_temp_overrides"]["retail"]
        assert override == {"temp_mean": 4.0, "temp_sd": 0}
        assert any("stated as constant" in note for note in request.notes)


def test_a_stage_stated_warmer_or_longer_lands_in_disruptions_applied():
    with claim(
        DOC,
        "**A stage stated above the baseline, or longer than it, lands in the "
        "run's `disruptions_applied` record**, because the API splits a change "
        "by direction and anything warmer or longer goes through that door. "
        "The response's `notes` says so.",
    ):
        warmer = plan(
            RUN, Facility(stage_temperatures={"retail": StageTemperature(shift=3.0)})
        )
        assert "retail" in warmer.body["disruptions"]
        assert any("Stated above the New York baseline" in n for n in warmer.notes)

        longer = plan(RUN, Facility(stage_durations={"retail": 7.0}))
        assert "retail" in longer.body["disruptions"]
        assert any("Stated longer than the New York baseline" in n for n in longer.notes)


def test_a_colder_or_shorter_stage_takes_the_other_door():
    with claim(
        DOC,
        "Colder and warmer are the same statement about the same stage, so do "
        "not split them by direction — the tool picks the door the API needs by sign.",
    ):
        request = plan(
            RUN,
            Facility(
                stage_temperatures={"retail": StageTemperature(shift=-2.5)},
                stage_durations={"retail": 4.0},
            ),
        )
        assert "disruptions" not in request.body
        overrides = request.body["interventions"]["stage_temp_overrides"]["retail"]
        assert overrides["temp_delta"] == -2.5
        assert overrides["duration_delta"] == pytest.approx(4.0 - 5.4583)


def test_a_stated_level_keeps_the_new_york_shape_and_the_notes_say_so():
    with claim(
        DOC,
        "These keys set a stage's **level**; the within-stage *shape* is still "
        "the New York baseline's measured trace, shifted.",
    ):
        request = plan(
            RUN, Facility(stage_temperatures={"retail": StageTemperature(shift=-2.5)})
        )
        assert any("issue #24" in note for note in request.notes)


# ---------------------------------------------------------------------------
# Step 5 -- reading the result, purely (the reshaping the routes rely on)
# ---------------------------------------------------------------------------

def test_a_truncated_run_reports_bounds_not_numbers():
    with claim(
        DOC,
        "When the median lot never crosses the criterion inside the horizon, "
        "`total_days` and `consumer_days` come back as a **bound object** "
        "rather than a number — `{more_than_days, why}` — and "
        "`shelf_life.truncated` is true.",
    ):
        request = plan(Run(seed=42, days=20))
        raw = synthetic_raw(
            shelf_life={"total_days": -1, "consumer_days": -1, "pre_consumer_days": 8.3}
        )
        prediction = reshape(raw, request)
        assert prediction.shelf_life.truncated is True
        assert isinstance(prediction.shelf_life.total_days, Bound)
        assert isinstance(prediction.shelf_life.consumer_days, Bound)
        assert prediction.shelf_life.total_days.why


def test_the_two_bounds_are_different_numbers():
    with claim(
        DOC,
        "The two bounds are different numbers, and the response computes each "
        "one: `total_days` counts from production, `consumer_days` counts from "
        "the moment the product reaches a consumer.",
    ):
        request = plan(Run(seed=42, days=20))
        raw = synthetic_raw(
            shelf_life={"total_days": -1, "consumer_days": -1, "pre_consumer_days": 8.3}
        )
        prediction = reshape(raw, request)
        assert prediction.shelf_life.total_days.more_than_days == 20
        assert prediction.shelf_life.consumer_days.more_than_days == pytest.approx(11.7)


def test_a_truncated_run_prices_the_value_at_zero_and_says_so():
    with claim(
        DOC,
        "A truncated run also prices the shelf-life value at **0** rather than "
        "reporting it as unknown, and the `notes` say so.",
    ):
        request = plan(Run(seed=42, days=20))
        raw = synthetic_raw(
            shelf_life={"total_days": -1, "consumer_days": -1},
            economics={"shelf_life_value_usd": 0.0},
        )
        prediction = reshape(raw, request)
        assert prediction.economics.shelf_life_value_usd == 0.0
        assert any(
            "priced the shelf-life value at 0" in note for note in prediction.notes
        )


def test_unmeasured_retail_exit_is_null_not_zero():
    with claim(
        DOC,
        "`measured: false` means retail exit fell outside the horizon, so the "
        "run ended before the product reached the consumer and `percent` is "
        "null rather than zero.",
    ):
        request = plan(Run(seed=42, days=5))
        raw = synthetic_raw(
            shelf_life={"pre_consumer_day": 8, "total_days": -1, "consumer_days": -1},
            economics={"pct_spoiled_at_retail": 0},
        )
        prediction = reshape(raw, request)
        exit_ = prediction.economics.pct_spoiled_at_retail
        assert exit_.measured is False
        assert exit_.percent is None
        assert exit_.evaluated_on_day == 8


def test_a_single_warning_still_reads_as_a_list():
    with claim(DOC, "Surface `warnings` to the processor whenever it is non-empty."):
        request = plan(RUN)
        prediction = reshape(synthetic_raw(warnings="solve terminated early"), request)
        assert prediction.warnings == ["solve terminated early"]


# ---------------------------------------------------------------------------
# Live -- route 2's own worked calls, end to end
# ---------------------------------------------------------------------------

def test_live_the_worked_default_call_answers(default_medium):
    with claim(DOC, 'predict_default(run={"seed": 42}, plant_category="medium")'):
        scenario = default_medium["scenario"]
        assert scenario["seed"] == 42
        assert scenario["lots"] == 10
        assert scenario["containers_per_lot"] == 100
        assert scenario["horizon_days"] == 40
        assert scenario["ppc_frequency_range"] == [0.40, 0.625]
        assert "medium" in scenario["ppc_frequency_source"]


def test_live_the_worked_customize_call_answers(target):
    with claim(
        DOC,
        'predict_customize( facility={"plant_category": "medium", '
        '"stage_temperatures": {"retail": {"shift": -2.5}}, '
        '"stage_durations": {"retail": 4.0}}, run={"seed": 42})',
    ):
        result = live.call(
            target,
            "predict_customize",
            {
                "run": {"seed": 42, "lots": 2, "containers_per_lot": 10, "days": 12},
                "facility": {
                    "plant_category": "medium",
                    "stage_temperatures": {"retail": {"shift": -2.5}},
                    "stage_durations": {"retail": 4.0},
                },
            },
        )
        # Colder and shorter both take the intervention door, so the audit
        # trail shows no incident.
        assert result["scenario"]["disruptions_applied"] == {}
        assert result["scenario"]["interventions_applied"]
        assert any("issue #24" in note for note in result["notes"])


def test_live_threshold_pct_comes_back_in_every_response(default_medium):
    with claim(
        DOC,
        "`threshold_pct` is 25 and comes back in every response — read it from there.",
    ):
        assert default_medium["shelf_life"]["threshold_pct"] == 25


def test_live_pre_consumer_days_reports_8_3(default_medium):
    with claim(
        DOC,
        "`pre_consumer_days` reports it rounded to one decimal, as **8.3**, so "
        "arithmetic done on the response lands a fraction off the baseline.",
    ):
        assert default_medium["shelf_life"]["pre_consumer_days"] == 8.3
        assert default_medium["shelf_life"]["pre_consumer_day"] == 8


def test_live_daily_spoilage_covers_every_day_to_the_horizon(default_medium):
    with claim(
        DOC,
        "| `daily_spoilage` | one row per simulated day, **0 to the horizon** — "
        "each with `median_pct`, `P25`, `P75` spoiled |",
    ):
        rows = default_medium["daily_spoilage"]
        assert [row["day"] for row in rows] == list(range(0, 41))
        for key in ("median_pct", "P25", "P75"):
            assert key in rows[0]


def test_live_spoilage_summary_days_are_the_fixed_set(default_medium):
    with claim(
        DOC,
        "| `spoilage_summary` | rows drawn from **days 7, 14, 21, 28, 35** — "
        "each with `median_pct`, `mean_pct`, `sd`, `P5`, `P95` |",
    ):
        rows = default_medium["spoilage_summary"]
        assert [row["day"] for row in rows] == [7, 14, 21, 28, 35]
        for key in ("median_pct", "mean_pct", "sd", "P5", "P95"):
            assert key in rows[0]


def test_live_a_20_day_run_returns_days_7_and_14_alone(long20_baseline):
    with claim(
        DOC,
        "a day past the horizon has no data and is dropped, so a 20-day run "
        "returns days 7 and 14 alone.",
    ):
        assert [row["day"] for row in long20_baseline["spoilage_summary"]] == [7, 14]


def test_live_retail_exit_is_day_8_and_matches_the_daily_series(default_medium):
    with claim(
        DOC,
        "Quote the day alongside the figure — on the shipped chain it is day 8, "
        "and `daily_spoilage` carries the same row.",
    ):
        exit_ = default_medium["economics"]["pct_spoiled_at_retail"]
        assert exit_["evaluated_on_day"] == 8
        assert exit_["measured"] is True
        day8 = next(
            row for row in default_medium["daily_spoilage"] if row["day"] == 8
        )
        assert exit_["percent"] == day8["median_pct"]


def test_live_a_horizon_shorter_than_the_chain_warns_and_reports_null(target):
    with claim(
        DOC,
        "A warning that total supply chain duration **exceeds** the horizon "
        "means the run ended before the product did. Raise `run.days` and call again.",
    ):
        result = live.call(
            target,
            "predict_default",
            {"run": {"seed": 42, "lots": 2, "containers_per_lot": 10, "days": 5}},
        )
        assert any("exceed" in warning.lower() for warning in result["warnings"])
        exit_ = result["economics"]["pct_spoiled_at_retail"]
        assert exit_["measured"] is False
        assert exit_["percent"] is None


def test_live_a_temperature_statement_composes_with_an_event_and_warns(target):
    with claim(
        DOC,
        "A stage carrying both a stage-temperature statement and an event "
        "raises a third warning, saying the disruption **composes with** the "
        "temperature intervention: the two are applied in order, the "
        "temperature first and the event on top.",
    ):
        result = live.call(
            target,
            "model_a_disruption",
            {
                "run": {"seed": 42, "lots": 2, "containers_per_lot": 10, "days": 12},
                "facility": {"stage_temperatures": {"retail": {"shift": -1.0}}},
                "disruption": {
                    "thermal_events": [{"stage": "retail", "celsius": 12.0, "days": 0.5}]
                },
            },
        )
        assert any("compose" in warning.lower() for warning in result["warnings"])
