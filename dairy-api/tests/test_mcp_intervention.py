"""An improvement a processor is weighing, as a /simulate request body.

Pure, so it runs without a server, a client or an R subprocess --
tests/test_mcp_tools.py covers the tool end to end.

ADR 012's rule is what most of this file asserts: a number the skill puts into
the model is published or measured, and a name resolves to a level the response
states rather than hiding it.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from mcp_server.facility import Facility, Run, plan
from mcp_server.intervention import SPORE_PRESETS, Intervention
from mcp_server.supply_chain import BASELINE

SEED = Run(seed=42)


def applied(intervention: Intervention, facility: Facility | None = None) -> dict:
    return plan(SEED, facility, intervention=intervention).body.get("interventions", {})


def levels(intervention: Intervention, facility: Facility | None = None) -> dict:
    return {
        resolved.named: resolved.level
        for resolved in plan(SEED, facility, intervention=intervention).resolved_levels
    }


# ---------------------------------------------------------------------------
# The named levers, each resolving to a published level
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("name", "parameter", "level"),
    [
        ("increase_equipment_cleaning", "ppc_frequency_factor", 0.5),
        ("replace_filler_nozzles", "ppc_frequency_factor", 0.1),
        ("preventative_maintenance", "ppc_initial_reduction_log", 1.0),
        ("preventative_maintenance_upper_bound", "ppc_initial_reduction_log", 3.0),
        ("seek_and_destroy_fastest_growing", "ppc_remove_st", ["100"]),
        ("seek_and_destroy_most_frequent", "ppc_remove_st", ["9", "13"]),
    ],
)
def test_a_named_lever_reaches_the_api_as_its_published_level(name, parameter, level):
    """Lau et al. Table 4, one row at a time. ADR 012."""
    intervention = Intervention(named=[name])
    assert applied(intervention)[parameter] == level


def test_a_named_lever_states_the_level_it_resolved_to():
    """The name is not enough: the response has to carry the number and its source."""
    result = plan(SEED, intervention=Intervention(named=["increase_equipment_cleaning"]))
    resolved = result.resolved_levels[0]
    assert resolved.named == "increase_equipment_cleaning"
    assert resolved.parameter == "ppc_frequency_factor"
    assert resolved.level == 0.5
    assert "filler nozzles" in resolved.plant_action
    assert "Lau" in resolved.source


def test_the_upper_bound_says_the_authors_flagged_it_as_unrealistic():
    resolved = plan(
        SEED, intervention=Intervention(named=["preventative_maintenance_upper_bound"])
    ).resolved_levels[0]
    assert "unrealistic" in resolved.source


def test_two_names_claiming_one_parameter_are_rejected_rather_than_overwritten():
    with pytest.raises(ValueError, match="ppc_frequency_factor"):
        applied(
            Intervention(named=["increase_equipment_cleaning", "replace_filler_nozzles"])
        )


def test_a_name_and_a_stated_level_for_one_parameter_are_rejected():
    """A processor's own figure outranks a published one -- so state one, not both."""
    with pytest.raises(ValueError, match="ppc_frequency_factor"):
        applied(
            Intervention(named=["increase_equipment_cleaning"], reduce_ppc_frequency=0.3)
        )


def test_the_two_seek_and_destroy_outcomes_are_one_call_together():
    """Removal alone models the source found; removal plus a frequency cut, eliminated."""
    sent = applied(
        Intervention(
            named=["seek_and_destroy_most_frequent", "increase_equipment_cleaning"]
        )
    )
    assert sent["ppc_remove_st"] == ["9", "13"]
    assert sent["ppc_frequency_factor"] == 0.5


def test_an_unknown_name_is_rejected_by_the_schema():
    with pytest.raises(ValidationError):
        Intervention(named=["tighter_valve_programme"])


# ---------------------------------------------------------------------------
# The levels a processor states themselves
# ---------------------------------------------------------------------------

def test_a_measured_ppc_frequency_reduction_is_used_as_given():
    assert applied(Intervention(reduce_ppc_frequency=0.35))["ppc_frequency_factor"] == 0.35


def test_a_stated_level_resolves_to_nothing_because_it_hides_nothing():
    assert levels(Intervention(reduce_ppc_frequency=0.35)) == {}


@pytest.mark.parametrize("factor", [0, 1, 1.4])
def test_a_frequency_factor_that_is_not_a_reduction_is_rejected(factor):
    """Interventions are improvements only (ADR 003), and 0 deletes PPC entirely."""
    with pytest.raises(ValidationError):
        Intervention(reduce_ppc_frequency=factor)


def test_a_load_reduction_reaches_the_api_in_log10():
    assert applied(Intervention(reduce_ppc_load_log=1.5))["ppc_initial_reduction_log"] == 1.5


def test_a_load_reduction_of_zero_is_rejected():
    with pytest.raises(ValidationError):
        Intervention(reduce_ppc_load_log=0)


def test_sequence_types_a_processor_typed_themselves_are_passed_through():
    sent = applied(Intervention(remove_sequence_types=["9_23", "112"]))
    assert sent["ppc_remove_st"] == ["9_23", "112"]


def test_removing_a_sequence_type_warns_that_a_non_matching_id_removes_nothing():
    """Route 4's trap: the run still lists the intervention as applied."""
    result = plan(SEED, intervention=Intervention(remove_sequence_types=["9"]))
    assert any("matches nothing" in note for note in result.notes)


# ---------------------------------------------------------------------------
# Spore removal
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("preset", sorted(SPORE_PRESETS))
def test_a_spore_preset_states_the_log_reduction_it_stands_for(preset):
    result = plan(SEED, intervention=Intervention(reduce_spores=preset))
    assert result.body["interventions"]["spore_reduction"] == preset
    resolved = next(r for r in result.resolved_levels if r.named == preset)
    assert resolved.level == SPORE_PRESETS[preset].log_reduction
    assert resolved.source


def test_a_measured_log_reduction_outranks_every_preset():
    """A processor who measured their own removal has to be able to say so."""
    result = plan(SEED, intervention=Intervention(reduce_spores=1.85))
    assert result.body["interventions"]["spore_reduction"] == 1.85
    assert result.resolved_levels == []


def test_a_negative_spore_reduction_is_rejected():
    with pytest.raises(ValidationError):
        Intervention(reduce_spores=-1.0)


def test_a_spore_reduction_in_a_ppc_driven_plant_says_the_benefit_is_masked():
    """Route 4 step 1. Reporting "no change" there is bad advice as a null result."""
    result = plan(
        SEED,
        Facility(plant_category="medium"),
        intervention=Intervention(reduce_spores="microfiltration"),
    )
    assert any("long shelf-life" in note and "masked" in note for note in result.notes)


def test_a_spore_reduction_in_a_long_shelf_life_plant_carries_no_such_note():
    result = plan(
        SEED,
        Facility(plant_category="long"),
        intervention=Intervention(reduce_spores="microfiltration"),
    )
    assert not any("masked" in note for note in result.notes)


# ---------------------------------------------------------------------------
# cool_stage -- read against the chain this same call describes
# ---------------------------------------------------------------------------

def test_cooling_a_stage_by_degrees_is_read_against_the_shipped_baseline():
    """No facility in the call, so the chain is the shipped one."""
    sent = applied(Intervention(cool_stage={"retail": {"by": 2.0}}))
    assert sent["stage_temp_overrides"]["retail"] == {"temp_delta": -2.0}


def test_cooling_a_stage_by_degrees_is_read_against_the_processors_own_level():
    """Their retail runs at 4.0, so two degrees colder is 2.0 -- a shift of -4.5."""
    sent = applied(
        Intervention(cool_stage={"retail": {"by": 2.0}}),
        Facility(stage_temperatures={"retail": {"shift": -2.5}}),
    )
    assert sent["stage_temp_overrides"]["retail"]["temp_delta"] == pytest.approx(-4.5)


def test_cooling_to_a_temperature_states_it_as_an_offset_not_a_flat_line():
    sent = applied(Intervention(cool_stage={"retail": {"to": 4.0}}))
    override = sent["stage_temp_overrides"]["retail"]
    assert "temp_mean" not in override
    assert override["temp_delta"] == pytest.approx(4.0 - BASELINE["retail"]["level"])


def test_cooling_a_stage_the_processor_described_as_constant_keeps_it_constant():
    sent = applied(
        Intervention(cool_stage={"retail": {"by": 1.0}}),
        Facility(stage_temperatures={"retail": {"flat": 4.0}}),
    )
    assert sent["stage_temp_overrides"]["retail"] == {"temp_mean": 3.0, "temp_sd": 0}


def test_a_cool_stage_that_would_warm_the_stage_is_rejected_and_names_the_other_tool():
    """ADR 003: interventions are improvements only."""
    with pytest.raises(ValueError, match="model_a_disruption"):
        applied(
            Intervention(cool_stage={"retail": {"to": 5.0}}),
            Facility(stage_temperatures={"retail": {"shift": -2.5}}),
        )


def test_a_ceiling_composes_with_a_stated_level_rather_than_replacing_it():
    """The API applies temp_delta first, then clamps at temp_max."""
    sent = applied(
        Intervention(cool_stage={"retail": {"cap": 6.0}}),
        Facility(stage_temperatures={"retail": {"shift": -0.5}}),
    )
    assert sent["stage_temp_overrides"]["retail"] == {
        "temp_delta": pytest.approx(-0.5),
        "temp_max": 6.0,
    }


def test_a_ceiling_only_lowers_an_existing_one():
    sent = applied(
        Intervention(cool_stage={"retail": {"cap": 5.0}}),
        Facility(stage_temperatures={"retail": {"cap": 6.0}}),
    )
    assert sent["stage_temp_overrides"]["retail"] == {"temp_max": 5.0}


def test_raising_an_existing_ceiling_is_rejected():
    with pytest.raises(ValueError, match="model_a_disruption"):
        applied(
            Intervention(cool_stage={"retail": {"cap": 8.0}}),
            Facility(stage_temperatures={"retail": {"cap": 6.0}}),
        )


def test_cooling_by_degrees_from_a_stage_stated_only_as_a_ceiling_is_rejected():
    """A ceiling is not a level, so there is nothing to subtract two degrees from.

    It is an upper bound on one: clamping the peaks lowers the mean by an amount
    only the measured profile knows, so subtracting from it would report a
    two-degree cooling while delivering less.
    """
    with pytest.raises(ValueError, match="State `to`"):
        applied(
            Intervention(cool_stage={"retail": {"by": 2.0}}),
            Facility(stage_temperatures={"retail": {"cap": 6.0}}),
        )


def test_the_escape_that_rejection_names_actually_works():
    """`to` states the level outright, so it is answerable where `by` is not.

    The rejection above sends the caller to `to`, and a message naming a remedy
    that lands back on the same rejection is worse than one naming none.
    """
    sent = applied(
        Intervention(cool_stage={"retail": {"to": 4.0}}),
        Facility(stage_temperatures={"retail": {"cap": 6.0}}),
    )
    assert sent["stage_temp_overrides"]["retail"] == {
        "temp_delta": pytest.approx(4.0 - BASELINE["retail"]["level"]),
        "temp_max": 6.0,
    }


def test_a_target_at_a_binding_ceiling_is_not_reported_as_a_warming():
    """Codex P2 on PR #62. Two rejections wear one shape, and one was mislabelled.

    A `to` sitting at or above a binding ceiling is not a stage running warmer,
    so pointing the caller at model_a_disruption misroutes them. The rejection
    itself stands: measured at the widest target a ceiling absorbs, shelf life,
    consumer days, retail spoilage and CO2e are all identical and the daily curve
    moves at most 1 pp on one interior day -- and on the three stages shipping a
    constant profile the clamp absorbs the shift exactly.
    """
    with pytest.raises(ValueError) as raised:
        applied(
            Intervention(cool_stage={"retail": {"to": 6.0}}),
            Facility(stage_temperatures={"retail": {"cap": 6.0}}),
        )
    assert "model_a_disruption" not in str(raised.value)
    assert "already held at or under 6.0 C" in str(raised.value)
    assert "State a `to` below 6.0 C" in str(raised.value)


def test_a_target_below_a_binding_ceiling_is_a_cooling_the_answer_can_show():
    """The escape the rejection names, and the band that was never rejected."""
    sent = applied(
        Intervention(cool_stage={"retail": {"to": 4.0}}),
        Facility(stage_temperatures={"retail": {"cap": 6.0}}),
    )
    assert sent["stage_temp_overrides"]["retail"] == {
        "temp_delta": pytest.approx(4.0 - BASELINE["retail"]["level"]),
        "temp_max": 6.0,
    }


def test_a_genuine_warming_still_points_at_the_disruption_tool():
    """Their retail runs at 4.0, and 5.0 is warmer -- that one really is a disruption."""
    with pytest.raises(ValueError, match="model_a_disruption"):
        applied(
            Intervention(cool_stage={"retail": {"to": 5.0}}),
            Facility(stage_temperatures={"retail": {"shift": -2.5}}),
        )


def test_cooling_a_stage_says_the_within_stage_shape_is_unchanged():
    """Issue #24, the same limit predict_customize states."""
    result = plan(SEED, intervention=Intervention(cool_stage={"retail": {"by": 2.0}}))
    assert any("within-stage" in note for note in result.notes)


def test_time_added_to_a_stage_is_held_at_the_temperature_the_intervention_leaves_it_at():
    """The processor's stage is longer AND cooled: the added time is spent cold."""
    sent = plan(
        SEED,
        Facility(stage_durations={"retail": 8.0}),
        intervention=Intervention(cool_stage={"retail": {"to": 3.0}}),
    ).body
    assert sent["disruptions"]["retail"]["temp"] == 3.0


def test_exactly_one_of_by_to_and_cap_is_accepted():
    with pytest.raises(ValidationError, match="one of"):
        Intervention(cool_stage={"retail": {"by": 1.0, "to": 4.0}})
    with pytest.raises(ValidationError, match="one of"):
        Intervention(cool_stage={"retail": {}})


def test_cooling_by_a_negative_amount_is_rejected():
    """`by` is how much colder, so a negative reads as a warming."""
    with pytest.raises(ValidationError):
        Intervention(cool_stage={"retail": {"by": -2.0}})


# ---------------------------------------------------------------------------
# What an intervention has to say about itself
# ---------------------------------------------------------------------------

def test_an_empty_intervention_is_rejected():
    """model_an_intervention weighs a change, so there has to be one."""
    with pytest.raises(ValidationError):
        Intervention()


def test_a_published_level_is_offered_for_replacement_rather_than_asserted():
    """ADR 012: state the number, that it is an estimate, and ask for their own."""
    result = plan(SEED, intervention=Intervention(named=["preventative_maintenance"]))
    assert any("estimate" in note and "own" in note for note in result.notes)


def test_an_intervention_changes_no_duration_so_retail_exit_stays_comparable():
    result = plan(SEED, intervention=Intervention(named=["increase_equipment_cleaning"]))
    assert result.pre_consumer_duration_changed is False
