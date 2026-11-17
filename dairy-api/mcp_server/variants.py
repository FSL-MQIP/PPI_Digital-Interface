"""The variant walk — which shipped model the lab's measurements support.

ADR 013 decided the plugin quotes the accuracy the shipped model scores, and
route 1 enforces that **by procedure**: walk `/variants`, which already arrives
sorted by `test_accuracy` highest first, and take the first variant whose every
feature the lab has. Nothing in this module knows an accuracy figure, and
nothing may learn one -- a number written into code drifts away from the model
that is actually serving, which is the defect ADR 013 exists to prevent.

Pure functions over the `/variants` payload. No HTTP, no model loading.
"""

from __future__ import annotations

from typing import Any, Iterable, Mapping, Optional

from services.classifier import ALL_FEATURES

# Tool argument name -> model feature name, derived from the API's own canonical
# list rather than written out again. The two must agree exactly: a client that
# spells a feature differently from the model sends a request that classifies
# fine and answers about the wrong measurement.
FEATURE_OF: dict[str, str] = {feature.lower(): feature for feature in ALL_FEATURES}

_ANALYTE = {"SPC": "SPC", "TGN": "TGN"}


def to_features(measurements: Mapping[str, Optional[float]]) -> dict[str, float]:
    """Uppercase feature dict from tool arguments, dropping absent measurements."""
    return {
        FEATURE_OF[name]: value
        for name, value in measurements.items()
        if name in FEATURE_OF and value is not None
    }


def missing_features(variant: Mapping[str, Any], have: Iterable[str]) -> list[str]:
    """The variant's features the lab does not have, in the variant's own order."""
    present = set(have)
    return [f for f in variant["features"] if f not in present]


def pick_variant(
    variants: list[Mapping[str, Any]], have: Iterable[str]
) -> Optional[Mapping[str, Any]]:
    """The walk: the first variant, from the top, whose every feature is present.

    `variants` must arrive in the order `/variants` returns it. Never choose on
    preference, and never on a processor's request for a particular model --
    what the lab measured decides.
    """
    present = set(have)
    for variant in variants:
        if all(f in present for f in variant["features"]):
            return variant
    return None


def nearest_miss(
    variants: list[Mapping[str, Any]], have: Iterable[str]
) -> Optional[dict[str, Any]]:
    """The variant closest to running, when the walk found nothing.

    Fewest missing measurements wins; a tie goes to the higher accuracy, which
    is list order. This is what turns "no model fits" into one measurement the
    processor can go and get.
    """
    present = set(have)
    ranked = [
        {"variant": v, "missing": missing_features(v, present)} for v in variants
    ]
    if not ranked:
        return None
    # min() is stable, so among equal miss counts the earliest -- the most
    # accurate -- entry survives.
    return min(ranked, key=lambda entry: len(entry["missing"]))


def next_best(
    variants: list[Mapping[str, Any]],
    selected: Optional[Mapping[str, Any]],
    have: Iterable[str],
) -> Optional[dict[str, Any]]:
    """The entry immediately above the selection, and what it would need.

    Route 1 prices a missing measurement with this: the selected variant against
    the one just above it. Returns None when the walk selected the top-ranked
    variant, because nothing sits above it and inventing a comparison there is
    how an accuracy figure gets fabricated.
    """
    if selected is None:
        return None
    index = next(
        (i for i, v in enumerate(variants) if v["variant_id"] == selected["variant_id"]),
        None,
    )
    if index is None or index == 0:  # not in the list, or already at the top
        return None
    above = variants[index - 1]
    return {"variant": above, "missing": missing_features(above, have)}


def measurement_label(feature: str) -> str:
    """`SPC_D21` as a lab would say it, for an answer a processor reads."""
    analyte, day = feature.split("_D")
    return f"{_ANALYTE.get(analyte, analyte)} at day {day}"
