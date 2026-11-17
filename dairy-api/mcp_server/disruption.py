"""A disruption a processor is worried about, turned into disruption parameters.

**Why `thermal_events` and `delays` are two parameters on one tool.** The API
implements them identically -- `scenarios/disruptions.R`, differing only in the
parameter name -- but a processor distinguishes them and so must the tool,
because the fidelity differs. Appending a delay is exact, since the added time is
real. Appending temperature abuse to a hold that was happening anyway lengthens
the stage, which is an approximation the answer has to name. Two separate tools
were rejected: the chiller tripping and then the load waiting for a truck is one
scenario across two stages, and two tools would make it two runs and therefore
unmodellable.

**Why two events on one stage are rejected rather than merged.** The API takes
one disruption per stage, and the obvious escape -- merge them at their
time-weighted mean -- always understates growth, because the growth rate squares
the temperature displacement. Measured: a 20 C failure for 0.25 d then 1.0 d at
6 C gives shelf life 9 d and consumer 0.0 d encoded faithfully, against 10 d and
0.5 d merged. So this module computes the ranking, at both reference
temperatures, and hands it back with the rejection. An earlier design made that a
separate `rank_thermal_events` helper tool; a helper the agent must remember to
call is a step it can skip, and arithmetic inside the tool it has to call anyway
cannot be skipped.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Optional

from pydantic import BaseModel, Field, model_validator

from mcp_server.supply_chain import BASELINE, REFERENCE_TEMPERATURES, Stage


class ThermalEvent(BaseModel):
    """A stage running hot for a while: a cooler failing, a trunk left open."""

    stage: Stage = Field(description="The stage the event happened in.")
    celsius: float = Field(
        description=(
            "The temperature the product reached, in Celsius. The processor's own "
            "account -- this has no default."
        )
    )
    days: float = Field(
        gt=0,
        description=(
            "How long it lasted, in days. Eight hours is 0.333. The length of an "
            "appended segment, so it is always positive: a stage running *short* "
            "is a stage_durations statement on the facility."
        ),
    )


class Delay(BaseModel):
    """Product spending longer in a stage than it should have."""

    stage: Stage = Field(description="The stage the product waited in.")
    days: float = Field(
        gt=0, description="How much longer than usual it waited, in days."
    )
    celsius: Optional[float] = Field(
        None,
        description=(
            "The temperature it waited at, in Celsius, when the processor names "
            "one. Omitted, the wait is held at the level that stage runs at in "
            "this call's chain -- which is the right reading for product that "
            "simply stayed where it was."
        ),
    )


@dataclass(frozen=True)
class Rankable:
    """An event reduced to the two things that decide how much growth it adds.

    A temperature-abuse event and a delay rank alike -- both append a segment at one
    temperature for one duration -- so the ranking sees this rather than either
    class. A delay that named no temperature arrives carrying its stage's
    shipped level, because the ranking runs before a facility is in view.
    """

    days: float
    celsius: float

    def score(self, tmin: float) -> float:
        """How much growth it implies, up to a constant.

        Growth rate is exactly quadratic in (T - Tmin), so `duration x
        (T - Tmin)^2` is what ranks two events. Temperature alone is the wrong
        test and duration alone is the wrong test: 0.1 d at 20 C scores 58
        against 1030 for 10 d at 6 C, so the long cool hold dominates the short
        hot one eighteen times over.
        """
        return self.days * (self.celsius - tmin) ** 2

    def __str__(self) -> str:
        return _label(self.days, self.celsius)


class Disruption(BaseModel):
    """One or more adverse events, on the stages they happened in.

    A stage takes one event. Two events on one stage are rejected with the
    ranking, because merging them understates growth every time.
    """

    thermal_events: Optional[list[ThermalEvent]] = Field(
        None,
        min_length=1,
        description=(
            "Events where a stage ran hot. Appended to the end of the stage, "
            "which lengthens it -- an approximation the answer names."
        ),
    )
    delays: Optional[list[Delay]] = Field(
        None,
        min_length=1,
        description=(
            "Waits where product spent longer in a stage than it should have. "
            "Appending the time is exact, because the added time is real."
        ),
    )

    @model_validator(mode="after")
    def _states_an_event(self) -> "Disruption":
        if not self.thermal_events and not self.delays:
            raise ValueError(
                "A disruption has to state at least one event, as thermal_events "
                "or delays or both. To predict the baseline itself, use "
                "predict_default or predict_customize."
            )
        return self

    @model_validator(mode="after")
    def _one_event_per_stage(self) -> "Disruption":
        """Reject a second event on a stage, with the ranking already computed."""
        by_stage: dict[str, list[Rankable]] = {}
        assumed: set[str] = set()
        for event in self.thermal_events or []:
            by_stage.setdefault(event.stage, []).append(
                Rankable(event.days, event.celsius)
            )
        for delay in self.delays or []:
            celsius = delay.celsius
            if celsius is None:
                # The facility is not in view here, so an unnamed wait ranks at
                # its stage's shipped level. Said out loud below, because a plant
                # running colder than the baseline could rank the pair the other
                # way round.
                celsius = BASELINE[delay.stage]["level"]
                assumed.add(delay.stage)
            by_stage.setdefault(delay.stage, []).append(Rankable(delay.days, celsius))

        for stage, events in by_stage.items():
            if len(events) > 1:
                raise ValueError(_ranked_rejection(stage, events, stage in assumed))
        return self

    def events(
        self,
        level_of: Callable[[str], float],
        duration_of: Callable[[str], float],
    ) -> tuple[list[tuple[str, str, dict[str, Any]]], list[str]]:
        """Each event as (stage, what it is, the API spec), plus what to say.

        Both callables answer about the chain **this call** describes rather than
        the shipped baseline, which is ADR 017's whole rule applied to the notes
        as well as to the request. `level_of` gives the temperature a stage runs
        at, which is where a delay naming no temperature is held. `duration_of`
        gives how long it runs, which is what an appended event lengthens: a
        processor whose retail hold is 2 d rather than the baseline's 5.4583
        needs to read "2 d to 2.5 d", and the baseline figure would be wrong in a
        number they act on.
        """
        placed: list[tuple[str, str, dict[str, Any]]] = []
        notes: list[str] = []

        for event in self.thermal_events or []:
            placed.append(
                (
                    event.stage,
                    f"temperature abuse of {_label(event.days, event.celsius)}",
                    {
                        "type": "temp_spike",
                        "temp": event.celsius,
                        "duration": event.days,
                    },
                )
            )
            was = duration_of(event.stage)
            notes.append(
                f"The temperature abuse on {event.stage} is appended to the end of "
                f"that stage and lengthens it from {round(was, 4)} d to "
                f"{round(was + event.days, 4)} d, rather than replacing time "
                f"inside it. So a cooler failing on the third day of a five-day "
                f"hold is modelled as the five-day hold followed by the failure. "
                f"That is the approximation in this run: when the timing inside "
                f"the stage is the point of the question, the model does not "
                f"carry it."
            )

        for delay in self.delays or []:
            celsius = (
                delay.celsius
                if delay.celsius is not None
                else level_of(delay.stage)
            )
            placed.append(
                (
                    delay.stage,
                    f"a delay of {_label(delay.days, celsius)}",
                    {"type": "delay", "duration_delta": delay.days, "temp": celsius},
                )
            )
            notes.append(
                f"The {delay.days} d added to {delay.stage} is time the product "
                f"really spent there, so appending it is exact rather than an "
                f"approximation. It lands at the end of the stage."
            )
            if delay.celsius is None:
                notes.append(
                    f"The delay on {delay.stage} named no temperature, so it is "
                    f"held at {round(celsius, 4)} C -- the level that stage runs "
                    f"at in this call's chain."
                )
        return placed, notes


def _label(days: float, celsius: float) -> str:
    return f"{days} d at {float(celsius)} C"


def _ranked_rejection(
    stage: str, events: list[Rankable], assumed_level: bool
) -> str:
    """The rejection, carrying the ranking rather than a silent pick.

    Ranked at both reference temperatures the model uses, because there is no
    single one: PPC containers use config$Tmin_PPC, the Buchanan pathway uses
    muAtNewTemp()'s own T0, and the high-growth pathway reads its own per
    container. When the two orderings agree there is a dominant event to model.
    When they disagree, the two contribute so nearly equally that the choice of
    reference decides the order -- so dropping either loses about half the added
    growth, and picking one is the wrong move rather than a rough one.
    """
    rankings = []
    orders = []
    for who, tmin in REFERENCE_TEMPERATURES:
        scored = sorted(
            ((event.score(tmin), str(event)) for event in events), reverse=True
        )
        orders.append(tuple(label for _, label in scored))
        rankings.append(
            f"  Tmin = {tmin}, {who}: "
            + "  |  ".join(f"{label} -> {score:.1f}" for score, label in scored)
        )

    if len(set(orders)) == 1:
        verdict = (
            f"Every ordering agrees, so `{orders[0][0]}` is the dominant event: "
            f"model that one alone on this stage, and say the other is not in the "
            f"run."
        )
    else:
        # What the omission actually costs, rather than "about half".
        #
        # A reversal usually IS a near-tie: measured across a realistic dairy
        # cold chain, every reversal at or above 0 C splits the pair no more
        # lopsidedly than 51.8 / 48.2. But it is not one by definition. An event
        # sitting within a few hundredths of a degree of a reference temperature
        # has its score at that reference collapse towards zero, so the pair can
        # reverse while one event carries 98% of the score at BOTH ends -- a
        # different event at each end. "About half" is then false by a factor of
        # fifty, and it is false in the direction that makes the refusal sound
        # more negotiable than it is.
        #
        # So the number is computed. For each event, the worst the omission costs
        # is the largest share the other event carries at either reference; the
        # best available single-event run is whichever event minimises that.
        worst_loss = min(
            max(
                sum(o.score(tmin) for o in events if o is not kept)
                / sum(o.score(tmin) for o in events)
                for _, tmin in REFERENCE_TEMPERATURES
            )
            for kept in events
        )
        verdict = (
            f"The orderings disagree, so the choice of reference temperature "
            f"decides which event is larger. Whichever single event is modelled, "
            f"the omitted one carries up to {worst_loss:.0%} of the pair's added "
            f"growth under one of the two pathways -- so no single-event run "
            f"represents both. Do not pick. Check whether they really belong to "
            f"one stage, and if they do, say plainly that a single-event run "
            f"cannot represent them."
        )

    assumption = (
        f"\nA delay on {stage} named no temperature, so it is ranked at that "
        f"stage's shipped level. A plant running colder could rank the pair the "
        f"other way round; state the wait's own temperature to be sure.\n"
        if assumed_level
        else ""
    )

    return (
        f"Stage {stage!r} carries {len(events)} events, and the API takes one "
        f"disruption per stage. Merging them at their time-weighted mean is not "
        f"the escape: the growth rate squares the temperature displacement, so a "
        f"merged pair always implies less growth than the two segments do. "
        f"Measured -- a 20 C failure for 0.25 d then 1.0 d at 6 C -- the merge "
        f"bought a day of shelf life that does not exist and turned 'no consumer "
        f"shelf life left' into 'half a day left'.\n"
        f"\nRanked by duration x (T - Tmin)^2, at both reference temperatures the "
        f"model carries:\n"
        + "\n".join(rankings)
        + f"\n{assumption}\n{verdict}\n"
        f"\nIf one event is modelled and the other omitted, the omitted one adds "
        f"growth the run never sees, so the two figures bound in opposite "
        f"directions: spoilage % is a lower bound, at least this much spoiled, and "
        f"total and consumer shelf life are an upper bound, at most this many "
        f"days. Saying 'a floor' about the whole answer is the dangerous mistake.\n"
        f"\nIf the events belong to different stages, put each on its own stage. "
        f"That is exact, and one call carries both."
    )
