"""Simulation endpoints — /simulate, /scenarios, /simulate/methods."""

import logging

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field, field_validator
from typing import Dict, Optional
from services.simulator import SimulatorService

logger = logging.getLogger(__name__)

router = APIRouter()
simulator = SimulatorService()

# The disruption types a caller may name. `profile_csv` is deliberately absent:
# scenarios/disruptions.R accepts it and hands `disruption$path` straight to
# read.csv, so exposing it would make this endpoint an arbitrary file read. The
# four measured traces are still reachable, through `preset` -- the bridge maps a
# preset name to a path it owns (r_bridge/run_simulation.R).
ALLOWED_DISRUPTION_TYPES = ("temp_spike", "delay", "temp_shift", "preset")

METHODS_TEXT = """\
## Economic Shelf-Life Value

Based on Lau, Wiedmann & Adalja (2023), J. Dairy Sci. 106:4773-4784.

    shelf_life_value_usd = consumer_shelf_life_days x $0.03/unit x n_units

Each additional day of consumer shelf life is worth $0.03 per half-gallon. The \
figure comes from hedonic price regressions on half-gallon milk products \
averaging $4.09. Note the sample was 61% organic and 46% ultra-pasteurized, so \
it is not drawn purely from the HTST conventional product this model simulates.

## Pre-Consumer Spoilage

Percentage of containers spoiled at retail exit (before consumer purchase).
Evaluated at the pre-consumer day (sum of facility + transport + retail durations).

## Environmental Emission (CO2e)

Based on EPA WARM model (U.S. EPA, 2020).

The waste cohort is the spoilage that defines end of shelf life. Shelf life ends \
on the first day median lot spoilage exceeds `threshold_pct`, so that fraction is \
spoiled by construction. The calculation partitions it by where it spoiled, not \
by how much spoiled. Every /simulate response reports the value the run used as \
`shelf_life.threshold_pct` -- read it from there rather than from this text.

    retail_waste_L = pct_spoiled_at_retail/100 x n_units x 1.893
    consumer_waste_L = (threshold_pct/100 - pct_spoiled_at_retail/100) x n_units x 1.893
    co2e_kg = retail_waste_L x 0.55 + consumer_waste_L x 0.20

- Retail waste -> landfill: 0.55 kg CO2e/L
- Consumer waste -> wastewater: 0.20 kg CO2e/L
- Container volume: 1.893L (half-gallon)

## References

- Lau, S., M. Wiedmann, and A. Adalja. (2023). Economic and environmental \
analysis of processing plant interventions to reduce fluid milk waste. Journal \
of Dairy Science 106:4773-4784. https://doi.org/10.3168/jds.2022-23019
  Supports the $0.03/day figure only.
- U.S. Environmental Protection Agency. (2020). Waste Reduction Model (WARM).
  Supports the 0.55 and 0.20 kg CO2e/L emission factors only.

The retail-landfill / consumer-wastewater split, and the use of the shelf-life \
criterion as the waste cohort, are this API's own construction. Neither \
reference above states them.
"""


class SimulateInput(BaseModel):
    config: Optional[Dict] = Field(
        None,
        description="Config overrides: n_lots, n_units, P_ppc_min, P_ppc_max, sim_duration",
    )
    interventions: Optional[Dict] = Field(
        None, description="Intervention parameters"
    )
    disruptions: Optional[Dict] = Field(
        None,
        description=(
            "Disruption definitions keyed by stage name. Each value needs a `type` of "
            + ", ".join(ALLOWED_DISRUPTION_TYPES)
        ),
    )
    seed: Optional[int] = Field(None, description="Random seed for reproducibility")

    @field_validator("disruptions")
    @classmethod
    def check_disruption_types(cls, value: Optional[Dict]) -> Optional[Dict]:
        """Reject any disruption type the API does not serve, `profile_csv` above all.

        The bridge passes every non-preset disruption through to the R model
        verbatim, so this validator is the only gate between a request body and
        `read.csv`.
        """
        if value is None:
            return value

        for stage, spec in value.items():
            if not isinstance(spec, dict):
                raise ValueError(
                    f"disruption for stage '{stage}' must be an object, got "
                    f"{type(spec).__name__}"
                )
            dtype = spec.get("type")
            if dtype == "profile_csv":
                raise ValueError(
                    "disruption type 'profile_csv' is not accepted over the API. It reads "
                    "a file path on the server. The four measured traces are reachable "
                    "with {'type': 'preset', 'name': ...} -- see GET /scenarios."
                )
            if dtype not in ALLOWED_DISRUPTION_TYPES:
                raise ValueError(
                    f"unknown disruption type {dtype!r} for stage '{stage}'. Options: "
                    + ", ".join(ALLOWED_DISRUPTION_TYPES)
                )
        return value


@router.post("/simulate", tags=["Simulation"])
async def simulate(input_data: SimulateInput):
    """Run spoilage simulation. Returns spoilage summary, shelf life, economics, and plot."""
    try:
        result = simulator.run(
            config=input_data.config,
            interventions=input_data.interventions,
            disruptions=input_data.disruptions,
            seed=input_data.seed,
        )
    except RuntimeError as e:
        # SimulatorService puts the R subprocess's stderr in the message, which
        # discloses server paths and package state. Log it, return nothing.
        logger.error("Simulation failed", exc_info=e)
        raise HTTPException(
            status_code=500,
            detail="Simulation failed. The error is in the server log.",
        )
    except Exception as e:
        logger.warning("Rejected simulation request", exc_info=e)
        raise HTTPException(status_code=400, detail="Invalid simulation request.")
    return result


@router.get("/scenarios", tags=["Simulation"])
async def list_scenarios():
    """List valid intervention and disruption options with parameter schemas."""
    return simulator.list_scenarios()


@router.get("/simulate/methods", tags=["Simulation"])
async def simulation_methods():
    """Documentation for economics calculation methods and references."""
    return {"methods": METHODS_TEXT}
