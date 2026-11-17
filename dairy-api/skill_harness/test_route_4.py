"""Route 4 -- prevention strategies: named levers, published levels, the gate.

ADR 012's rule runs through this file: a number entering the model was
published or measured, never invented, and a name standing for a published
number has to hand that number back.
"""

from __future__ import annotations

import csv
from pathlib import Path

import pytest
from pydantic import ValidationError

from mcp_server.facility import Facility, Run, StageTemperature, plan
from mcp_server.intervention import NAMED, SPORE_PRESETS, Intervention, StageCooling
from mcp_server.supply_chain import PPC_BANDS
from skill_harness.claims import claim

DOC = "routes/4-prevention-strategies.md"

RUN = Run(seed=42)

_INPUT_DATA = Path(__file__).resolve().parents[2] / "milk-spoilage-model" / "input_data"


def pool_rows(name: str) -> list[dict]:
    with open(_INPUT_DATA / name, newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


# ---------------------------------------------------------------------------
# Step 2 -- the named levers and their published levels
# ---------------------------------------------------------------------------

def test_each_named_lever_resolves_to_the_published_level():
    rows = {
        "increase_equipment_cleaning": (
            "| `increase_equipment_cleaning` | PPC frequency 100% → 50% | increase "
            "periodic cleaning of filler nozzles from once to twice a week |",
            "ppc_frequency_factor", 0.5,
        ),
        "replace_filler_nozzles": (
            "| `replace_filler_nozzles` | PPC frequency 100% → 10% | the same, plus "
            "replacing old filler nozzles |",
            "ppc_frequency_factor", 0.1,
        ),
        "preventative_maintenance": (
            "| `preventative_maintenance` | 1 log reduction in the PPC load that "
            "arrives | maintenance SOPs for O-rings, gaskets, mesh screens, rubber "
            "fittings |",
            "ppc_initial_reduction_log", 1.0,
        ),
        "preventative_maintenance_upper_bound": (
            "| `preventative_maintenance_upper_bound` | 3 log | the same, at a level "
            "the authors flag as likely unrealistic — a bound, not a proposal |",
            "ppc_initial_reduction_log", 3.0,
        ),
        "seek_and_destroy_fastest_growing": (
            "| `seek_and_destroy_fastest_growing` | the sequence type with the "
            'highest maximum growth rate | "Seek and Destroy" on that type |',
            "ppc_remove_st", ("100",),
        ),
        "seek_and_destroy_most_frequent": (
            "| `seek_and_destroy_most_frequent` | the two most frequently occurring "
            'sequence types | "Seek and Destroy" on those two |',
            "ppc_remove_st", ("9", "13"),
        ),
    }
    assert set(rows) == set(NAMED), "the route table and the shipped levers differ"
    for name, (quote, parameter, level) in rows.items():
        with claim(DOC, quote):
            assert NAMED[name].parameter == parameter
            assert NAMED[name].level == level
            assert "Lau" in NAMED[name].source


def test_a_name_hands_its_number_back_in_resolved_levels():
    with claim(
        DOC,
        "each `named` lever resolves to its level server-side. The response "
        "states that level, the plant action behind it and the publication in "
        "`scenario.resolved_levels`.",
    ):
        request = plan(
            RUN, intervention=Intervention(named=["increase_equipment_cleaning"])
        )
        (resolved,) = request.resolved_levels
        assert resolved.named == "increase_equipment_cleaning"
        assert resolved.level == 0.5
        assert resolved.plant_action
        assert "Lau" in resolved.source


def test_a_name_and_a_stated_level_claiming_one_parameter_are_rejected():
    with claim(
        DOC,
        "**A name and a stated level claiming the same parameter are rejected "
        "rather than merged**, so state one.",
    ):
        with pytest.raises(ValidationError) as caught:
            Intervention(
                named=["increase_equipment_cleaning"], reduce_ppc_frequency=0.5
            )
        assert "State one" in str(caught.value)
        with pytest.raises(ValidationError):
            Intervention(
                named=[
                    "preventative_maintenance",
                    "preventative_maintenance_upper_bound",
                ]
            )


def test_an_intervention_states_at_least_one_lever():
    with claim(DOC, "Tool: `model_an_intervention(run, intervention, facility?)`."):
        with pytest.raises(ValidationError) as caught:
            Intervention()
        assert "at least one lever" in str(caught.value)


def test_limiting_distribution_temperature_is_a_cap():
    with claim(
        DOC,
        '**Limiting distribution temperature** is `cool_stage: {<stage>: '
        '{"cap": 6}}` — Lau et al. (2022) publish 6 °C for it.',
    ):
        request = plan(
            RUN, intervention=Intervention(cool_stage={"retail": StageCooling(cap=6)})
        )
        overrides = request.body["interventions"]["stage_temp_overrides"]
        assert overrides["retail"]["temp_max"] == 6


def test_by_and_to_are_read_against_this_calls_own_chain():
    with claim(
        DOC,
        "`cool_stage` also takes `by` for degrees colder than this call's "
        "chain already runs a stage, and `to` for an absolute temperature. "
        "Both are read against the chain this same call describes, never an "
        "earlier run, and a target that leaves the stage warmer is rejected.",
    ):
        request = plan(
            RUN,
            Facility(stage_temperatures={"retail": StageTemperature(shift=-2.5)}),
            intervention=Intervention(cool_stage={"retail": StageCooling(by=2)}),
        )
        overrides = request.body["interventions"]["stage_temp_overrides"]
        # The facility runs retail at 4.0, so 2 degrees colder is 2.0 -- a
        # shift of -4.5 against the 6.5 baseline, not -2 against it.
        assert overrides["retail"]["temp_delta"] == pytest.approx(-4.5)

        with pytest.raises(ValueError) as caught:
            plan(
                RUN,
                intervention=Intervention(cool_stage={"retail": StageCooling(to=8)}),
            )
        assert "improvements only" in str(caught.value)
        assert "model_a_disruption" in str(caught.value)


def test_cooling_states_exactly_one_of_by_to_cap():
    with claim(DOC, "Tool: `model_an_intervention(run, intervention, facility?)`."):
        with pytest.raises(ValidationError):
            StageCooling(by=2, to=4)
        with pytest.raises(ValidationError):
            StageCooling()


# ---------------------------------------------------------------------------
# Seek and Destroy: the pool's own numbers
# ---------------------------------------------------------------------------

def test_mumax_ranks_st13_above_st100_and_lag_says_why_that_is_wrong():
    # Route 4 keeps the constraint; the pool's own numbers live behind its
    # pointer in the reference document (issue #34). Both claims are bound.
    with claim(
        DOC,
        "**Do not substitute an ID by reading the pool's `mumax` column.**",
    ), claim(
        "docs/reference/ppc-growth-model.md",
        "It ranks ST 13 above ST 100, and that ranking ignores lag: ST 13's "
        "rows carry a lag of 55.9–58.6 against ST 100's 3.5–8.9.",
    ):
        rows = pool_rows("ppc_growth_params.csv")
        st13 = [row for row in rows if row["STorAT"] == "13"]
        st100 = [row for row in rows if row["STorAT"] == "100"]
        assert st13 and st100
        assert min(float(r["mumax"]) for r in st13) > max(
            float(r["mumax"]) for r in st100
        )
        lag13 = [float(r["lag"]) for r in st13]
        lag100 = [float(r["lag"]) for r in st100]
        assert (round(min(lag13), 1), round(max(lag13), 1)) == (55.9, 58.6)
        assert (round(min(lag100), 1), round(max(lag100), 1)) == (3.5, 8.9)


def test_removing_9_leaves_the_36_compound_rows_in_place():
    with claim(
        DOC,
        "One trap in the pool's own labels: some rows carry compound types "
        'such as `9_23`. Removing `"9"` leaves those 36 rows in place, because '
        "the match is exact rather than partial.",
    ):
        rows = pool_rows("ppc_st_frequency.csv")
        compound = [row for row in rows if row["ClosestST"] == "9_23"]
        assert len(compound) == 36


def test_a_non_matching_id_is_flagged_in_the_notes():
    with claim(
        DOC,
        "A Seek-and-Destroy run that returns numbers identical to the baseline "
        "is far more likely a non-matching ID than a real null result, and the "
        "response's `notes` says so.",
    ):
        request = plan(
            RUN, intervention=Intervention(remove_sequence_types=["999"])
        )
        assert any("non-matching id" in note for note in request.notes)


# ---------------------------------------------------------------------------
# Spore removal
# ---------------------------------------------------------------------------

def test_the_spore_presets_carry_their_published_levels():
    rows = {
        "microfiltration": ("| `microfiltration` | 2.2 | Doll et al. 2017 |", 2.2, "Doll"),
        "microfiltration_low": (
            "| `microfiltration_low` | 0.6 | Doll et al. 2017, a low-efficiency installation |",
            0.6, "Doll",
        ),
        "bactofugation_single": (
            "| `bactofugation_single` | 1.4 | Gésan-Guiziou 2010 |", 1.4, "Gesan-Guiziou",
        ),
        "bactofugation_double": (
            "| `bactofugation_double` | 2.0 | Griep 2018, Cornell PhD thesis |", 2.0, "Griep",
        ),
    }
    assert set(rows) == set(SPORE_PRESETS)
    for name, (quote, level, source) in rows.items():
        with claim(DOC, quote):
            assert SPORE_PRESETS[name].log_reduction == level
            assert source in SPORE_PRESETS[name].source


def test_a_measured_reduction_is_passed_bare_and_resolves_no_name():
    with claim(
        DOC,
        "Pass a bare number instead of a preset name when the processor has "
        "measured their own reduction.",
    ):
        keys, resolved, _ = Intervention(reduce_spores=1.5).parameters()
        assert keys["spore_reduction"] == 1.5
        assert resolved == []

        keys, resolved, _ = Intervention(reduce_spores="microfiltration").parameters()
        assert keys["spore_reduction"] == "microfiltration"
        assert resolved[0].level == 2.2


def test_the_spore_lever_in_a_medium_plant_is_flagged_as_masked():
    with claim(
        DOC,
        "The tool says the same thing in its `notes` whenever `reduce_spores` "
        "runs in a medium or short plant. Repeat the note you were given.",
    ):
        masked = plan(
            RUN,
            Facility(plant_category="medium"),
            intervention=Intervention(reduce_spores="microfiltration"),
        )
        assert any("masked by a PPC problem" in note for note in masked.notes)

        clear = plan(
            RUN,
            Facility(plant_category="long"),
            intervention=Intervention(reduce_spores="microfiltration"),
        )
        assert not any("masked by a PPC problem" in note for note in clear.notes)


# ---------------------------------------------------------------------------
# A category move is not a reduce_ppc_frequency
# ---------------------------------------------------------------------------

def test_no_single_scalar_moves_the_medium_band_onto_the_long_one():
    with claim(
        DOC,
        "`reduce_ppc_frequency` multiplies **both** PPC frequency bounds by "
        "one scalar. Moving a medium plant onto the long shelf-life band needs "
        "×0.3125 on the minimum and ×0.47 on the maximum, which no single "
        "scalar delivers.",
    ):
        low_ratio = PPC_BANDS["long"][0] / PPC_BANDS["medium"][0]
        high_ratio = PPC_BANDS["long"][1] / PPC_BANDS["medium"][1]
        assert low_ratio == pytest.approx(0.3125)
        assert round(high_ratio, 2) == 0.47
        assert low_ratio != pytest.approx(high_ratio)


# ---------------------------------------------------------------------------
# Live -- the gate's own measured evidence
# ---------------------------------------------------------------------------

def test_live_the_masked_lever_leaves_every_headline_figure_unchanged(
    adr012_medium_baseline, adr012_medium_micro
):
    with claim(
        DOC,
        "| Medium (the shipped default) | 12 d → **12 d** | 3.7 → **3.7** | unchanged |",
    ):
        for run in (adr012_medium_baseline, adr012_medium_micro):
            assert run["shelf_life"]["total_days"] == 12
            assert run["shelf_life"]["consumer_days"] == 3.7
        assert (
            adr012_medium_baseline["economics"]["shelf_life_value_usd"]
            == adr012_medium_micro["economics"]["shelf_life_value_usd"]
        )


def test_live_the_masked_lever_still_moves_the_spoilage_curve(
    adr012_medium_baseline, adr012_medium_micro
):
    with claim(
        DOC,
        "The spoilage curve did move: `spoilage_summary` went from 59% to 54% "
        "spoiled at d 21.",
    ):
        def at_day_21(run):
            return next(
                row for row in run["spoilage_summary"] if row["day"] == 21
            )["median_pct"]

        assert round(at_day_21(adr012_medium_baseline)) == 59
        assert round(at_day_21(adr012_medium_micro)) == 54


def test_live_the_same_lever_moves_every_figure_in_a_long_plant(
    adr012_long_baseline, adr012_long_micro
):
    with claim(
        DOC,
        "| Long | 19 d → **22 d** | 10.7 → **13.7** | $16.12 → **$20.62** |",
    ):
        assert adr012_long_baseline["shelf_life"]["total_days"] == 19
        assert adr012_long_micro["shelf_life"]["total_days"] == 22
        assert adr012_long_baseline["shelf_life"]["consumer_days"] == 10.7
        assert adr012_long_micro["shelf_life"]["consumer_days"] == 13.7
        assert adr012_long_baseline["economics"]["shelf_life_value_usd"] == 16.12
        assert adr012_long_micro["economics"]["shelf_life_value_usd"] == 20.62


def test_live_the_masked_note_reaches_the_response(adr012_medium_micro):
    with claim(
        DOC,
        "The tool says the same thing in its `notes` whenever `reduce_spores` "
        "runs in a medium or short plant.",
    ):
        assert any(
            "masked by a PPC problem" in note
            for note in adr012_medium_micro["notes"]
        )
