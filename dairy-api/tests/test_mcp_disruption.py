"""A disruption a processor is worried about, as a /simulate request body.

Pure, so it runs without a server, a client or an R subprocess.

The rejection this file exists for: **two events on one stage cannot be merged at
their time-weighted mean.** The growth rate squares the temperature displacement,
so the merge always understates growth. Measured in issue #58 -- a 20 C failure
for 0.25 d then 1.0 d at 6 C gives shelf life 9 d and consumer 0.0 d encoded
faithfully, against 10 d and 0.5 d merged. The tool ranks and rejects rather than
picking silently.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from mcp_server.disruption import Disruption
from mcp_server.facility import Facility, Run, plan
from mcp_server.supply_chain import BASELINE, BUCHANAN_T0, FOLD_TMIN

SEED = Run(seed=42)


def sent(disruption: Disruption, facility: Facility | None = None) -> dict:
    return plan(SEED, facility, disruption=disruption).body["disruptions"]


def rejection(**disruption) -> str:
    with pytest.raises(ValueError) as raised:
        Disruption(**disruption)
    return str(raised.value)


# ---------------------------------------------------------------------------
# The two kinds of event, each reaching the API as its own type
# ---------------------------------------------------------------------------

def test_a_thermal_event_becomes_a_temperature_spike():
    """"the cooler failed for eight hours"."""
    assert sent(
        Disruption(thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.25}])
    ) == {"retail": {"type": "temp_spike", "temp": 20.0, "duration": 0.25}}


def test_a_delay_becomes_a_delay_at_the_temperature_the_processor_named():
    """"the load sat on the dock overnight, at fifteen degrees"."""
    assert sent(
        Disruption(
            delays=[
                {
                    "stage": "transportation_facility_to_retail",
                    "days": 0.5,
                    "celsius": 15.0,
                }
            ]
        )
    ) == {
        "transportation_facility_to_retail": {
            "type": "delay",
            "duration_delta": 0.5,
            "temp": 15.0,
        }
    }


def test_a_delay_with_no_temperature_is_held_at_the_stages_own_level():
    """"the truck was late" -- the product waited where it already was."""
    result = plan(SEED, disruption=Disruption(delays=[{"stage": "retail", "days": 1.0}]))
    assert result.body["disruptions"]["retail"]["temp"] == BASELINE["retail"]["level"]
    assert any("named no temperature" in note for note in result.notes)


def test_a_delay_with_no_temperature_follows_the_processors_own_cold_chain():
    """Their retail runs at 4.0, so the wait is a cold one."""
    assert (
        sent(
            Disruption(delays=[{"stage": "retail", "days": 1.0}]),
            Facility(stage_temperatures={"retail": {"shift": -2.5}}),
        )["retail"]["temp"]
        == pytest.approx(4.0)
    )


def test_a_mixed_scenario_is_one_call_across_two_stages():
    """The chiller tripping and then the load waiting for a truck is one scenario.

    Two tools would make it two runs, and two runs cannot represent it -- which
    is why thermal_events and delays are two parameters on one tool.
    """
    body = sent(
        Disruption(
            thermal_events=[
                {"stage": "processing_facility", "celsius": 18.0, "days": 0.3}
            ],
            delays=[
                {
                    "stage": "transportation_facility_to_retail",
                    "days": 0.5,
                    "celsius": 12.0,
                }
            ],
        )
    )
    assert body["processing_facility"]["type"] == "temp_spike"
    assert body["transportation_facility_to_retail"]["type"] == "delay"


def test_an_event_of_zero_length_is_rejected():
    """Both durations are the length of an appended segment, never an offset."""
    with pytest.raises(ValidationError):
        Disruption(thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0}])
    with pytest.raises(ValidationError):
        Disruption(delays=[{"stage": "retail", "days": -1.0}])


def test_a_disruption_stating_no_event_is_rejected():
    with pytest.raises(ValidationError):
        Disruption()


def test_an_unknown_stage_is_rejected_by_the_schema():
    with pytest.raises(ValidationError):
        Disruption(delays=[{"stage": "distribution_centre", "days": 1.0}])


# ---------------------------------------------------------------------------
# Two events on one stage: ranked, then rejected
# ---------------------------------------------------------------------------

def test_two_events_on_one_stage_are_rejected_rather_than_merged():
    message = rejection(
        thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.25}],
        delays=[{"stage": "retail", "days": 1.0, "celsius": 6.0}],
    )
    assert "retail" in message
    assert "merge" in message.lower()


def test_the_rejection_ranks_at_both_reference_temperatures():
    """There is no single reference temperature, so the ranking is computed twice."""
    message = rejection(
        thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.25}],
        delays=[{"stage": "retail", "days": 1.0, "celsius": 6.0}],
    )
    assert str(FOLD_TMIN) in message
    assert str(BUCHANAN_T0) in message


def test_the_rejection_names_the_dominant_event_when_both_orderings_agree():
    """duration x (T - Tmin)^2 ranks them; temperature alone is the wrong test.

    0.25 d at 20 C scores 145.8 against 103.0 for 1.0 d at 6 C at Tmin = -4.15,
    and 139.5 against 92.5 at -3.62. Same order, so the spike dominates.
    """
    message = rejection(
        thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.25}],
        delays=[{"stage": "retail", "days": 1.0, "celsius": 6.0}],
    )
    assert "0.25 d at 20.0 C -> 145.8" in message
    assert "`0.25 d at 20.0 C` is the dominant event" in message


def test_a_long_cool_hold_outranks_a_short_hot_one():
    """Route 5's worked pair: 58 against 1030, an eighteen-fold difference.

    Temperature alone would pick the 20 C spike and drop almost all of the added
    growth. Only the product of duration and squared displacement ranks them.
    """
    message = rejection(
        thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.1}],
        delays=[{"stage": "retail", "days": 10.0, "celsius": 6.0}],
    )
    assert "0.1 d at 20.0 C -> 58.3" in message
    assert "10.0 d at 6.0 C -> 1030.2" in message
    assert "`10.0 d at 6.0 C` is the dominant event" in message


def test_the_rejection_says_which_direction_each_metric_then_bounds():
    """"A floor" about the whole answer is the dangerous mistake.

    The omitted event adds growth the run never sees, so spoilage is a lower
    bound and shelf life an upper one. A processor who hears "floor" about a
    shelf life plans against a number the model overestimates.
    """
    message = rejection(
        thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.25}],
        delays=[{"stage": "retail", "days": 1.0, "celsius": 6.0}],
    )
    assert "lower bound" in message
    assert "upper bound" in message
    assert "at most" in message


def test_orderings_that_disagree_refuse_to_pick_at_all():
    """0.06 d at 20 C against 1.0 d at 2 C: 35.0 v 37.8, then 33.5 v 31.6.

    The choice of reference temperature decides the order, which means the two
    contribute so nearly equally that dropping either loses about half the added
    growth.
    """
    message = rejection(
        thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.06}],
        delays=[{"stage": "retail", "days": 1.0, "celsius": 2.0}],
    )
    assert "disagree" in message
    assert "dominant" not in message
    assert "cannot represent" in message


def test_a_lopsided_reversal_does_not_claim_the_two_events_are_near_equal():
    """Codex P2 on PR #62. A reversal is usually a near-tie; it is not one by law.

    An event within a few hundredths of a degree of a reference temperature has
    its score there collapse towards zero, so the pair can reverse while one
    event carries 98% at both ends -- a different event at each end. "About half"
    is then wrong by a factor of fifty, in the direction that makes the refusal
    sound negotiable. The refusal is right; the number was not.
    """
    message = rejection(
        delays=[{"stage": "retail", "days": 1.0, "celsius": -3.61}],
        thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 9.47e-6}],
    )
    assert "disagree" in message
    assert "about half" not in message
    assert "up to 98% of the pair's added growth" in message


def test_a_genuine_near_tie_still_reports_about_half():
    """The heuristic holds where it is used: every reversal at or above 0 C
    measured across a realistic cold chain splits no worse than 51.8 / 48.2."""
    message = rejection(
        thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.06}],
        delays=[{"stage": "retail", "days": 1.0, "celsius": 2.0}],
    )
    assert "disagree" in message
    assert "up to 51% of the pair's added growth" in message


def test_two_events_of_the_same_kind_on_one_stage_are_rejected_too():
    assert "retail" in rejection(
        thermal_events=[
            {"stage": "retail", "celsius": 20.0, "days": 0.25},
            {"stage": "retail", "celsius": 14.0, "days": 0.5},
        ]
    )


def test_two_events_on_different_stages_are_exact_and_accepted():
    """Check first whether the second event really belongs to the same stage."""
    body = sent(
        Disruption(
            thermal_events=[
                {"stage": "retail", "celsius": 20.0, "days": 0.25},
                {"stage": "consumer", "celsius": 14.0, "days": 0.5},
            ]
        )
    )
    assert set(body) == {"retail", "consumer"}


# ---------------------------------------------------------------------------
# The approximation an appended event carries, and the one it does not
# ---------------------------------------------------------------------------

def test_a_thermal_event_names_the_approximation_it_makes():
    """It lengthens a hold that was happening anyway, rather than replacing time."""
    result = plan(
        SEED,
        disruption=Disruption(
            thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.25}]
        ),
    )
    note = next(note for note in result.notes if "retail" in note)
    assert "lengthens" in note
    assert str(round(BASELINE["retail"]["days"] + 0.25, 4)) in note


def test_the_lengthening_is_measured_from_the_stage_this_call_describes():
    """Their retail hold is 2 d, not the baseline's 5.4583, so the note says 2.

    A stage stated shorter reaches the API through the intervention door and
    leaves the disruption slot free, so the two genuinely coexist -- and a note
    quoting the shipped length would be a wrong number in the one figure a
    processor reads to check what was modelled.
    """
    result = plan(
        SEED,
        Facility(stage_durations={"retail": 2.0}),
        disruption=Disruption(
            thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.5}]
        ),
    )
    note = next(note for note in result.notes if "lengthens" in note)
    assert "from 2.0 d to 2.5 d" in note
    assert str(BASELINE["retail"]["days"]) not in note


def test_a_delay_says_the_added_time_is_real_rather_than_an_approximation():
    result = plan(
        SEED,
        disruption=Disruption(
            delays=[{"stage": "retail", "days": 1.0, "celsius": 12.0}]
        ),
    )
    assert any("exact" in note for note in result.notes)


# ---------------------------------------------------------------------------
# Where a disruption meets a facility on the same stage
# ---------------------------------------------------------------------------

def test_an_event_on_a_stage_the_facility_already_lengthened_is_rejected():
    """The API takes one disruption per stage, and both reach it through that door."""
    with pytest.raises(ValueError, match="one disruption"):
        plan(
            SEED,
            Facility(stage_durations={"retail": 8.0}),
            disruption=Disruption(
                thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.25}]
            ),
        )


def test_an_event_on_a_stage_the_facility_only_cooled_is_accepted():
    """A colder stage is an intervention, so the disruption slot is still free."""
    result = plan(
        SEED,
        Facility(stage_temperatures={"retail": {"shift": -2.5}}),
        disruption=Disruption(delays=[{"stage": "retail", "days": 1.0}]),
    )
    assert result.body["interventions"]["stage_temp_overrides"]["retail"] == {
        "temp_delta": -2.5
    }
    assert result.body["disruptions"]["retail"]["temp"] == pytest.approx(4.0)


# ---------------------------------------------------------------------------
# The comparability verdict every appended event moves
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "disruption",
    [
        Disruption(thermal_events=[{"stage": "retail", "celsius": 20.0, "days": 0.25}]),
        Disruption(delays=[{"stage": "retail", "days": 1.0, "celsius": 6.0}]),
    ],
)
def test_an_appended_event_moves_the_day_retail_exit_is_evaluated_on(disruption):
    """Both types lengthen the stage, so neither leaves retail exit comparable."""
    result = plan(SEED, disruption=disruption)
    assert result.pre_consumer_duration_changed is True
    assert result.duration_stages == ["retail"]


def test_an_event_confined_to_the_consumer_stage_leaves_retail_exit_alone():
    result = plan(
        SEED,
        disruption=Disruption(
            thermal_events=[{"stage": "consumer", "celsius": 20.0, "days": 0.25}]
        ),
    )
    assert result.pre_consumer_duration_changed is False
