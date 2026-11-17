"""The shipped cold chain, as numbers the client needs before it can call.

Two of the mappings ADR 015 puts in this client cannot be done without the
baseline. A processor states their plant in absolutes -- "our retail cases run at
4 degrees", "product sits five days" -- and the API takes offsets, so the client
subtracts. The sign of that subtraction is also what picks the API door:
colder or shorter is an intervention, warmer or longer a disruption.

So the five stages, their baseline levels and their baseline durations are
written here, copied from milk-spoilage-model/config.R. Copied, not read: parsing
R at import would add a startup failure mode to a live server for a table that
changes about never. tests/test_supply_chain_matches_config.py reads config.R and
fails when the two disagree, which is the same arrangement
SimulatorService._REQUIRED_R_PACKAGES has with the Dockerfile.
"""

from __future__ import annotations

import math
from typing import Literal, get_args

from pydantic import BaseModel, Field

# The five stages, in the order product passes through them. run_model() fixes
# both the count and the names -- the Buchanan pathway reads five stage columns
# by name, so a sixth stage would run as though every dynamic profile were
# absent and return a plausible wrong number.
Stage = Literal[
    "processing_facility",
    "transportation_facility_to_retail",
    "retail",
    "transportation_retail_to_home",
    "consumer",
]

# Derived, not written out again. The Literal is what the tool schemas advertise
# and this is what the code iterates, so a second copy is a second thing to keep
# in step.
STAGES: tuple[str, ...] = get_args(Stage)

# The four `pre_consumer_days` sums -- run_model.R takes setdiff(stage_order,
# "consumer"). A duration change inside these four moves the day the run
# evaluates retail exit on, which is the whole comparability question route 3
# gates on.
PRE_CONSUMER_STAGES: tuple[str, ...] = STAGES[:-1]

# Baseline level and duration per stage, from config$temperature_stages. `level`
# is that stage's `mean`: for the four dynamic stages it is the mean of the
# measured New York profile, and for transportation_retail_to_home, the one
# static stage, it is the temperature the stage is drawn around.
BASELINE: dict[str, dict[str, float]] = {
    "processing_facility": {"level": 1.7037, "days": 2.4264},
    "transportation_facility_to_retail": {"level": 4.549, "days": 0.3299},
    "retail": {"level": 6.5, "days": 5.4583},
    "transportation_retail_to_home": {"level": 8.5, "days": 0.04},
    "consumer": {"level": 6.5, "days": 27.9583},
}

# Su et al. fitted three bands to voluntary shelf-life data from 28 New York
# plants and 536 samples. The pair is what `P_ppc_min` and `P_ppc_max` draw a
# lot's PPC frequency from; the percentage band that sorted a plant into the
# category is a different number and is not repeated here. Medium is the shipped
# default -- config$P_ppc_min and config$P_ppc_max carry exactly this row.
PlantCategory = Literal["long", "medium", "short"]

PPC_BANDS: dict[str, tuple[float, float]] = {
    "long": (0.125, 0.294),
    "medium": (0.40, 0.625),
    "short": (0.778, 1.00),
}

DEFAULT_PLANT_CATEGORY: PlantCategory = "medium"

# The classification band each category was fitted from, as a PPC frequency. Used
# only to name the category an observed prevalence implies, which route 2 reports
# as the evidence for a choice rather than as the choice itself.
_CATEGORY_CEILING: tuple[tuple[float, PlantCategory], ...] = (
    (0.33, "long"),
    (0.66, "medium"),
)


def category_for_prevalence(prevalence: float) -> PlantCategory:
    """The plant category an observed PPC prevalence falls in."""
    for ceiling, category in _CATEGORY_CEILING:
        if prevalence <= ceiling:
            return category
    return "short"


# The minimum growth temperature the fold below is computed at, config$Tmin_PPC.
#
# One reference temperature is enough for a fold and the non-PPC pathways' own
# T0 is not used. Writing `d = m - Tmin` for the leg's time-weighted mean and `v`
# for its time-weighted variance, T_eq is about m + v/(2d), so the two references
# differ only through `d` -- a few hundredths of a degree across a cold chain's
# range of v.
FOLD_TMIN = -4.15

# The Buchanan pathway's own reference temperature, muAtNewTemp()'s T0 default in
# utils/growth_models.R. The high-growth pathway reads a third per container, off
# the pool's own Tmin column, so no small set covers every pathway.
BUCHANAN_T0 = -3.62

# Ranking two events on one stage is the case that genuinely needs both. Unlike a
# fold, the two orderings can disagree -- and when they do, the two events
# contribute so nearly equally that dropping either loses about half the added
# growth, so the disagreement is the answer rather than a tie to break.
REFERENCE_TEMPERATURES: tuple[tuple[str, float], ...] = (
    ("PPC containers", FOLD_TMIN),
    ("the Buchanan pathway", BUCHANAN_T0),
)


class Reading(BaseModel):
    """One temperature-logger reading from a leg of the processor's chain."""

    hours: float = Field(
        ge=0, description="Elapsed hours from the start of the leg."
    )
    celsius: float = Field(description="The temperature recorded, in Celsius.")


def growth_equivalent_temperature(readings: list[Reading]) -> float:
    """The one temperature that grows a leg as much as its measured series does.

    Growth is exactly quadratic in (T - Tmin), so a series folds at the
    temperature whose squared displacement matches the series' own mean squared
    displacement -- not at its arithmetic mean, which is lower and therefore
    overpredicts shelf life. This repository measured 26.3% of a stage's growth
    lost to a mean.

    The segment rule is the simulator's own. Between two readings the model
    interpolates linearly (approxfun), and the exact integral of that ramp
    squared over one segment is dt * (a^2 + a*b + b^2) / 3 -- see
    stage_growth_integral() in milk-spoilage-model/utils/temperature.R. The
    trapezoidal (a^2 + b^2)/2 runs warm on a sparse ramp and would not reproduce
    the model.

    Weighting is by elapsed time, so dense sampling through a cool interval
    cannot bury a long warm one recorded sparsely. The unit cancels -- the result
    is a ratio of an integral to the span it was taken over -- so hours are read
    as given.
    """
    ordered = sorted((r.hours, r.celsius) for r in readings)
    span = ordered[-1][0] - ordered[0][0]
    if span <= 0:
        raise ValueError(
            "The readings span no time, so there is no leg to fold. Times are "
            "elapsed hours from the start of the leg, and they must increase."
        )

    integral = 0.0
    for (t_a, temp_a), (t_b, temp_b) in zip(ordered, ordered[1:]):
        a = temp_a - FOLD_TMIN
        b = temp_b - FOLD_TMIN
        integral += (t_b - t_a) * (a * a + a * b + b * b) / 3.0

    return FOLD_TMIN + math.sqrt(integral / span)
