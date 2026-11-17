"""Route 5 -- disruption scenarios: events, refusals, and the fold.

The refusal checks matter most here. Several of these tools are correct by
refusing, and a refusal that silently succeeds is the worst failure mode,
because it looks like an answer. Each refusal is asserted to carry the numbers
it claims to have computed.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from mcp_server.disruption import Delay, Disruption, Rankable, ThermalEvent
from mcp_server.facility import ExtraLeg, Facility, Run, StageTemperature, plan
from mcp_server.supply_chain import (
    BUCHANAN_T0,
    FOLD_TMIN,
    Reading,
    growth_equivalent_temperature,
)
from skill_harness import live
from skill_harness.claims import claim

DOC = "routes/5-disruption-scenarios.md"
FACILITY_DOC = "docs/demonstration/facility.md"

RUN = Run(seed=42)

# The two traces facility.md records, hours = the table's days x 24. Route 5's
# 27.7% / 10.5% claim says "its own two traces", and these are them.
NORMAL_HOLD = [
    (0.00, 3.8), (0.02, 6.9), (0.05, 8.4), (0.08, 6.1), (0.12, 4.2),
    (0.20, 2.9), (0.35, 2.6), (0.60, 2.5), (0.90, 2.7), (1.20, 2.6),
    (1.50, 2.8), (1.70, 3.1), (1.80, 6.8), (1.88, 7.9), (1.94, 6.2),
    (2.00, 4.1),
]
FAULT = [
    (0.00, 3.8), (0.02, 6.9), (0.05, 8.4), (0.08, 6.1), (0.12, 4.2),
    (0.20, 2.9), (0.35, 2.6), (0.55, 2.7), (0.70, 5.4), (0.90, 8.6),
    (1.10, 11.3), (1.25, 12.1), (1.30, 11.8), (1.45, 8.2), (1.60, 5.1),
    (1.70, 3.4), (1.80, 6.8), (1.88, 7.9), (1.94, 6.2), (2.00, 4.1),
]


def readings(trace):
    return [Reading(hours=day * 24, celsius=celsius) for day, celsius in trace]


def growth(temperature: float, tmin: float = FOLD_TMIN) -> float:
    """Implied growth, up to a constant: exactly quadratic in (T - Tmin)."""
    return (temperature - tmin) ** 2


def naive_mean(trace) -> float:
    return sum(celsius for _, celsius in trace) / len(trace)


def time_weighted_mean(trace) -> float:
    total = sum(
        (t_b - t_a) * (c_a + c_b) / 2
        for (t_a, c_a), (t_b, c_b) in zip(trace, trace[1:])
    )
    return total / (trace[-1][0] - trace[0][0])


def teq(trace, tmin: float) -> float:
    """The segment rule, written out independently of the module under test."""
    integral = sum(
        (t_b - t_a) * ((c_a - tmin) ** 2 + (c_a - tmin) * (c_b - tmin) + (c_b - tmin) ** 2) / 3
        for (t_a, c_a), (t_b, c_b) in zip(trace, trace[1:])
    )
    return tmin + (integral / (trace[-1][0] - trace[0][0])) ** 0.5


# ---------------------------------------------------------------------------
# The two parameters
# ---------------------------------------------------------------------------

def test_both_durations_are_appended_segments_and_positive():
    with claim(
        DOC,
        "Eight hours is `days: 0.333`. Both durations are the length of an "
        "appended segment, so both are positive.",
    ):
        with pytest.raises(ValidationError):
            ThermalEvent(stage="retail", celsius=12.0, days=-0.333)
        with pytest.raises(ValidationError):
            Delay(stage="retail", days=0)


def test_a_thermal_event_lengthens_the_stage_and_the_notes_name_both_lengths():
    with claim(
        DOC,
        "The response's `notes` name the stage's length before and after; repeat that.",
    ):
        request = plan(
            RUN,
            disruption=Disruption(
                thermal_events=[ThermalEvent(stage="retail", celsius=12.0, days=0.5)]
            ),
        )
        assert any("from 5.4583 d to 5.9583 d" in note for note in request.notes)

        # ADR 017: the lengths are this call's own chain, not the shipped one.
        shortened = plan(
            RUN,
            Facility(stage_durations={"retail": 2.0}),
            disruption=Disruption(
                thermal_events=[ThermalEvent(stage="retail", celsius=12.0, days=0.5)]
            ),
        )
        assert any("from 2.0 d to 2.5 d" in note for note in shortened.notes)


def test_a_delay_is_exact_and_lands_at_the_end_of_the_stage():
    with claim(
        DOC,
        "| a **delay** | appends the waiting time at the end of the stage | "
        "**exact** — the added time is real |",
    ):
        request = plan(
            RUN,
            disruption=Disruption(delays=[Delay(stage="retail", days=1.0, celsius=6.0)]),
        )
        assert any("exact rather than an approximation" in n for n in request.notes)


def test_a_delay_naming_no_temperature_is_held_at_this_calls_own_level():
    with claim(
        DOC,
        "A delay may omit `celsius`, and then the wait is held at the level "
        "that stage runs at in this call's own chain — the right reading for "
        "product that simply stayed where it was, and the `notes` say which "
        "temperature was used.",
    ):
        colder = plan(
            RUN,
            Facility(stage_temperatures={"retail": StageTemperature(shift=-2.5)}),
            disruption=Disruption(delays=[Delay(stage="retail", days=1.0)]),
        )
        assert colder.body["disruptions"]["retail"]["temp"] == 4.0
        assert any("held at 4.0 C" in note for note in colder.notes)


def test_a_standing_condition_is_recorded_as_the_plant_not_an_incident():
    with claim(
        DOC,
        '"Our retail cases run two degrees warm" is a standing condition '
        "rather than an incident, so it goes in `facility.stage_temperatures` "
        "as a positive `shift` and the call is `predict_customize`.",
    ):
        request = plan(
            RUN, Facility(stage_temperatures={"retail": StageTemperature(shift=2.0)})
        )
        assert any(
            "the plant described, not an incident" in note for note in request.notes
        )


# ---------------------------------------------------------------------------
# Two events on one stage: the refusal, carrying its computed ranking
# ---------------------------------------------------------------------------

def test_two_events_on_one_stage_are_rejected_with_the_computed_ranking():
    with claim(
        DOC,
        "it **rejects the call** and hands back the ranking already computed "
        "at both reference temperatures the model carries, plus the direction "
        "each metric then bounds.",
    ):
        events = [
            ThermalEvent(stage="retail", celsius=20.0, days=0.25),
            ThermalEvent(stage="retail", celsius=6.0, days=1.0),
        ]
        with pytest.raises(ValidationError) as caught:
            Disruption(thermal_events=events)
        message = str(caught.value)
        for tmin in (FOLD_TMIN, BUCHANAN_T0):
            assert str(tmin) in message
            for event in events:
                score = Rankable(event.days, event.celsius).score(tmin)
                assert f"{score:.1f}" in message, (
                    f"the refusal does not carry its own computed score "
                    f"{score:.1f} at Tmin {tmin}"
                )
        assert "spoilage % is a lower bound" in message
        assert "total and consumer shelf life are an upper bound" in message


def test_when_the_orderings_agree_the_refusal_names_the_dominant_event():
    with claim(
        DOC,
        "**The orderings agree.** It names the dominant event. Model that one "
        "alone on the stage, say the other is not in the run, and state the "
        "bound direction **per metric**",
    ):
        with pytest.raises(ValidationError) as caught:
            Disruption(
                thermal_events=[ThermalEvent(stage="retail", celsius=20.0, days=0.1)],
                delays=[Delay(stage="retail", days=10.0, celsius=6.0)],
            )
        message = str(caught.value)
        assert "dominant event" in message
        # Ranked by duration x (T - Tmin)^2, the long cool hold beats the short
        # hot excursion -- which is why temperature alone is the wrong test.
        assert "`10.0 d at 6.0 C` is the dominant event" in message


def test_when_the_orderings_disagree_the_refusal_says_not_to_pick():
    with claim(
        DOC,
        "**The orderings disagree.** The refusal states how much of the pair's "
        "added growth the omitted event carries. Do not pick.",
    ):
        # Chosen so the two reference temperatures order the pair differently:
        # at -4.15 the long cool hold wins, at -3.62 the short warm one does.
        first = Rankable(1.0, 10.0)
        second = Rankable(2.45, 5.0)
        assert first.score(FOLD_TMIN) < second.score(FOLD_TMIN)
        assert first.score(BUCHANAN_T0) > second.score(BUCHANAN_T0)

        with pytest.raises(ValidationError) as caught:
            Disruption(
                thermal_events=[
                    ThermalEvent(stage="retail", celsius=10.0, days=1.0),
                    ThermalEvent(stage="retail", celsius=5.0, days=2.45),
                ]
            )
        message = str(caught.value)
        assert "orderings disagree" in message
        assert "Do not pick" in message
        worst_loss = min(
            max(
                other.score(tmin) / (kept.score(tmin) + other.score(tmin))
                for tmin in (FOLD_TMIN, BUCHANAN_T0)
            )
            for kept, other in [(first, second), (second, first)]
        )
        assert f"{worst_loss:.0%}" in message


def test_two_events_in_different_stages_are_one_exact_call():
    with claim(
        DOC,
        "Put each event on the stage it happened in. Two events in "
        "**different** stages is one call, and it is exact.",
    ):
        request = plan(
            RUN,
            disruption=Disruption(
                thermal_events=[
                    ThermalEvent(stage="processing_facility", celsius=18.0, days=0.3)
                ],
                delays=[
                    Delay(
                        stage="transportation_facility_to_retail",
                        days=0.5,
                        celsius=12.0,
                    )
                ],
            ),
        )
        assert set(request.body["disruptions"]) == {
            "processing_facility",
            "transportation_facility_to_retail",
        }


# ---------------------------------------------------------------------------
# A leg the five stages do not have
# ---------------------------------------------------------------------------

def test_a_constant_leg_folds_exactly():
    with claim(
        DOC,
        "**The fold is exact for a leg held at one temperature**, because "
        "growth depends on the temperature-time series and not on the stage "
        "labels drawn over it.",
    ):
        leg = ExtraLeg(after="transportation_facility_to_retail", days=3, celsius=5)
        assert leg.folded() == (3, 5)


def test_a_leg_states_one_shape_and_readings_carry_their_own_duration():
    with claim(DOC, "The readings carry their own duration, so omit `days`."):
        pair = [Reading(hours=0, celsius=3.8), Reading(hours=12, celsius=8.4)]
        with pytest.raises(ValidationError):
            ExtraLeg(after="retail", readings=pair, days=2.0)
        with pytest.raises(ValidationError):
            ExtraLeg(after="retail", readings=pair, celsius=5.0, days=2.0)
        with pytest.raises(ValidationError):
            ExtraLeg(after="retail")
        with pytest.raises(ValidationError):
            ExtraLeg(after="retail", celsius=5.0)


def test_a_measured_leg_folds_by_the_simulators_own_segment_rule():
    with claim(
        DOC,
        "**A leg whose temperature varies goes in as the measured series "
        "instead**, and the tool folds it at the growth-equivalent temperature "
        "by the simulator's own segment rule",
    ):
        # A single 24-hour ramp, checked against the exact integral of the
        # squared displacement -- written out here rather than imported.
        ramp = [(0.0, 0.0), (1.0, 10.0)]
        leg = ExtraLeg(after="retail", readings=readings(ramp))
        days, folded_at = leg.folded()
        assert days == pytest.approx(1.0)
        assert folded_at == pytest.approx(teq([(0.0, 0.0), (24.0, 10.0)], FOLD_TMIN))
        assert folded_at == pytest.approx(
            growth_equivalent_temperature(readings(ramp))
        )


def test_the_repositorys_two_traces_break_a_naive_mean_in_opposite_directions():
    with claim(
        DOC,
        "This repository measured both directions on its own two traces: the "
        "naive mean overstated growth by **27.7%** on one and understated it "
        "by **10.5%** on the other.",
    ):
        # Both figures are ratios of the larger growth to the smaller: the
        # naive mean implies 27.7% more growth than the normal hold has, and
        # the fault has 10.5% more growth than its naive mean implies.
        normal_teq = growth_equivalent_temperature(readings(NORMAL_HOLD))
        fault_teq = growth_equivalent_temperature(readings(FAULT))
        overstated = growth(naive_mean(NORMAL_HOLD)) / growth(normal_teq) - 1
        understated = growth(fault_teq) / growth(naive_mean(FAULT)) - 1
        assert round(overstated * 100, 1) == 27.7
        assert round(understated * 100, 1) == 10.5


def test_the_traces_match_every_figure_facility_md_records():
    with claim(
        FACILITY_DOC,
        "| **`T_eq` at `Tmin` = −4.15** | **3.594 °C** | **6.967 °C** |",
    ):
        assert round(growth_equivalent_temperature(readings(NORMAL_HOLD)), 3) == 3.594
        assert round(growth_equivalent_temperature(readings(FAULT)), 3) == 6.967
    with claim(FACILITY_DOC, "| `T_eq` at `Tmin` = −3.62 | 3.605 °C | 6.988 °C |"):
        hours = lambda trace: [(d * 24, c) for d, c in trace]  # noqa: E731
        assert round(teq(hours(NORMAL_HOLD), BUCHANAN_T0), 3) == 3.605
        assert round(teq(hours(FAULT), BUCHANAN_T0), 3) == 6.988
    with claim(FACILITY_DOC, "| Naive mean of the readings | 4.600 °C | 6.425 °C |"):
        assert round(naive_mean(NORMAL_HOLD), 3) == 4.600
        assert round(naive_mean(FAULT), 3) == 6.425
    with claim(FACILITY_DOC, "| Time-weighted mean | 3.442 °C | 6.545 °C |"):
        assert round(time_weighted_mean(NORMAL_HOLD), 3) == 3.442
        assert round(time_weighted_mean(FAULT), 3) == 6.545
    with claim(
        FACILITY_DOC,
        "The tool folds the normal hold at **3.594 °C** and the fault at "
        "**6.967 °C**, which raises the leg's implied growth by **2.06×**.",
    ):
        ratio = growth(growth_equivalent_temperature(readings(FAULT))) / growth(
            growth_equivalent_temperature(readings(NORMAL_HOLD))
        )
        assert round(ratio, 2) == 2.06


def test_a_time_weighted_mean_always_loses_growth():
    with claim(
        DOC,
        "A time-weighted mean always loses growth, so it overpredicts shelf life.",
    ):
        for trace in (NORMAL_HOLD, FAULT):
            assert time_weighted_mean(trace) < growth_equivalent_temperature(
                readings(trace)
            )


def test_a_measured_fold_is_named_in_the_notes_as_close_not_exact():
    with claim(
        DOC,
        "The response states the temperature the leg folded at and the implied "
        "growth that temperature carries, and says the fold is close rather "
        "than exact, because the non-PPC pathways carry their own reference "
        "temperatures.",
    ):
        request = plan(
            RUN,
            Facility(
                extra_legs=[
                    ExtraLeg(
                        after="transportation_facility_to_retail",
                        readings=readings(NORMAL_HOLD),
                    )
                ]
            ),
        )
        assert any(
            "growth-equivalent temperature of 3.59 C" in note for note in request.notes
        )
        assert any("Close rather than exact" in note for note in request.notes)


def test_the_fold_note_reports_the_implied_growth_it_carries():
    with claim(
        DOC,
        "Two folds of the same leg — a normal hold against a faulted one — "
        "compare by the ratio of their implied-growth figures, both read from "
        "the notes; `(T_eq − Tmin)²` is never computed client-side.",
    ):
        figures = []
        for trace in (NORMAL_HOLD, FAULT):
            request = plan(
                RUN,
                Facility(
                    extra_legs=[
                        ExtraLeg(
                            after="transportation_facility_to_retail",
                            readings=readings(trace),
                        )
                    ]
                ),
            )
            expected = growth(growth_equivalent_temperature(readings(trace)))
            note = next(n for n in request.notes if "implied growth" in n)
            assert f"is {expected:.1f}" in note
            figures.append(expected)
        # The two returned figures reproduce facility.md's 2.06x by division
        # alone -- the squaring already happened server-side.
        assert round(figures[1] / figures[0], 2) == 2.06


def test_an_event_inside_a_leg_cannot_double_as_a_thermal_event():
    with claim(
        DOC,
        "Encoding the fault as a separate temperature-abuse event on the absorbing "
        "stage is rejected, because the leg already holds that stage's one change.",
    ):
        with pytest.raises(ValueError) as caught:
            plan(
                RUN,
                Facility(
                    extra_legs=[
                        ExtraLeg(
                            after="transportation_facility_to_retail",
                            days=2.0,
                            celsius=5.0,
                        )
                    ]
                ),
                disruption=Disruption(
                    thermal_events=[
                        ThermalEvent(
                            stage="transportation_facility_to_retail",
                            celsius=12.1,
                            days=0.75,
                        )
                    ]
                ),
            )
        assert "Attach the leg to a neighbouring stage" in str(caught.value)


def test_the_three_fold_consequences_are_in_the_notes():
    request = plan(
        RUN,
        Facility(
            extra_legs=[
                ExtraLeg(
                    after="transportation_facility_to_retail", days=2.0, celsius=5.0
                )
            ]
        ),
    )
    with claim(
        DOC,
        "**The leg is invisible in the stage breakdown.** `pre_consumer_days` "
        "stays correct, and the per-stage attribution absorbs the leg into its "
        "neighbour rather than showing it separately.",
    ):
        assert any("invisible in the stage breakdown" in n for n in request.notes)
    with claim(
        DOC,
        "**The leg lands in `disruptions_applied`**, because the API splits a "
        "change by direction and added time goes through that door.",
    ):
        assert any("disruptions_applied record" in n for n in request.notes)
    with claim(
        DOC,
        "**The fold uses up that stage's one change.** No event can then be "
        "aimed at the folded leg, or at the stage that absorbed it.",
    ):
        with pytest.raises(ValueError):
            plan(
                RUN,
                Facility(
                    extra_legs=[
                        ExtraLeg(
                            after="transportation_facility_to_retail",
                            days=2.0,
                            celsius=5.0,
                        )
                    ]
                ),
                disruption=Disruption(
                    delays=[
                        Delay(
                            stage="transportation_facility_to_retail",
                            days=0.5,
                            celsius=5.0,
                        )
                    ]
                ),
            )


def test_a_sixth_stage_is_refused():
    with claim(DOC, "Adding a sixth stage is refused by the model deliberately"):
        with pytest.raises(ValidationError):
            ExtraLeg(after="distribution_centre", days=2.0, celsius=5.0)
        with pytest.raises(ValidationError):
            ThermalEvent(stage="dock", celsius=12.0, days=0.5)


# ---------------------------------------------------------------------------
# Pricing the disruption
# ---------------------------------------------------------------------------

def test_an_appended_event_moves_the_pre_consumer_window_and_the_verdict_says_so():
    with claim(
        DOC,
        "an appended event **lengthens the stage it lands on**, so the two "
        "runs can have different pre-consumer windows. The response settles it "
        "— `comparability` says whether the two runs' retail-exit figures may "
        "be differenced, and `stages_changed` names the stages whose duration moved.",
    ):
        request = plan(
            RUN,
            disruption=Disruption(
                thermal_events=[ThermalEvent(stage="retail", celsius=12.0, days=0.5)]
            ),
        )
        assert request.pre_consumer_duration_changed is True
        assert request.duration_stages == ["retail"]


def test_a_pre_merged_event_and_a_hand_averaged_leg_pass_through_silently():
    """The pre-call paths the client cannot see, asserted as acceptances.

    A refusal closes a defect only when the wrong behaviour passes through the
    refusal (issue #33, second comment). An agent that merges two events at
    their mean before the call, or averages a logger trace into `celsius`,
    submits one valid entry -- so these route-5 sentences are the only guard,
    and the harness asserts that the tool indeed cannot fire on them.
    """
    with claim(
        DOC,
        "**Never reduce the series to an average yourself.** An average of any "
        "kind is unsafe, because neither direction of its error is predictable.",
    ):
        # Two events at their time-weighted mean: one valid entry, no refusal.
        Disruption(
            thermal_events=[ThermalEvent(stage="retail", celsius=8.8, days=1.25)]
        )
        # A logger trace hand-averaged to its naive mean: a first-class shape.
        ExtraLeg(
            after="transportation_facility_to_retail",
            days=2.0,
            celsius=naive_mean(NORMAL_HOLD),
        )


def test_a_wrong_duration_key_is_rejected_loudly_not_dropped():
    """Issue #36's silent NULL, closed by the tool surface and pinned here.

    The API read `disruption$duration`, so a delay sent `duration` ran with a
    NULL duration silently. On the tool surface both event shapes require
    `days`, so the old wrong key now fails the call instead of the product.
    """
    with claim(DOC, "Tool: `model_a_disruption(run, disruption, facility?)`."):
        with pytest.raises(ValidationError):
            ThermalEvent(stage="retail", celsius=12.0, duration=0.5)
        with pytest.raises(ValidationError):
            Delay(stage="retail", duration_delta=0.5)


def test_the_verdict_is_against_the_baseline_so_a_shared_leg_marks_both_arms():
    with claim(
        DOC,
        "**The verdict is computed against the New York baseline, never "
        "against the other run.** A leg with no stage, or an event on a "
        "pre-consumer stage, makes **both** runs report not comparable",
    ):
        leg = Facility(
            extra_legs=[
                ExtraLeg(
                    after="transportation_facility_to_retail", days=2.0, celsius=3.594
                )
            ]
        )
        baseline_arm = plan(RUN, leg)
        scenario_arm = plan(
            RUN,
            leg,
            disruption=Disruption(
                delays=[Delay(stage="retail", days=0.5, celsius=6.0)]
            ),
        )
        assert baseline_arm.pre_consumer_duration_changed is True
        assert scenario_arm.pre_consumer_duration_changed is True


# ---------------------------------------------------------------------------
# Live -- the procedures and the refusals, over the wire
# ---------------------------------------------------------------------------

def test_live_a_mixed_two_stage_disruption_is_one_run(target):
    with claim(
        DOC,
        "One call carries both, so a chiller tripping at the plant and the "
        "load then waiting for a truck is **one run** rather than two.",
    ):
        result = live.call(
            target,
            "model_a_disruption",
            {
                "run": {"seed": 42, "lots": 2, "containers_per_lot": 10, "days": 14},
                "disruption": {
                    "thermal_events": [
                        {"stage": "processing_facility", "celsius": 18.0, "days": 0.3}
                    ],
                    "delays": [
                        {
                            "stage": "transportation_facility_to_retail",
                            "days": 0.5,
                            "celsius": 12.0,
                        }
                    ],
                },
            },
        )
        applied = result["scenario"]["disruptions_applied"]
        assert set(applied) == {
            "processing_facility",
            "transportation_facility_to_retail",
        }
        assert any("from 2.4264 d to 2.7264 d" in note for note in result["notes"])
        assert any(
            "exact rather than an approximation" in note for note in result["notes"]
        )


def test_live_a_measured_leg_folds_and_the_notes_carry_all_three_consequences(target):
    with claim(
        DOC,
        "Three consequences to state when a leg folds, all of them in the "
        "response's `notes`",
    ):
        result = live.call(
            target,
            "predict_customize",
            {
                "run": {"seed": 42, "lots": 2, "containers_per_lot": 10, "days": 14},
                "facility": {
                    "extra_legs": [
                        {
                            "after": "transportation_facility_to_retail",
                            "readings": [
                                {"hours": day * 24, "celsius": celsius}
                                for day, celsius in NORMAL_HOLD
                            ],
                        }
                    ]
                },
            },
        )
        notes = result["notes"]
        assert any("growth-equivalent temperature of 3.59 C" in n for n in notes)
        assert any("invisible in the stage breakdown" in n for n in notes)
        assert any("disruptions_applied record" in n for n in notes)
        assert result["scenario"]["disruptions_applied"]


def test_live_the_two_event_refusal_reaches_the_agent_with_its_numbers(target):
    """The ranking must survive the wire, not only the validator.

    A refusal that silently succeeds is the worst failure mode; second worst
    is a refusal whose computed ranking is eaten by the transport, leaving the
    agent to re-derive what route 5 forbids it to.
    """
    with claim(
        DOC,
        "**Repeat what the refusal computed.** Do not re-derive the ranking, "
        "and never rank by temperature alone or by duration alone.",
    ):
        events = [
            ThermalEvent(stage="retail", celsius=20.0, days=0.25),
            ThermalEvent(stage="retail", celsius=6.0, days=1.0),
        ]
        refusal = live.refusal(
            target,
            "model_a_disruption",
            {
                "run": {"seed": 42, "lots": 2, "containers_per_lot": 10, "days": 14},
                "disruption": {
                    "thermal_events": [
                        {"stage": e.stage, "celsius": e.celsius, "days": e.days}
                        for e in events
                    ]
                },
            },
        )
        assert "Ranked by duration x (T - Tmin)^2" in refusal
        for tmin in (FOLD_TMIN, BUCHANAN_T0):
            for event in events:
                score = Rankable(event.days, event.celsius).score(tmin)
                assert f"{score:.1f}" in refusal


def test_live_a_warming_intervention_is_refused_naming_the_right_tool(target):
    with claim(
        "routes/4-prevention-strategies.md",
        "Both are read against the chain this same call describes, never an "
        "earlier run, and a target that leaves the stage warmer is rejected.",
    ):
        refusal = live.refusal(
            target,
            "model_an_intervention",
            {
                "run": {"seed": 42, "lots": 2, "containers_per_lot": 10, "days": 14},
                "intervention": {"cool_stage": {"retail": {"to": 8.0}}},
            },
        )
        assert "improvements only" in refusal
        assert "model_a_disruption" in refusal
