"""One /simulate response, reshaped for an agent rather than for a program.

The API's raw response is shaped for a caller that already knows its
conventions: that -1 means the criterion was never met inside the horizon, that
both economics figures scale with `n_units` while `n_lots` enters neither, that
`pct_spoiled_at_retail` was read at a whole day living in another field. An agent
does not know any of that, and every convention it has to remember is one it can
get wrong.

The types here are the tools' `outputSchema`. Writing them as the responses are
written costs nothing; retrofitting them later costs a pass over six tools.

Shared with issue #58's two tools, which reshape the same response.
"""

from __future__ import annotations

from typing import Any, Optional, Union

from pydantic import BaseModel, Field

from mcp_server.facility import Plan
from mcp_server.intervention import Resolved
from mcp_server.supply_chain import PlantCategory

# The API's own placeholder for "not reached inside the simulated horizon". It
# appears in two fields whose bounds are different numbers, which is why it is
# never simply passed through.
_UNREACHED = -1


def _mapping(value: Any) -> dict[str, Any]:
    """A record R serialised, as an object.

    `toJSON` writes an empty named list as `[]` rather than `{}`, so a run that
    applied nothing returns an array where the schema promises an object. A
    non-empty record always carries names and so always arrives as an object.
    """
    return value if isinstance(value, dict) else {}


def _strings(value: Any) -> list[str]:
    """A character vector R serialised, as a list.

    `toJSON(auto_unbox = TRUE)` unboxes a length-one vector, so one warning
    arrives as a bare string and two arrive as an array. Route 2 tells the agent
    to read `warnings` as a list, so it has to be one at either length.
    """
    if isinstance(value, str):
        return [value]
    return list(value or [])


class Bound(BaseModel):
    """A shelf life the run could not measure, because it ran past the horizon."""

    more_than_days: float = Field(
        description="The criterion was not met by this day, so shelf life exceeds it."
    )
    why: str = Field(description="What the run did, and what to change to get a number.")


class ShelfLife(BaseModel):
    total_days: Union[float, Bound] = Field(
        description=(
            "Days from production until the median lot is more than "
            "`threshold_pct` spoiled. A bound object instead of a number when the "
            "run ended first."
        )
    )
    consumer_days: Union[float, Bound] = Field(
        description="How many of those days are left once the product reaches a consumer."
    )
    pre_consumer_days: float = Field(
        description=(
            "The supply-chain window, the part of shelf life the processor "
            "controls. Rounded to one decimal by the run."
        )
    )
    pre_consumer_day: int = Field(
        description=(
            "The whole day the run evaluates retail exit on. The run floors full "
            "precision, so this is not `pre_consumer_days` rounded -- a window of "
            "8.9546 d reports as 9.0 and the run used day 8."
        )
    )
    threshold_pct: float = Field(
        description=(
            "The share of a lot that has to be spoiled for shelf life to end. A "
            "container counts as spoiled at 6 log10 CFU/mL, which is a different "
            "criterion."
        )
    )
    truncated: bool = Field(
        description=(
            "True when the spoilage criterion was never met inside the horizon, so "
            "both figures above are bounds and the dollar value came back as zero."
        )
    )
    horizon_days: int = Field(
        description="Days simulated from production, which is what bounds a truncated run."
    )


class RetailExit(BaseModel):
    """Spoilage at retail exit, with the day the run measured it on."""

    percent: Optional[float] = Field(
        description=(
            "Containers spoiled when the product left retail, as a percentage of "
            "the lot. Null when the run could not measure it."
        )
    )
    evaluated_on_day: int = Field(description="The whole day this was read at.")
    measured: bool = Field(
        description=(
            "False when retail exit fell outside the simulated horizon. The run "
            "reports zero there as a placeholder, which is not clean product."
        )
    )


class Economics(BaseModel):
    shelf_life_value_usd: float = Field(
        description=(
            "The lot's shelf-life value, at $0.03 per container per consumer day. "
            "Scales with containers per lot; the number of lots enters neither this "
            "nor the emissions, so this describes one simulated lot rather than a plant."
        )
    )
    shelf_life_value_usd_per_container: float = Field(
        description=(
            "The figure above divided by containers per lot. Multiply by the "
            "containers the processor actually produces to reach a plant figure. "
            "The $0.03 is a per-package premium fitted on half-gallon products "
            "only, so it does not convert to another package size."
        )
    )
    co2e_kg: float = Field(
        description=(
            "The lot's emissions from spoilage waste. Scales the same way as the "
            "dollars."
        )
    )
    co2e_kg_per_container: float = Field(
        description=(
            "Emissions per container. Unlike the dollars this converts by volume "
            "exactly, because the run turns containers into litres."
        )
    )
    containers_priced: int = Field(
        description="The containers per lot both raw figures were computed over."
    )
    pct_spoiled_at_retail: RetailExit


class DailyRow(BaseModel):
    day: int
    median_pct: float
    P25: float
    P75: float


class SummaryRow(BaseModel):
    day: int
    median_pct: float
    mean_pct: float
    sd: float
    P5: float
    P95: float


class Comparability(BaseModel):
    """Whether this run's retail-exit figures can be diffed against another run.

    Computable from this run's own scenario, without seeing the other run, so the
    response carries the verdict rather than leaving the agent to derive it. The
    gate is whether the scenario changed a duration in one of the four stages
    `pre_consumer_days` sums: a change there moves the day the run evaluates
    retail exit on, and a later day carries more spoilage for reasons that have
    nothing to do with the scenario.
    """

    pct_spoiled_at_retail_comparable: bool = Field(
        description=(
            "True when this run's `pct_spoiled_at_retail` and `co2e_kg` may be "
            "differenced against another run's. The emissions inherit the "
            "restriction, because the run computes them from that same figure."
        )
    )
    pre_consumer_duration_changed: bool
    stages_changed: list[str] = Field(
        description="The pre-consumer stages whose duration this scenario changed."
    )
    verdict: str


class Scenario(BaseModel):
    """What the run was configured with, in the numbers rather than the names.

    ADR 012 requires a published level to be stated rather than hidden behind a
    name, and two fields carry that here because the names are different kinds.
    `ppc_frequency_range` is the pair a plant category resolved to.
    `resolved_levels` is every other name the call gave -- a named intervention,
    a spore-removal preset -- with the level, the plant action and the
    publication behind it. Neither can be read off `interventions_applied`, which
    is the run's record of the name it was handed.
    """

    seed: int
    lots: int
    containers_per_lot: int
    horizon_days: int
    ppc_frequency_range: tuple[float, float] = Field(
        description=(
            "The two bounds a lot's PPC frequency was drawn from. The pair carries "
            "uncertainty about the facility, realised as one draw per lot."
        )
    )
    ppc_frequency_source: str = Field(description="Where those two bounds came from.")
    plant_category: Optional[PlantCategory] = Field(
        None, description="The category the band above belongs to, when one was used."
    )
    resolved_levels: list[Resolved] = Field(
        default_factory=list,
        description=(
            "Every name this call gave, and the published level it stands for. "
            "Empty when the call stated its levels itself, because a stated level "
            "hides nothing. Worth repeating to a processor with the source, and "
            "worth asking whether they have their own measured figure."
        ),
    )
    interventions_applied: dict[str, Any] = Field(
        default_factory=dict, description="The run's own record of what it applied."
    )
    disruptions_applied: dict[str, Any] = Field(default_factory=dict)


class Prediction(BaseModel):
    """One simulation run, as an answer rather than as an API response."""

    shelf_life: ShelfLife
    economics: Economics
    daily_spoilage: list[DailyRow] = Field(
        description=(
            "One row per simulated day, from 0 to the horizon. The curve the run "
            "derives shelf life from, so any day inside the horizon is readable "
            "off it -- including retail exit, which `spoilage_summary` never reports."
        )
    )
    spoilage_summary: list[SummaryRow] = Field(
        description=(
            "The narrower view, at days 7, 14, 21, 28 and 35 only, and the one "
            "place lot-to-lot spread appears. A day past the horizon is dropped."
        )
    )
    comparability: Comparability
    scenario: Scenario
    warnings: list[str] = Field(
        description="The run's own warnings. Worth repeating to a processor."
    )
    notes: list[str] = Field(
        description="What answering this question had to assume, and the limits of the answer."
    )


_COMPARABLE = (
    "This scenario changed no duration in a pre-consumer stage, so retail exit "
    "falls on the same day a baseline run evaluates it on and the two figures may "
    "be differenced."
)

_NOT_COMPARABLE = (
    "This scenario changed a pre-consumer duration, so it evaluates retail exit "
    "on its own day. Report each run's pct_spoiled_at_retail separately with its "
    "own day named, and take the comparable figure from daily_spoilage at the "
    "baseline's pre_consumer_day instead. co2e_kg inherits the restriction."
)


def _shelf_life(raw: dict[str, Any], horizon: int) -> tuple[ShelfLife, bool]:
    """Shelf life as numbers or as bounds, plus whether the run truncated.

    The two fields do not share one bound. `total_days` counts from production,
    so the horizon bounds it; `consumer_days` counts from the moment the product
    reaches a consumer, so the horizon less the supply-chain window bounds it. At
    the shipped 40-day horizon that is 31.7, not 40.
    """
    pre_consumer = raw["pre_consumer_days"]
    truncated = raw["total_days"] == _UNREACHED

    def bounded(value: float, floor: float) -> Union[float, Bound]:
        if value != _UNREACHED:
            return value
        return Bound(
            more_than_days=round(floor, 1),
            why=(
                f"The median lot never passed {raw['threshold_pct']}% spoiled "
                f"inside the {horizon}-day run, so shelf life is longer than this "
                "rather than shorter. Raise the horizon and run again for a number."
            ),
        )

    return (
        ShelfLife(
            total_days=bounded(raw["total_days"], horizon),
            # Clamped, because a horizon shorter than the supply-chain window
            # leaves this negative -- "more than -4.3 days at the consumer" is
            # not a bound. The run ended before the product reached a consumer at
            # all, and the note reshape() adds for that case says so.
            consumer_days=bounded(raw["consumer_days"], max(0.0, horizon - pre_consumer)),
            pre_consumer_days=pre_consumer,
            pre_consumer_day=raw["pre_consumer_day"],
            threshold_pct=raw["threshold_pct"],
            truncated=truncated,
            horizon_days=horizon,
        ),
        truncated,
    )


def reshape(raw: dict[str, Any], request: Plan) -> Prediction:
    """Turn one /simulate response into the answer shape, given the plan behind it."""
    run = request.run
    horizon = run.days
    containers = run.containers_per_lot
    shelf_life, truncated = _shelf_life(raw["shelf_life"], horizon)
    notes = list(request.notes)

    if truncated:
        notes.append(
            f"The spoilage criterion was never met inside the {horizon}-day "
            "horizon, so the run priced the shelf-life value at 0 rather than "
            "reporting it as unknown. Do not read that as no value, and do not "
            "difference it against another run: raise the horizon until neither "
            "run truncates."
        )

    day = raw["shelf_life"]["pre_consumer_day"]
    measured = 0 <= day <= horizon
    if not measured:
        notes.append(
            f"Retail exit falls on day {day}, past the {horizon}-day horizon, so "
            "the run ended before the product reached the consumer and has no "
            "daily result to read there. It reports retail spoilage as 0 as a "
            "placeholder. Raise the horizon and run again."
        )

    economics = raw["economics"]
    comparable = not request.pre_consumer_duration_changed
    return Prediction(
        shelf_life=shelf_life,
        economics=Economics(
            shelf_life_value_usd=economics["shelf_life_value_usd"],
            shelf_life_value_usd_per_container=economics["shelf_life_value_usd"] / containers,
            co2e_kg=economics["co2e_kg"],
            co2e_kg_per_container=economics["co2e_kg"] / containers,
            containers_priced=containers,
            pct_spoiled_at_retail=RetailExit(
                percent=economics["pct_spoiled_at_retail"] if measured else None,
                evaluated_on_day=day,
                measured=measured,
            ),
        ),
        daily_spoilage=raw["daily_spoilage"],
        spoilage_summary=raw["spoilage_summary"],
        comparability=Comparability(
            pct_spoiled_at_retail_comparable=comparable,
            pre_consumer_duration_changed=request.pre_consumer_duration_changed,
            stages_changed=request.duration_stages,
            verdict=_COMPARABLE if comparable else _NOT_COMPARABLE,
        ),
        scenario=Scenario(
            seed=run.seed,
            lots=run.lots,
            containers_per_lot=containers,
            horizon_days=horizon,
            ppc_frequency_range=request.ppc_frequency_range,
            ppc_frequency_source=request.ppc_frequency_source,
            plant_category=request.plant_category,
            resolved_levels=request.resolved_levels,
            interventions_applied=_mapping(raw["scenario"]["interventions_applied"]),
            disruptions_applied=_mapping(raw["scenario"]["disruptions_applied"]),
        ),
        warnings=_strings(raw["warnings"]),
        notes=notes,
    )
