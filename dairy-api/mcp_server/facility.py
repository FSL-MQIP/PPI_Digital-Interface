"""A processor's plant, turned into a /simulate request body.

The mismatch this module exists to fix, from ADR 015. **The API splits a change
by direction** -- colder or shorter is an `intervention`, warmer or longer a
`disruption`. **A processor splits it by purpose**: this is my plant, against
this is a change I am weighing. Those are different axes and the API carries one.

So `facility` describes the plant in either direction and this module picks the
API door by sign. The worked failure it prevents: "our retail cases run at 4
degrees, not the 6.5 you assume" describes a facility while asking a shelf-life
question, and the parameter that carries it lives under `interventions`. The
natural reading of "runs at 4" is `temp_mean: 4.0`, which replaces the New
York baseline's measured trace with a flat line and reports growth for a case
that never varies.
The correct key is `temp_delta: -2.5`.

`shift`, `flat` and `cap` are named for what happens to the stage's measured
shape, which is the choice `temp_delta` against `temp_mean` against `temp_max`
hides behind key names. `shift` is the default.

`plan()` builds a body and says what building it assumed. It runs no simulation
and makes no request; the one thing it reads outside its arguments is the call
timeout, which `Run` bounds a run size against before that run is sent.

**It takes the whole scenario, not only the facility** -- `intervention` and
`disruption` too, whose own shapes live in intervention.py and disruption.py. The
three cannot be mapped separately, because the API takes **one disruption per
stage** and all three can claim it: a facility stating a stage longer, and a
disruption putting temperature abuse on that same stage, are two claims only a
function seeing both can reject. So the arbitration is here, and the module is
named for the argument that carries most of it rather than for everything it now
maps. `scenario.py` would name it honestly, and that rename is worth doing on its
own rather than inside the commit that made it true.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Annotated, Any, Optional

from pydantic import BaseModel, Field, model_validator

from mcp_server import api
from mcp_server.disruption import Disruption
from mcp_server.intervention import Intervention, Resolved, StageCooling
from mcp_server.supply_chain import (
    BASELINE,
    DEFAULT_PLANT_CATEGORY,
    FOLD_TMIN,
    PPC_BANDS,
    PRE_CONSUMER_STAGES,
    STAGES,
    PlantCategory,
    Reading,
    Stage,
    category_for_prevalence,
    growth_equivalent_temperature,
)

# Measured on the free CPU-basic Space: the production default -- 10 lots x 100
# containers x 40 days -- takes about 40 seconds. Cost is close enough to linear
# in all three for a guard, and a guard is what this is: a run the client will
# abandon mid-flight returns a timeout naming nothing, where this names the size
# and the limit.
_SECONDS_PER_CONTAINER_DAY = 40.0 / (10 * 100 * 40)

# A PPC frequency is a proportion, and above 1 the run dies rather than
# saturating. run_model.R:142 takes `num_ppc <- round(P_ppc * n_unit)` and then
# `num_non_ppc <- n_unit - num_ppc`, so a frequency of 1.2 at 100 containers asks
# for `rep("non_PPC", -20)`. Measured: `Error in rep("non_PPC", num_non_ppc) :
# invalid 'times' argument`, which /simulate returns as an HTTP 500.
#
# The mistake to make here is a percentage. `type_lot_samples` returns a
# proportion, but route 2 states every published band as a percentage -- 0-33%,
# 34-66%, 67-100% -- so a processor saying "our lots came back at 45% and 60%"
# reads naturally as [45, 60]. Same shape as the raw plate count MAX_LOG10_COUNT
# exists for: the bound is the backstop, and the field description is what
# prevents the call.
Proportion = Annotated[float, Field(ge=0, le=1)]


class Run(BaseModel):
    """How much to simulate, and the seed that makes two runs comparable."""

    seed: int = Field(
        description=(
            "Random seed. Required, and reported back: two runs compared against "
            "each other have to share it, because at ten lots the Monte Carlo "
            "noise between two independent draws is not small next to the effect "
            "being measured."
        )
    )
    lots: int = Field(
        10, ge=1, le=100, description="Production lots simulated. The shipped default is 10."
    )
    containers_per_lot: int = Field(
        100,
        ge=1,
        le=1000,
        description=(
            "Containers in each lot, every one a half-gallon. The shipped default "
            "is 100. Both economics figures scale with this and with nothing else, "
            "so raising it for a steadier estimate also raises the reported dollars."
        ),
    )
    days: int = Field(
        40,
        ge=1,
        le=365,
        description=(
            "Days simulated from production. The shipped default is 40. A shelf "
            "life that runs past this comes back as a bound rather than a number, "
            "so raise it and run again when that happens."
        ),
    )

    @model_validator(mode="after")
    def _fits_the_call(self) -> "Run":
        estimate = self.lots * self.containers_per_lot * self.days * _SECONDS_PER_CONTAINER_DAY
        limit = api.timeout()
        if estimate > limit:
            raise ValueError(
                f"{self.lots} lots x {self.containers_per_lot} containers x "
                f"{self.days} days is roughly {estimate:.0f} seconds of simulation, "
                f"and this call gives up at {limit:.0f} seconds. The default "
                f"10 x 100 x 40 takes about 40. Cut the run size, or the horizon."
            )
        return self


class StageTemperature(BaseModel):
    """What a processor's stage does to the baseline's measured shape.

    State one key.

    `shift` is the default, and the one a stated level belongs in: it moves the
    measured trace to the processor's temperature and keeps its shape. `flat` and
    `cap` are for the two cases that shape is genuinely wrong for -- a stage that
    does not vary, and a stage held under a ceiling.
    """

    shift: Optional[float] = Field(
        None,
        description=(
            "Degrees Celsius this stage runs above or below the New York baseline, "
            "signed. Keeps the measured within-stage shape and moves the whole of "
            "it, so a stage a processor describes as 'running at 4' with a "
            "baseline of 6.5 is a shift of -2.5."
        ),
    )
    flat: Optional[float] = Field(
        None,
        description=(
            "Degrees Celsius this stage holds constant. Replaces the measured "
            "shape with one value, so the daily door-opening and defrost cycle "
            "in the baseline's measured trace disappears. For a stage that "
            "genuinely does not vary."
        ),
    )
    cap: Optional[float] = Field(
        None,
        description=(
            "Degrees Celsius this stage never exceeds. Keeps the measured shape "
            "below the ceiling and flattens the peaks above it."
        ),
    )

    @model_validator(mode="after")
    def _exactly_one(self) -> "StageTemperature":
        stated = [k for k in ("shift", "flat", "cap") if getattr(self, k) is not None]
        if len(stated) != 1:
            raise ValueError(
                "State exactly one of shift, flat or cap for a stage. Got "
                + (", ".join(stated) if stated else "none")
                + "."
            )
        return self

    def level(self, baseline: float) -> float:
        """The temperature the stage runs at once this statement applies.

        Time added to a stage is spent at the stage's own level, so a colder
        plant's extra hours are cold ones.

        A `cap` is the one that cannot be answered exactly: clamping the peaks
        lowers the stage's mean by an amount only the profile knows, so this
        returns an upper bound on it. That errs warm, which errs towards more
        growth and a shorter predicted shelf life, and plan() says so.
        """
        if self.flat is not None:
            return self.flat
        if self.shift is not None:
            return baseline + self.shift
        assert self.cap is not None  # _exactly_one
        return min(baseline, self.cap)


class ExtraLeg(BaseModel):
    """A leg of the processor's chain the five shipped stages do not have.

    A distribution centre, a second retail hold, a cross-dock. The model fixes
    the chain at five stages with fixed names, so the leg is folded into the
    stage it follows.

    **The folding is exact; reducing a measured leg to one temperature is not.**
    Encoding the leg inside a neighbour's series loses nothing, because growth
    depends on the temperature-time series and not on the stage labels drawn over
    it -- so a leg held at one temperature is modelled exactly. A `readings`
    series has to become one temperature first, and that step is close rather
    than exact: see `growth_equivalent_temperature`.
    """

    after: Stage = Field(description="The shipped stage this leg comes directly after.")
    days: Optional[float] = Field(
        None,
        gt=0,
        description=(
            "How long the leg lasts. State it with `celsius`; `readings` carry "
            "their own."
        ),
    )
    celsius: Optional[float] = Field(
        None, description="The one temperature the leg is held at."
    )
    readings: Optional[list[Reading]] = Field(
        None,
        min_length=2,
        description=(
            "A measured series, when the leg's temperature varies. Folded at the "
            "growth-equivalent temperature by the simulator's own segment rule, "
            "never at the arithmetic mean -- a mean loses growth and so "
            "overpredicts shelf life."
        ),
    )

    @model_validator(mode="after")
    def _one_shape(self) -> "ExtraLeg":
        if (self.celsius is None) == (self.readings is None):
            raise ValueError(
                "A leg is either held at one temperature or measured as a series: "
                "state celsius or readings, not both and not neither."
            )
        if self.readings is not None and self.days is not None:
            raise ValueError(
                "readings carry their own times, so the leg's duration comes from "
                "them. Omit days."
            )
        if self.celsius is not None and self.days is None:
            raise ValueError("A leg held at one temperature needs its days.")
        return self

    def folded(self) -> tuple[float, float]:
        """The leg as (days, temperature) the API can append to a stage."""
        if self.celsius is not None:
            assert self.days is not None  # _one_shape
            return self.days, self.celsius
        assert self.readings is not None  # _one_shape
        hours = [r.hours for r in self.readings]
        return (
            (max(hours) - min(hours)) / 24,
            growth_equivalent_temperature(self.readings),
        )


class Facility(BaseModel):
    """The processor's own cold chain and their own PPC frequency.

    Every field is optional, and an omitted one keeps the shipped New York baseline.
    """

    plant_category: Optional[PlantCategory] = Field(
        None,
        description=(
            "The processor's own shelf-life history, as one of three categories Su "
            "et al. fitted PPC frequency bands to. Answerable without any "
            "laboratory work, which is why it is the better opening question than "
            "'what is your PPC prevalence'. Omitted, the run uses the medium band, "
            "which is the shipped default."
        ),
    )
    observed_ppc: Optional[list[Proportion]] = Field(
        None,
        min_length=1,
        description=(
            "PPC prevalence measured in each lot, one number per lot, from "
            "type_lot_samples. A proportion, not a percentage: a lot that came "
            "back 45% PPC is 0.45. A range observed across two or more lots beats "
            "every published band. One lot, or several that agree, is reported as "
            "evidence for a category rather than used as the bounds."
        ),
    )
    ppc_range: Optional[tuple[Proportion, Proportion]] = Field(
        None,
        description=(
            "The two bounds a lot's PPC frequency is drawn from, when the "
            "processor states them directly. Proportions, not percentages. The "
            "pair expresses uncertainty about the facility, realised as one draw "
            "per lot; it is not variation within a lot."
        ),
    )
    stage_temperatures: Optional[dict[Stage, StageTemperature]] = Field(
        None,
        description="How each stage's temperature differs from the New York baseline.",
    )
    stage_durations: Optional[dict[Stage, Annotated[float, Field(gt=0)]]] = Field(
        None,
        description=(
            "How long each stage actually lasts, in days, as an absolute figure "
            "rather than a difference. A stage must keep a positive duration."
        ),
    )
    extra_legs: Optional[list[ExtraLeg]] = Field(
        None,
        description=(
            "Legs of the processor's chain the five shipped stages do not have. "
            "One leg per stage: the API takes one change of this kind per stage."
        ),
    )

    @model_validator(mode="after")
    def _range_is_ordered(self) -> "Facility":
        # Ordering only -- `Proportion` already bounds both ends to 0..1.
        if self.ppc_range is not None:
            low, high = self.ppc_range
            if low > high:
                raise ValueError(
                    f"ppc_range must be two proportions in order, low then high. "
                    f"Got {low} and {high}."
                )
        return self


# A change above or beyond the baseline reaches the API through the disruption
# door, so it lands in the run's own disruptions_applied record. Said out loud,
# because an audit trail that shows a disruption the processor never suffered
# reads as an incident that never happened.
_RECORD = (
    "It lands in the run's disruptions_applied record, because the API splits a "
    "change by direction and anything above or longer than the New York baseline "
    "goes through that door. Read it as the plant described, not an incident "
    "that happened to it."
)


@dataclass
class Plan:
    """A request body, and everything the answer has to say about building it.

    `run` is here so the reshaping reads the seed, the run size and the horizon
    off the object that set them rather than walking back into `body["config"]`.
    The horizon is what bounds a truncated shelf life, and the response carries no
    `sim_duration` to recover it from.
    """

    body: dict[str, Any]
    run: Run
    notes: list[str] = field(default_factory=list)
    ppc_frequency_range: tuple[float, float] = PPC_BANDS[DEFAULT_PLANT_CATEGORY]
    ppc_frequency_source: str = ""
    plant_category: Optional[PlantCategory] = None
    # Every name this call gave, and the published level it stands for. ADR 012
    # requires the number to be stated rather than hidden behind the name.
    resolved_levels: list[Resolved] = field(default_factory=list)
    # Route 3's comparability gate: whether this scenario changed a duration in
    # one of the four stages `pre_consumer_days` sums. Determinable from the
    # scenario alone, without seeing the other run, which is why the response
    # carries the verdict and the agent stops deciding it.
    pre_consumer_duration_changed: bool = False
    duration_stages: list[str] = field(default_factory=list)


def _band(
    facility: Optional[Facility],
) -> tuple[tuple[float, float], str, Optional[PlantCategory], list[str]]:
    """The PPC frequency bounds the run uses, and the evidence they came from.

    Route 2's rule, in one place. An observed range across lots is the
    facility-specific input Su et al. explicitly sanction and it beats every
    published band -- but a range that has collapsed to a point is a small-sample
    artefact rather than certainty about the facility, and using it would delete
    the uncertainty the pair exists to carry.
    """
    notes: list[str] = []
    stated = facility.plant_category if facility else None
    observed = facility.observed_ppc if facility else None

    if facility is not None and facility.ppc_range is not None:
        low, high = facility.ppc_range
        if low == high:
            notes.append(
                f"Both PPC frequency bounds were given as {low}, which deletes the "
                "uncertainty the pair exists to carry: every lot then draws the "
                "same frequency."
            )
            if high == 0:
                notes.append(
                    "A range pinned at zero deletes PPC from the simulation "
                    "entirely, so every figure below describes a facility with no "
                    "post-pasteurisation contamination at all."
                )
        return (low, high), "the range stated for this facility", stated, notes

    if observed:
        implied = category_for_prevalence(sum(observed) / len(observed))
        if len(observed) > 1 and min(observed) < max(observed):
            return (
                (min(observed), max(observed)),
                f"the range observed across {len(observed)} lots, which is the "
                "facility-specific input Su et al. sanction",
                stated,
                notes,
            )
        category = stated or implied
        if len(observed) == 1:
            evidence = (
                f"the prevalence observed in one lot ({observed[0]}) implies a "
                f"{implied} shelf-life plant, and one lot cannot place a facility"
            )
        else:
            evidence = (
                f"the range observed across {len(observed)} lots collapsed to a "
                f"point ({observed[0]}), which implies a {implied} shelf-life "
                "plant rather than establishing bounds"
            )
        return (
            PPC_BANDS[category],
            f"the published band for a {category} shelf-life plant; {evidence}",
            category,
            notes,
        )

    category = stated or DEFAULT_PLANT_CATEGORY
    source = f"the published band for a {category} shelf-life plant"
    if stated is None:
        source += ", which is the shipped default"
    return PPC_BANDS[category], source, category, notes


def _cooled(
    stage: str,
    cooling: StageCooling,
    stated: Optional[StageTemperature],
    ceiling: Optional[float],
) -> StageTemperature:
    """The stage's temperature statement once the intervention applies.

    Read against the chain this same call describes -- the level `facility`
    states for the stage, or the shipped baseline when the call carries none.
    A run is one call carrying the whole scenario (ADR 015), so there is no
    earlier run for a cooling to be relative to.

    The statement's *shape* survives: cooling a stage the processor described as
    constant leaves it constant, and cooling one described as a level keeps the
    measured within-stage shape and moves it.
    """
    baseline = BASELINE[stage]["level"]
    current = stated.level(baseline) if stated is not None else baseline
    if ceiling is not None:
        current = min(current, ceiling)

    if cooling.by is not None:
        # `by` needs a level to subtract from, and a stage described only by a
        # ceiling has none: clamping the peaks lowers the mean by an amount only
        # the measured profile knows, so `current` here is an upper bound rather
        # than the level. Subtracting from it would report a cooling of `by`
        # while delivering less. `to` is answerable -- it states the level
        # outright -- so the escape is real rather than a loop back here.
        if stated is None and ceiling is not None:
            raise ValueError(
                f"Stage {stage!r} is described only by a cap, which is a ceiling "
                f"rather than a level, so there is nothing to subtract "
                f"{cooling.by} C from. State `to` with the temperature the stage "
                f"would run at, or lower the ceiling with the intervention's own "
                f"`cap`."
            )
        target = current - cooling.by
    else:
        target = cooling.to
    assert target is not None  # StageCooling._exactly_one, cap handled by caller
    if target >= current:
        # Two different rejections wear the same shape here, and sending the
        # second one to model_a_disruption would be wrong: a target sitting at or
        # above a binding ceiling is not a warming, it is a change the run cannot
        # show. Measured on the shipped profiles, at the widest target the
        # ceiling absorbs: shelf life, consumer days, retail spoilage and CO2e
        # all identical, and the daily curve moves at most 1 pp on one interior
        # day. Three of the five stages ship a constant profile, where the
        # clamp absorbs the shift exactly and the difference is zero.
        if ceiling is not None and target >= ceiling:
            raise ValueError(
                f"Stage {stage!r} is already held at or under {ceiling} C by a "
                f"ceiling in this call's chain, and a target of "
                f"{round(target, 4)} C sits at or above that ceiling -- so the "
                f"run would encode the stage the ceiling already describes. "
                f"State a `to` below {ceiling} C for a cooling the answer can "
                f"show, or lower the ceiling itself with the intervention's own "
                f"`cap`."
            )
        raise ValueError(
            f"Stage {stage!r} already runs at {round(current, 4)} C in this call's "
            f"chain, and the intervention would put it at {round(target, 4)} C. "
            f"That is not an improvement, and interventions are improvements only. "
            f"Weigh a stage running warmer with model_a_disruption instead."
        )
    if stated is not None and stated.flat is not None:
        return StageTemperature(flat=target)
    return StageTemperature(shift=round(target - baseline, 6))


def plan(
    run: Run,
    facility: Optional[Facility] = None,
    intervention: Optional[Intervention] = None,
    disruption: Optional[Disruption] = None,
) -> Plan:
    """Build the /simulate body for one run, and say what building it assumed."""
    bounds, source, category, notes = _band(facility)
    body: dict[str, Any] = {
        "config": {
            "n_lots": run.lots,
            "n_units": run.containers_per_lot,
            "P_ppc_min": bounds[0],
            "P_ppc_max": bounds[1],
            "sim_duration": run.days,
        },
        "seed": run.seed,
    }
    result = Plan(
        body=body,
        run=run,
        notes=notes,
        ppc_frequency_range=bounds,
        ppc_frequency_source=source,
        plant_category=category,
    )
    if facility is None and intervention is None and disruption is None:
        return result
    facility = facility or Facility()

    overrides: dict[str, dict[str, Any]] = {}
    disruptions: dict[str, dict[str, Any]] = {}
    # What each stage's one disruption slot is spent on, as (kind, description),
    # so a second claim on it is a rejection rather than a silent overwrite.
    claimed: dict[str, tuple[str, str]] = {}

    def claim(stage: str, kind: str, what: str, spec: dict[str, Any]) -> None:
        if stage in claimed:
            held, wanted = claimed[stage][1], what
            # The advice has to fit the collision. A leg can move to a neighbour,
            # because growth depends on the series rather than the stage labels
            # over it -- but a stage that is both warmer AND longer cannot be
            # expressed at all, and telling someone to move a leg they never
            # mentioned is worse than telling them nothing.
            escape = (
                "Attach the leg to a neighbouring stage instead, or fold its time "
                "into the change already on this one."
                if "leg" in held or "leg" in wanted
                else "State one of the two. A stage that is both warmer and "
                "longer than the New York baseline needs two disruptions, and "
                "the API has room for one -- putting either through the "
                "intervention door would record a degradation as an improvement."
            )
            raise ValueError(
                f"Stage {stage!r} needs two changes the API can only take one of: "
                f"{held}, and {wanted}. The API takes one disruption per stage, "
                f"and both of these reach it through that door. {escape}"
            )
        claimed[stage] = (kind, what)
        disruptions[stage] = spec

    def claimed_for(kind: str) -> list[str]:
        return sorted(s for s, (k, _) in claimed.items() if k == kind)

    # A stage's temperature arrives as up to two separate statements -- the level
    # it runs at, and a ceiling it never exceeds -- because the two compose. The
    # API applies temp_delta and then clamps at temp_max, so a plant running two
    # degrees cold under a 6 C limit is one override carrying both keys. Kept
    # apart here so that either can come from the facility or from the
    # intervention without one silently replacing the other.
    levels: dict[str, StageTemperature] = {}
    ceilings: dict[str, float] = {}
    for stage, temperature in (facility.stage_temperatures or {}).items():
        if temperature.cap is not None:
            ceilings[stage] = temperature.cap
        else:
            levels[stage] = temperature

    cooling_by_stage = (intervention.cool_stage if intervention else None) or {}
    for stage, cooling in cooling_by_stage.items():
        if cooling.cap is not None:
            held = ceilings.get(stage)
            if held is not None and cooling.cap >= held:
                raise ValueError(
                    f"Stage {stage!r} is already held under {held} C in this "
                    f"call's chain, and the intervention would raise that ceiling "
                    f"to {cooling.cap} C. Interventions are improvements only; "
                    f"weigh a loosened limit with model_a_disruption."
                )
            ceilings[stage] = cooling.cap
            continue
        levels[stage] = _cooled(stage, cooling, levels.get(stage), ceilings.get(stage))

    def level_of(stage: str) -> float:
        """The temperature the stage runs at once every statement applies.

        Time added to a stage is spent at the stage's own level, so this is what
        a delay holds. A ceiling can only lower it, and a capped stage's true
        mean is lower still by an amount only the measured profile knows -- so
        this errs warm, and the note below says so.
        """
        baseline = BASELINE[stage]["level"]
        stated = levels.get(stage)
        value = stated.level(baseline) if stated is not None else baseline
        ceiling = ceilings.get(stage)
        return min(value, ceiling) if ceiling is not None else value

    for stage in [s for s in STAGES if s in levels or s in ceilings]:
        if stage in ceilings:
            # Clamping can only lower a temperature, so a ceiling has one door in
            # either direction. A ceiling above every point is simply inert.
            overrides.setdefault(stage, {})["temp_max"] = ceilings[stage]
        temperature = levels.get(stage)
        if temperature is None:
            continue

        baseline = BASELINE[stage]["level"]
        target = temperature.level(baseline)
        delta = round(target - baseline, 6)
        if temperature.flat is not None:
            # No disruption type flattens a stage, so a flat above baseline needs
            # both doors: the intervention flattens at the shipped baseline's own
            # level, which is no thermal improvement, and the disruption carries
            # the whole of the warming.
            overrides.setdefault(stage, {}).update(
                {"temp_mean": target if delta <= 0 else baseline, "temp_sd": 0}
            )
        if delta > 0:
            claim(
                stage,
                "temperature",
                f"a temperature {delta} above baseline",
                {"type": "temp_shift", "temp_delta": delta},
            )
        elif delta < 0 and temperature.flat is None:
            overrides.setdefault(stage, {})["temp_delta"] = delta

    durations = facility.stage_durations or {}

    def duration_of(stage: str) -> float:
        """How long the stage runs in this call's chain, before any event.

        A stage stated *shorter* reaches the API through the intervention door
        and leaves the disruption slot free, so an event can land on a stage
        whose length the facility already changed. The note that event carries
        has to name that length rather than the shipped one. A stage stated
        longer, or carrying an extra leg, claims the slot -- so an event on it is
        already rejected and never reaches here.
        """
        stated = durations.get(stage)
        return stated if stated is not None else BASELINE[stage]["days"]

    for stage, days in durations.items():
        delta = round(days - BASELINE[stage]["days"], 6)
        if delta < 0:
            overrides.setdefault(stage, {})["duration_delta"] = delta
        elif delta > 0:
            claim(
                stage,
                "duration",
                f"a duration {delta} days longer than baseline",
                {"type": "delay", "duration_delta": delta, "temp": level_of(stage)},
            )
            if stage in ceilings:
                notes.append(
                    f"The time added to {stage} is held at {level_of(stage)} C, "
                    "which is an upper bound on what a capped stage averages -- "
                    "clamping the peaks lowers the mean by an amount only the "
                    "measured profile knows. So the added time errs warm, towards "
                    "more growth and a shorter predicted shelf life."
                )

    for leg in facility.extra_legs or []:
        days, celsius = leg.folded()
        claim(
            leg.after,
            "duration",
            f"an extra leg of {round(days, 4)} days",
            {"type": "delay", "duration_delta": days, "temp": celsius},
        )
        if leg.readings is not None:
            implied = (celsius - FOLD_TMIN) ** 2
            notes.append(
                f"The leg after {leg.after} was measured, so it folds at its "
                f"growth-equivalent temperature of {celsius:.2f} C rather than at "
                "its arithmetic mean, by the segment rule the simulator itself "
                "uses. Growth is quadratic in temperature, so a mean loses growth "
                "and overpredicts shelf life. Close rather than exact: the "
                "non-PPC pathways carry their own reference temperatures. The "
                f"implied growth this fold carries, (T_eq - Tmin)^2 at the PPC "
                f"reference Tmin = {FOLD_TMIN} C, is {implied:.1f}; two folds of "
                "the same leg compare by the ratio of these figures."
            )
        # The claim above already routes the leg into the aggregate "stated
        # longer than baseline" note, which carries the disruptions_applied
        # explanation once for everything that goes through that door.
        notes.append(
            f"The leg after {leg.after} is folded into that stage, so it is "
            f"invisible in the stage breakdown -- pre_consumer_days stays correct "
            f"and the leg is absorbed rather than shown separately."
        )

    if disruption is not None:
        placed, event_notes = disruption.events(level_of, duration_of)
        for stage, what, spec in placed:
            claim(stage, "event", what, spec)
        notes.extend(event_notes)

    interventions: dict[str, Any] = {}
    if intervention is not None:
        keys, resolved, applied_notes = intervention.parameters()
        interventions.update(keys)
        result.resolved_levels = resolved
        notes.extend(applied_notes)
        if intervention.reduce_spores is not None and category in ("medium", "short"):
            # Route 4 gates on plant category before offering a spore lever, and
            # ADR 012 measured why: in a medium-PPC run microfiltration moved the
            # d-21 spoilage curve from 59% to 54% and left every headline figure
            # identical, because shelf life had already ended on a PPC-driven
            # curve at d 12.
            notes.append(
                f"Spore control is the lever in a long shelf-life plant, and this "
                f"run is a {category} shelf-life one. Shelf life there usually ends "
                f"on a PPC-driven curve before the spore-formers act, so the "
                f"headline figures can come back unchanged while the spoilage curve "
                f"still moves -- read daily_spoilage and spoilage_summary before "
                f"reporting no benefit. The intervention is masked by a PPC problem "
                f"that has to be solved first, rather than worthless."
            )

    if levels or ceilings:
        notes.append(
            "A stated stage level sets the stage's level only: the within-stage "
            "temperature shape stays the New York baseline's measured trace, "
            "shifted, because a processor's own logger series cannot be loaded "
            "inline for an existing stage yet (issue #24)."
        )
    for stage, temperature in levels.items():
        if temperature.flat is not None:
            notes.append(
                f"{stage} was stated as constant, so the baseline's measured shape "
                "there is replaced by one value and the run reports growth for a "
                "stage that never varies."
            )
    warmer = claimed_for("temperature")
    if warmer:
        notes.append(
            "Stated above the New York baseline: " + ", ".join(warmer) + f". {_RECORD}"
        )
    longer = claimed_for("duration")
    if longer:
        notes.append(
            "Stated longer than the New York baseline: "
            + ", ".join(longer)
            + f". {_RECORD}"
        )

    if overrides:
        interventions["stage_temp_overrides"] = overrides
    if interventions:
        body["interventions"] = interventions
    if disruptions:
        body["disruptions"] = disruptions

    # temp_spike lengthens a stage exactly as delay does -- disruptions.R appends
    # a segment and adds its duration -- so it moves the day retail exit is
    # evaluated on just the same. Route 5's rule: every disruption except
    # temp_shift changes a stage's duration.
    moved = {
        stage
        for stage in PRE_CONSUMER_STAGES
        if "duration_delta" in overrides.get(stage, {})
        or disruptions.get(stage, {}).get("type") in ("delay", "temp_spike")
    }
    result.duration_stages = [s for s in PRE_CONSUMER_STAGES if s in moved]
    result.pre_consumer_duration_changed = bool(moved)
    return result
