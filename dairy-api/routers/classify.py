"""Classification router — POST /classify, POST /classify/batch, GET /variants."""

from __future__ import annotations

from typing import Any, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from services.classifier import (
    DEFAULT_VARIANT,
    MAX_LOG10_COUNT,
    ClassifierService,
)

router = APIRouter(tags=["Classification"])

# Singleton service — loaded once at import time
_service = ClassifierService()

# -------------------------------------------------------------------------
# Pydantic models
# -------------------------------------------------------------------------

def _count(analyte: str, day: int) -> Any:
    """A plate-count field, bounded to the unit the model actually needs.

    The bound is the backstop; the description is what prevents the call. A
    caller sending 4700000 where 6.67 belongs gets a 422 naming this field,
    rather than the 500 that an unbounded `10 ** 4700000` used to raise.
    """
    return Field(
        None,
        ge=0,
        le=MAX_LOG10_COUNT,
        description=(
            f"{analyte} at Day {day}, in log10 CFU/mL. Convert before sending: "
            f"a plate count of 4,700,000 CFU/mL is 6.67."
        ),
    )


class ClassifyInput(BaseModel):
    spc_d7: Optional[float] = _count("Standard Plate Count", 7)
    spc_d14: Optional[float] = _count("Standard Plate Count", 14)
    spc_d21: Optional[float] = _count("Standard Plate Count", 21)
    tgn_d7: Optional[float] = _count("Total Gram-Negative", 7)
    tgn_d14: Optional[float] = _count("Total Gram-Negative", 14)
    tgn_d21: Optional[float] = _count("Total Gram-Negative", 21)
    model_variant: str = Field(DEFAULT_VARIANT, description="Model variant to use")

    model_config = {
        "json_schema_extra": {
            "example": {
                "spc_d7": 2.1,
                "spc_d14": 4.7,
                "spc_d21": 6.4,
                "tgn_d7": 1.0,
                "tgn_d14": 3.7,
                "tgn_d21": 5.3,
                "model_variant": DEFAULT_VARIANT,
            }
        }
    }


class BatchInput(BaseModel):
    samples: list[ClassifyInput]
    model_variant: str = Field(DEFAULT_VARIANT, description="Model variant to use for all samples")


# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------

# Map lowercase snake_case pydantic field -> uppercase model feature name
_FEATURE_MAP = {
    "spc_d7": "SPC_D7",
    "spc_d14": "SPC_D14",
    "spc_d21": "SPC_D21",
    "tgn_d7": "TGN_D7",
    "tgn_d14": "TGN_D14",
    "tgn_d21": "TGN_D21",
}


def _input_to_features(inp: ClassifyInput) -> dict[str, float]:
    """Convert a ClassifyInput to an uppercase feature dict, dropping Nones."""
    result: dict[str, float] = {}
    for snake, upper in _FEATURE_MAP.items():
        val = getattr(inp, snake)
        if val is not None:
            result[upper] = val
    return result


# -------------------------------------------------------------------------
# Endpoints
# -------------------------------------------------------------------------

@router.post("/classify")
async def classify_single(body: ClassifyInput):
    """Classify a single milk sample (3-class: PPC, no spoilage, spore spoilage)."""
    features = _input_to_features(body)
    try:
        result = _service.classify_sample(features, body.model_variant)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    # Attach variant metadata
    variant_meta = next(
        (v for v in _service.list_variants() if v["variant_id"] == body.model_variant),
        None,
    )
    result["variant_used"] = variant_meta
    return result


@router.post("/classify/batch")
async def classify_batch(body: BatchInput):
    """Classify multiple milk samples and return PPC prevalence summary."""
    samples = [_input_to_features(s) for s in body.samples]
    try:
        result = _service.classify_batch(samples, body.model_variant)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return result


@router.get("/variants")
async def list_variants():
    """List all available model variants sorted by accuracy."""
    variants = _service.list_variants()
    return {"total_variants": len(variants), "variants": variants}
