"""What a processor's plant becomes, as a /simulate request body.

The mapping is the half of issue #57 that has to be right before anything else
matters, and it is pure -- so it is tested here without a server, a client or an
R subprocess. tests/test_mcp_tools.py covers the two tools end to end.

The worked failure this whole file exists for: "our retail cases run at 4 degrees,
not the 6.5 you assume" describes a facility while asking a shelf-life question,
and the natural reading is `temp_mean: 4.0`, which replaces the New York
baseline's measured trace with a flat line. The correct key is
`temp_delta: -2.5`.
"""

from __future__ import annotations

import math

import pytest
from pydantic import ValidationError

from mcp_server.facility import Facility, Run, plan
from mcp_server.supply_chain import (
    BASELINE,
    FOLD_TMIN,
    PPC_BANDS,
    Reading,
    growth_equivalent_temperature,
)

SEED = Run(seed=42)


def body(facility: Facility | None = None, run: Run = SEED) -> dict:
    return plan(run, facility).body


# ---------------------------------------------------------------------------
# The run, and the config every call carries
# ---------------------------------------------------------------------------

def test_a_default_run_carries_the_shipped_config_and_the_seed():
    """Sent explicitly rather than left to the API's defaults.

    The reshaping has to state the horizon a truncated shelf life is bounded by,
    and the response carries no `sim_duration`. Sending it is what makes the
    bound computable from one call.
    """
    assert body() == {
        "config": {
            "n_lots": 10,
            "n_units": 100,
            "P_ppc_min": 0.40,
            "P_ppc_max": 0.625,
            "sim_duration": 40,
        },
        "seed": 42,
    }


def test_a_run_the_client_would_time_out_on_is_rejected_before_it_is_sent():
    with pytest.raises(ValidationError, match="seconds"):
        Run(seed=1, lots=100, containers_per_lot=1000, days=120)


def test_a_seed_is_required():
    with pytest.raises(ValidationError):
        Run()


# ---------------------------------------------------------------------------
# PPC frequency — the published band, or the processor's own observation
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("category", ["long", "medium", "short"])
def test_a_plant_category_resolves_to_its_published_band(category):
    result = plan(SEED, Facility(plant_category=category))
    assert result.body["config"]["P_ppc_min"] == PPC_BANDS[category][0]
    assert result.body["config"]["P_ppc_max"] == PPC_BANDS[category][1]
    assert result.ppc_frequency_range == PPC_BANDS[category]
    # ADR 012: the response states the number rather than hiding it behind a name.
    assert category in result.ppc_frequency_source


def test_prevalences_that_vary_across_lots_beat_every_published_band():
    result = plan(SEED, Facility(observed_ppc=[0.2, 0.45, 0.3]))
    assert result.ppc_frequency_range == (0.2, 0.45)
    assert "3 lots" in result.ppc_frequency_source


def test_prevalences_that_agree_keep_the_band_rather_than_collapsing_to_a_point():
    """An observed range of zero width is a small-sample artefact, not certainty.

    Route 2's rule. Setting both bounds to one observed value deletes the
    uncertainty the pair exists to carry, and at an observed zero it deletes PPC
    from the simulation entirely.
    """
    result = plan(SEED, Facility(observed_ppc=[0.5, 0.5]))
    assert result.ppc_frequency_range == PPC_BANDS["medium"]
    assert "collapsed" in result.ppc_frequency_source


def test_one_lot_is_reported_as_evidence_and_does_not_set_the_bounds():
    result = plan(SEED, Facility(observed_ppc=[0.8]))
    assert result.ppc_frequency_range == PPC_BANDS["short"]
    assert "one lot" in result.ppc_frequency_source
    assert "short" in result.ppc_frequency_source


def test_a_stated_category_outranks_what_a_single_lot_implies():
    result = plan(SEED, Facility(plant_category="long", observed_ppc=[0.8]))
    assert result.ppc_frequency_range == PPC_BANDS["long"]
    assert "short" in result.ppc_frequency_source  # named as the observation's implication


def test_the_processors_own_range_is_used_as_given():
    result = plan(SEED, Facility(ppc_range=(0.1, 0.9)))
    assert result.ppc_frequency_range == (0.1, 0.9)


def test_a_range_of_zero_width_is_noted_rather_than_silently_used():
    result = plan(SEED, Facility(ppc_range=(0.3, 0.3)))
    assert result.ppc_frequency_range == (0.3, 0.3)
    assert any("uncertainty" in note for note in result.notes)


def test_a_range_pinned_at_zero_says_it_deletes_ppc_from_the_run():
    result = plan(SEED, Facility(ppc_range=(0.0, 0.0)))
    assert any("deletes PPC" in note for note in result.notes)


def test_a_backwards_range_is_rejected():
    with pytest.raises(ValidationError):
        Facility(ppc_range=(0.6, 0.2))


@pytest.mark.parametrize(
    "facility",
    [
        {"observed_ppc": [0.2, 1.2]},
        # The mistake the bound exists for: route 2 states every published band as
        # a percentage, so "our lots came back at 45% and 60%" reads as [45, 60].
        {"observed_ppc": [45, 60]},
        {"ppc_range": (0.4, 1.6)},
    ],
)
def test_a_frequency_above_one_is_rejected_before_it_kills_the_run(facility):
    """A PPC frequency over 1 does not saturate -- the run dies.

    run_model.R:142 takes `num_ppc <- round(P_ppc * n_unit)` and then
    `num_non_ppc <- n_unit - num_ppc`, so 1.2 at 100 containers asks for
    `rep("non_PPC", -20)`. Measured against the bridge: `Error in
    rep("non_PPC", num_non_ppc) : invalid 'times' argument`, which /simulate
    returns as an HTTP 500. `ppc_range` was bounded; `observed_ppc` was not, and
    it reaches P_ppc_min/P_ppc_max by exactly the same path.
    """
    with pytest.raises(ValidationError, match="less than or equal to 1"):
        Facility(**facility)


def test_a_prevalence_of_one_is_still_allowed():
    """67-100% is the short-shelf-life band, so 1.0 is a real observation."""
    assert plan(SEED, Facility(ppc_range=(0.9, 1.0))).ppc_frequency_range == (0.9, 1.0)


# ---------------------------------------------------------------------------
# Stage temperature — the door is picked by sign
# ---------------------------------------------------------------------------

def test_a_colder_stage_becomes_an_intervention():
    sent = body(Facility(stage_temperatures={"retail": {"shift": -2.5}}))
    assert sent["interventions"] == {
        "stage_temp_overrides": {"retail": {"temp_delta": -2.5}}
    }
    assert "disruptions" not in sent


def test_a_warmer_stage_becomes_a_disruption():
    sent = body(Facility(stage_temperatures={"retail": {"shift": 2.0}}))
    assert sent["disruptions"] == {"retail": {"type": "temp_shift", "temp_delta": 2.0}}
    assert "interventions" not in sent


def test_the_worked_failure_a_stated_level_becomes_an_offset_not_a_flat_line():
    """"our retail cases run at 4 degrees, not the 6.5 you assume"."""
    sent = body(Facility(stage_temperatures={"retail": {"shift": -2.5}}))
    override = sent["interventions"]["stage_temp_overrides"]["retail"]
    assert "temp_mean" not in override
    assert override["temp_delta"] == -2.5


def test_a_flat_stage_below_baseline_replaces_the_measured_shape():
    """`flat` is the key that means a constant stage, and it says so."""
    result = plan(SEED, Facility(stage_temperatures={"retail": {"flat": 4.0}}))
    override = result.body["interventions"]["stage_temp_overrides"]["retail"]
    assert override == {"temp_mean": 4.0, "temp_sd": 0}
    assert any("constant" in note for note in result.notes)


def test_a_flat_stage_above_baseline_still_puts_the_warming_through_the_disruption_door():
    """No disruption type flattens a stage, so the two doors compose.

    The intervention flattens at the baseline level, which is no thermal
    improvement, and the disruption carries the whole of the warming. The run
    then reports a stage flat at the stated level, and disruptions_applied is an
    honest record of a plant running warmer than the New York baseline.
    """
    result = plan(SEED, Facility(stage_temperatures={"retail": {"flat": 9.0}}))
    assert result.body["interventions"]["stage_temp_overrides"]["retail"] == {
        "temp_mean": BASELINE["retail"]["level"],
        "temp_sd": 0,
    }
    assert result.body["disruptions"]["retail"] == {
        "type": "temp_shift",
        "temp_delta": pytest.approx(2.5),
    }


def test_a_cap_is_an_intervention_in_either_direction():
    """Clamping can only lower a temperature, so it has one door."""
    sent = body(Facility(stage_temperatures={"retail": {"cap": 8.0}}))
    assert sent["interventions"] == {
        "stage_temp_overrides": {"retail": {"temp_max": 8.0}}
    }


def test_a_stage_stated_at_its_baseline_level_sends_nothing():
    sent = body(Facility(stage_temperatures={"retail": {"shift": 0}}))
    assert "interventions" not in sent
    assert "disruptions" not in sent


def test_a_flat_stage_at_the_baseline_level_is_still_a_change():
    """The level matches; the shape does not.

    `flat` at the New York baseline's own mean discards the daily door-opening and defrost
    cycle in the measured trace, so it is not the no-op a zero shift is.
    """
    sent = body(Facility(stage_temperatures={"retail": {"flat": 6.5}}))
    assert sent["interventions"]["stage_temp_overrides"]["retail"] == {
        "temp_mean": 6.5,
        "temp_sd": 0,
    }
    assert "disruptions" not in sent


def test_exactly_one_of_shift_flat_and_cap_is_accepted():
    with pytest.raises(ValidationError, match="one of"):
        Facility(stage_temperatures={"retail": {"shift": -1, "flat": 4}})
    with pytest.raises(ValidationError, match="one of"):
        Facility(stage_temperatures={"retail": {}})


def test_an_unknown_stage_is_rejected_by_the_schema():
    with pytest.raises(ValidationError):
        Facility(stage_temperatures={"distribution_centre": {"shift": 1}})


# ---------------------------------------------------------------------------
# Stage duration — absolute days in, an offset out
# ---------------------------------------------------------------------------

def test_a_shorter_stage_becomes_an_intervention():
    sent = body(Facility(stage_durations={"retail": 3.0}))
    delta = sent["interventions"]["stage_temp_overrides"]["retail"]["duration_delta"]
    assert delta == pytest.approx(3.0 - BASELINE["retail"]["days"])


def test_a_longer_stage_becomes_a_delay_at_the_stages_own_level():
    sent = body(Facility(stage_durations={"retail": 8.0}))
    assert sent["disruptions"]["retail"] == {
        "type": "delay",
        "duration_delta": pytest.approx(8.0 - BASELINE["retail"]["days"]),
        "temp": BASELINE["retail"]["level"],
    }


def test_a_longer_stage_holds_the_added_time_at_the_level_the_processor_stated():
    """A colder plant's extra time is spent cold, not at the baseline's level."""
    sent = body(
        Facility(
            stage_temperatures={"retail": {"shift": -2.5}},
            stage_durations={"retail": 8.0},
        )
    )
    assert sent["disruptions"]["retail"]["temp"] == pytest.approx(4.0)
    assert sent["interventions"]["stage_temp_overrides"]["retail"]["temp_delta"] == -2.5


def test_a_stage_shortened_to_nothing_is_rejected_by_the_schema():
    """A stage must keep a positive duration, in either temperature mode."""
    with pytest.raises(ValidationError, match="greater than 0"):
        Facility(stage_durations={"transportation_retail_to_home": 0})


def test_a_stage_that_is_both_warmer_and_longer_is_rejected_not_silently_halved():
    """The API takes one disruption per stage, and both changes need that slot."""
    with pytest.raises(ValueError, match="one disruption") as raised:
        body(
            Facility(
                stage_temperatures={"retail": {"shift": 2.0}},
                stage_durations={"retail": 8.0},
            )
        )
    # The advice has to fit the collision. No leg was mentioned, so telling the
    # caller to move one is worse than telling them nothing.
    assert "leg" not in str(raised.value)
    assert "both warmer and longer" in str(raised.value)


def test_a_capped_stage_running_longer_says_what_the_added_time_is_held_at():
    """Only the measured profile knows how far a cap lowers a stage's mean.

    So the added time is held at an upper bound on it, which errs warm -- towards
    more growth and a shorter predicted shelf life. Named, not silent.
    """
    result = plan(
        SEED,
        Facility(
            stage_temperatures={"retail": {"cap": 5.0}},
            stage_durations={"retail": 8.0},
        ),
    )
    assert result.body["disruptions"]["retail"]["temp"] == 5.0
    assert any("upper bound" in note and "errs warm" in note for note in result.notes)


# ---------------------------------------------------------------------------
# extra_legs — a leg the five stages do not have
# ---------------------------------------------------------------------------

def test_a_leg_held_at_one_temperature_folds_into_the_stage_it_follows():
    sent = body(
        Facility(
            extra_legs=[
                {"after": "transportation_facility_to_retail", "celsius": 5.0, "days": 3}
            ]
        )
    )
    assert sent["disruptions"]["transportation_facility_to_retail"] == {
        "type": "delay",
        "duration_delta": 3.0,
        "temp": 5.0,
    }


def test_a_folded_leg_says_it_lands_in_the_disruption_record():
    result = plan(
        SEED,
        Facility(extra_legs=[{"after": "retail", "celsius": 5.0, "days": 1}]),
    )
    assert any(
        "disruptions_applied" in note and "not an incident" in note
        for note in result.notes
    )


def test_a_measured_leg_folds_above_its_arithmetic_mean():
    """A fold at the mean loses growth, and the loss overpredicts shelf life."""
    readings = [
        {"hours": 0, "celsius": 2.0},
        {"hours": 6, "celsius": 20.0},
        {"hours": 12, "celsius": 2.0},
    ]
    result = plan(
        SEED, Facility(extra_legs=[{"after": "retail", "readings": readings}])
    )
    folded = result.body["disruptions"]["retail"]
    assert folded["duration_delta"] == pytest.approx(0.5)
    assert folded["temp"] > 11.0  # the arithmetic mean of the three readings
    assert any("growth-equivalent" in note for note in result.notes)


def test_the_fold_weights_by_elapsed_time_not_by_reading_count():
    """Dense sampling through a cool interval must not bury a long warm one."""
    sparse_warm = [
        {"hours": 0, "celsius": 4.0},
        {"hours": 1, "celsius": 4.0},
        {"hours": 2, "celsius": 4.0},
        {"hours": 26, "celsius": 4.0},
    ]
    even = [{"hours": 0, "celsius": 4.0}, {"hours": 26, "celsius": 4.0}]
    one = plan(SEED, Facility(extra_legs=[{"after": "retail", "readings": sparse_warm}]))
    two = plan(SEED, Facility(extra_legs=[{"after": "retail", "readings": even}]))
    assert one.body["disruptions"]["retail"]["temp"] == pytest.approx(
        two.body["disruptions"]["retail"]["temp"]
    )


def test_a_leg_states_a_temperature_or_a_series_and_not_both():
    with pytest.raises(ValidationError, match="celsius"):
        Facility(
            extra_legs=[
                {
                    "after": "retail",
                    "celsius": 5.0,
                    "readings": [{"hours": 0, "celsius": 4}, {"hours": 1, "celsius": 6}],
                }
            ]
        )


def test_a_series_carries_its_own_duration_so_days_is_refused():
    with pytest.raises(ValidationError, match="days"):
        Facility(
            extra_legs=[
                {
                    "after": "retail",
                    "days": 2,
                    "readings": [{"hours": 0, "celsius": 4}, {"hours": 1, "celsius": 6}],
                }
            ]
        )


def test_a_leg_stated_as_one_temperature_needs_its_duration():
    with pytest.raises(ValidationError, match="days"):
        Facility(extra_legs=[{"after": "retail", "celsius": 5.0}])


def test_two_legs_after_one_stage_are_rejected():
    with pytest.raises(ValueError, match="one disruption") as raised:
        body(
            Facility(
                extra_legs=[
                    {"after": "retail", "celsius": 5.0, "days": 1},
                    {"after": "retail", "celsius": 9.0, "days": 2},
                ]
            )
        )
    # Here a leg IS involved, so moving it to a neighbour is the fix -- growth
    # depends on the series, not on the stage labels drawn over it.
    assert "neighbouring stage" in str(raised.value)


# ---------------------------------------------------------------------------
# The limits the answer has to state
# ---------------------------------------------------------------------------

def test_a_stated_stage_level_says_the_within_stage_shape_is_still_cornells():
    """Issue #24. An existing stage cannot take an inline profile."""
    result = plan(SEED, Facility(stage_temperatures={"retail": {"shift": -2.5}}))
    assert any(
        "within-stage" in note and "shifted" in note for note in result.notes
    )


def test_a_warmer_level_says_it_lands_in_the_disruption_record():
    result = plan(SEED, Facility(stage_temperatures={"retail": {"shift": 2.0}}))
    assert any("disruptions_applied" in note for note in result.notes)


def test_a_baseline_call_carries_no_scenario_notes():
    assert plan(SEED, None).notes == []


# ---------------------------------------------------------------------------
# The comparability verdict the response states
# ---------------------------------------------------------------------------

def test_a_temperature_change_alone_leaves_the_evaluation_day_alone():
    result = plan(SEED, Facility(stage_temperatures={"retail": {"shift": 2.0}}))
    assert result.pre_consumer_duration_changed is False
    assert result.duration_stages == []


@pytest.mark.parametrize(
    "facility",
    [
        Facility(stage_durations={"retail": 3.0}),
        Facility(stage_durations={"retail": 8.0}),
        Facility(extra_legs=[{"after": "retail", "celsius": 5.0, "days": 1}]),
    ],
)
def test_any_duration_change_in_a_pre_consumer_stage_moves_the_evaluation_day(facility):
    result = plan(SEED, facility)
    assert result.pre_consumer_duration_changed is True
    assert result.duration_stages == ["retail"]


def test_a_duration_change_confined_to_the_consumer_stage_does_not():
    """pre_consumer_days sums the other four, so the evaluation day is untouched."""
    result = plan(SEED, Facility(stage_durations={"consumer": 20.0}))
    assert result.pre_consumer_duration_changed is False


def test_the_fold_matches_the_simulators_own_segment_rule():
    """A ramp, integrated in closed form, against the fold.

    Over a linear ramp from a to b the mean of (T - Tmin)^2 is
    (a^2 + ab + b^2)/3, so T_eq is Tmin + the square root of that. Any
    trapezoidal or arithmetic shortcut disagrees here.
    """
    a = 2.0 - FOLD_TMIN
    b = 20.0 - FOLD_TMIN
    ramp = [Reading(hours=0, celsius=2.0), Reading(hours=24, celsius=20.0)]
    assert growth_equivalent_temperature(ramp) == pytest.approx(
        FOLD_TMIN + math.sqrt((a * a + a * b + b * b) / 3)
    )


def test_readings_that_span_no_time_are_rejected():
    """Two readings at the same timestamp are a leg with no extent."""
    with pytest.raises(ValueError, match="span no time"):
        growth_equivalent_temperature(
            [Reading(hours=3, celsius=4.0), Reading(hours=3, celsius=9.0)]
        )
