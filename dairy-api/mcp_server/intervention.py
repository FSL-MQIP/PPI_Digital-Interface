"""An improvement a processor is weighing, turned into intervention parameters.

Interventions are improvements only (ADR 003), so everything here reaches the API
through the intervention door and nothing needs the disruption one. A change that
makes an outcome worse is `model_a_disruption`, and how a plant normally runs is
`facility`.

**A name resolves to a level the response states.** ADR 012's rule is that a
number entering the model was published or measured, never invented, and the
corollary is that a name standing for a published number has to hand that number
back -- otherwise the skill asserts "increase equipment cleaning" and the
processor cannot see that it meant a PPC frequency of 50%. Every name this module
accepts leaves a `Resolved` behind, carrying the level, the plant action and the
publication.

`plan()` in facility.py consumes this. Nothing here reaches the API or the model.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated, Any, Literal, Optional, Union

from pydantic import BaseModel, Field, model_validator

from mcp_server.supply_chain import Stage

# The named levers, and the published level each one stands for.
#
# Lau et al. (2022) Table 4 is a published what-if taxonomy that maps one-to-one
# onto the simulation's parameters, and every row carries a named plant action.
# Six rows are here; the seventh, limiting distribution temperature at 6 C, is
# not -- see the note under `cool_stage` on why it is a `cap` rather than a name.
NamedIntervention = Literal[
    "increase_equipment_cleaning",
    "replace_filler_nozzles",
    "preventative_maintenance",
    "preventative_maintenance_upper_bound",
    "seek_and_destroy_fastest_growing",
    "seek_and_destroy_most_frequent",
]


@dataclass(frozen=True)
class _Published:
    parameter: str
    level: Union[float, tuple[str, ...]]
    plant_action: str
    source: str


_LAU_2022 = "Lau et al. (2022), Table 4"

NAMED: dict[str, _Published] = {
    "increase_equipment_cleaning": _Published(
        "ppc_frequency_factor",
        0.5,
        "increase periodic cleaning of filler nozzles from once to twice a week",
        f"{_LAU_2022}: PPC frequency 100% to 50%",
    ),
    "replace_filler_nozzles": _Published(
        "ppc_frequency_factor",
        0.1,
        "the same increase in periodic cleaning, plus replacing old filler nozzles",
        f"{_LAU_2022}: PPC frequency 100% to 10%",
    ),
    "preventative_maintenance": _Published(
        "ppc_initial_reduction_log",
        1.0,
        "preventative maintenance SOPs for O-rings, gaskets, mesh screens and "
        "rubber fittings",
        f"{_LAU_2022}: a 1 log reduction in the PPC load that arrives",
    ),
    "preventative_maintenance_upper_bound": _Published(
        "ppc_initial_reduction_log",
        3.0,
        "the same maintenance SOPs, at a level the authors flag as likely "
        "unrealistic",
        f"{_LAU_2022}: a 3 log reduction, which the authors call likely "
        "unrealistic -- a bound rather than a proposal",
    ),
    "seek_and_destroy_fastest_growing": _Published(
        "ppc_remove_st",
        ("100",),
        '"Seek and Destroy" on the sequence type with the highest maximum growth rate',
        f"{_LAU_2022}, which names the sequence type as well as the rule",
    ),
    "seek_and_destroy_most_frequent": _Published(
        "ppc_remove_st",
        ("9", "13"),
        '"Seek and Destroy" on the two most frequently occurring sequence types',
        f"{_LAU_2022}, which names the sequence types as well as the rule",
    ),
}


@dataclass(frozen=True)
class _SporePreset:
    log_reduction: float
    source: str


# Copied from milk-spoilage-model/scenarios/interventions.R, the same arrangement
# supply_chain.py's BASELINE has with config.R and for the same reason: the API
# resolves the preset name itself, but the response has to state the number the
# name stands for, and a client stating a level the model no longer applies is
# worse than one that states none. tests/test_supply_chain_matches_config.py
# reads the R and fails when the two disagree.
SPORE_PRESETS: dict[str, _SporePreset] = {
    "microfiltration": _SporePreset(2.2, "Doll et al. 2017, Front. Microbiol. 8:135"),
    "microfiltration_low": _SporePreset(
        0.6, "Doll et al. 2017, a low-efficiency installation"
    ),
    "bactofugation_single": _SporePreset(
        1.4, "Gesan-Guiziou 2010, Improv. Saf. Qual. Milk 1:349-372"
    ),
    "bactofugation_double": _SporePreset(2.0, "Griep 2018, PhD thesis, Cornell"),
}

SporePreset = Literal[
    "microfiltration",
    "microfiltration_low",
    "bactofugation_single",
    "bactofugation_double",
]


class Resolved(BaseModel):
    """A name the call used, and the published level it stands for."""

    named: str = Field(description="The name this call gave.")
    parameter: str = Field(description="The simulation parameter it set.")
    level: Union[float, list[str]] = Field(
        description="The published level it resolved to."
    )
    plant_action: str = Field(description="What a plant does to achieve it.")
    source: str = Field(description="The publication the level comes from.")


class StageCooling(BaseModel):
    """How much colder one stage runs under the intervention. State one key.

    `by` and `to` are read against **the chain this same call describes**: the
    level `facility` states for that stage, or the shipped baseline when the call
    carries no facility. Nothing here refers to an earlier call -- a run is one
    call carrying the whole scenario (ADR 015), so there is no previous run for a
    change to be relative to.
    """

    by: Optional[float] = Field(
        None,
        gt=0,
        description=(
            "Degrees Celsius colder than this call's chain already runs the stage. "
            "A facility stating retail at 4.0 and a `by` of 2 is retail at 2.0."
        ),
    )
    to: Optional[float] = Field(
        None,
        description=(
            "The temperature in Celsius the stage runs at under the intervention, "
            "stated absolutely. Has to be below the level this call's chain "
            "already runs it at, because an intervention is an improvement."
        ),
    )
    cap: Optional[float] = Field(
        None,
        description=(
            "A ceiling in Celsius the stage never exceeds. Keeps the measured "
            "within-stage shape and flattens the peaks above it, so it is the key "
            "for limiting distribution temperature -- Lau et al. (2022) publish 6 "
            "C for that. Composes with a stated level rather than replacing it."
        ),
    )

    @model_validator(mode="after")
    def _exactly_one(self) -> "StageCooling":
        stated = [k for k in ("by", "to", "cap") if getattr(self, k) is not None]
        if len(stated) != 1:
            raise ValueError(
                "State exactly one of by, to or cap for a stage. Got "
                + (", ".join(stated) if stated else "none")
                + "."
            )
        return self


class Intervention(BaseModel):
    """One change for the better, weighed against the baseline.

    State at least one lever. Levels come from a publication or from the
    processor's own measurement; the response says which, and a published level
    is offered for replacement rather than asserted about their plant.
    """

    named: Optional[list[NamedIntervention]] = Field(
        None,
        min_length=1,
        description=(
            "Published levers, by name. Each resolves to the level Lau et al. "
            "(2022) fitted, and the response states that level beside the name. "
            "Two names claiming one parameter are rejected rather than merged."
        ),
    )
    reduce_spores: Optional[Union[SporePreset, Annotated[float, Field(gt=0)]]] = Field(
        None,
        description=(
            "Physical spore removal: a preset name, or the processor's own "
            "measured log10 reduction, which outranks every preset. Acts on "
            "Bacillus and Paenibacillus rows only, so it does nothing to a "
            "vegetative cell."
        ),
    )
    reduce_ppc_frequency: Optional[Annotated[float, Field(gt=0, lt=1)]] = Field(
        None,
        description=(
            "The share of the facility's PPC frequency that remains, as a "
            "multiplier on both bounds: 0.5 halves how often PPC happens. Below 1 "
            "and above 0 -- 1 is no change, above 1 is a disruption, and 0 deletes "
            "PPC from the run rather than reducing it."
        ),
    )
    reduce_ppc_load_log: Optional[Annotated[float, Field(gt=0)]] = Field(
        None,
        description=(
            "How much less PPC arrives when it does happen, as a log10 reduction "
            "on the initial load. Changes how often PPC is survivable, not how "
            "often it occurs."
        ),
    )
    remove_sequence_types: Optional[list[str]] = Field(
        None,
        min_length=1,
        description=(
            "PPC sequence types to remove from the pool, by ClosestST id. The "
            "processor's own sequencing outranks the published choices, which the "
            "two seek_and_destroy names carry. Matched exactly, so a compound "
            "label such as 9_23 is not removed by 9."
        ),
    )
    cool_stage: Optional[dict[Stage, StageCooling]] = Field(
        None,
        description=(
            "Stages the intervention runs colder, or holds under a ceiling. "
            "Temperature control reaches every populated growth pathway, so it is "
            "a lever in any plant category rather than a PPC-specific one."
        ),
    )

    @model_validator(mode="after")
    def _states_a_change(self) -> "Intervention":
        if not any(
            getattr(self, field) is not None for field in type(self).model_fields
        ):
            raise ValueError(
                "An intervention has to state at least one lever. The levers are "
                "named, reduce_spores, reduce_ppc_frequency, reduce_ppc_load_log, "
                "remove_sequence_types and cool_stage. To predict the baseline "
                "itself, use predict_default or predict_customize."
            )
        return self

    @model_validator(mode="after")
    def _one_claim_per_parameter(self) -> "Intervention":
        """A parameter set twice is a rejection, never a silent last-one-wins.

        Both collisions are real. Two names can carry one parameter -- the two
        maintenance levels both set `ppc_initial_reduction_log` -- and a name plus
        a stated level is a processor's own figure meeting a published one, where
        picking either silently answers a question nobody asked.
        """
        stated = {
            "ppc_frequency_factor": "reduce_ppc_frequency"
            if self.reduce_ppc_frequency is not None
            else None,
            "ppc_initial_reduction_log": "reduce_ppc_load_log"
            if self.reduce_ppc_load_log is not None
            else None,
            "ppc_remove_st": "remove_sequence_types"
            if self.remove_sequence_types is not None
            else None,
        }
        claimed: dict[str, list[str]] = {
            parameter: [key] for parameter, key in stated.items() if key
        }
        for name in self.named or []:
            claimed.setdefault(NAMED[name].parameter, []).append(name)

        for parameter, claims in claimed.items():
            if len(claims) > 1:
                raise ValueError(
                    f"{' and '.join(claims)} all set {parameter}, and the run takes "
                    f"one value for it. State one. A level the processor measured "
                    f"outranks a published one, so if that is the disagreement, "
                    f"drop the name."
                )
        return self

    def parameters(self) -> tuple[dict[str, Any], list[Resolved], list[str]]:
        """The API's intervention keys, the levels any names resolved to, and notes.

        `cool_stage` is absent from the keys: a stage temperature has to be
        composed against whatever the facility says about that same stage, so
        plan() builds it where both are in view.
        """
        keys: dict[str, Any] = {}
        resolved: list[Resolved] = []
        notes: list[str] = []

        for name in self.named or []:
            published = NAMED[name]
            level = (
                list(published.level)
                if isinstance(published.level, tuple)
                else published.level
            )
            keys[published.parameter] = level
            resolved.append(
                Resolved(
                    named=name,
                    parameter=published.parameter,
                    level=level,
                    plant_action=published.plant_action,
                    source=published.source,
                )
            )

        if self.reduce_spores is not None:
            keys["spore_reduction"] = self.reduce_spores
            preset = SPORE_PRESETS.get(str(self.reduce_spores))
            if preset is not None:
                resolved.append(
                    Resolved(
                        named=str(self.reduce_spores),
                        parameter="spore_reduction",
                        level=preset.log_reduction,
                        plant_action="physical removal of spores from the milk "
                        "before packaging",
                        source=preset.source,
                    )
                )
        if self.reduce_ppc_frequency is not None:
            keys["ppc_frequency_factor"] = self.reduce_ppc_frequency
        if self.reduce_ppc_load_log is not None:
            keys["ppc_initial_reduction_log"] = self.reduce_ppc_load_log
        if self.remove_sequence_types is not None:
            keys["ppc_remove_st"] = self.remove_sequence_types

        if "ppc_remove_st" in keys:
            notes.append(
                "ppc_remove_st matches ClosestST exactly, so an id that matches "
                "nothing removes nothing while the run still lists the "
                "intervention as applied. A Seek-and-Destroy run returning figures "
                "identical to the baseline is far more likely a non-matching id "
                "than a real null result -- compare the two runs before reporting "
                "no benefit."
            )
        if resolved:
            notes.append(
                "Every level named above is published rather than measured at this "
                "facility, so it is an estimate: what it delivers depends on the "
                "equipment installed, its condition, flow rate, processing "
                "temperature and cleaning frequency. Ask whether the processor has "
                "their own figure, which outranks any of these."
            )
        return keys, resolved, notes
