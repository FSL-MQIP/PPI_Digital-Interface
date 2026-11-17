"""What the two typing tools return, as types rather than as `dict[str, Any]`.

`response.py` does this for the simulation tools and says why. The same argument
applies here with one addition: a `dict[str, Any]` return is not untyped in the
protocol, it is *vacuously* typed. FastMCP emits
`{"type": "object", "additionalProperties": true}` for it, which validates any
object at all -- so a client that checks the response against the declared
schema learns nothing, while appearing to have checked something.

Both tools answer in two shapes: the classifier ran, or the measurements reached
no shipped model. The second is returned rather than raised (see
`_no_variant_fits`), so one model carries both and `classified` says which. A
`Union` of two models would express it better, but FastMCP buries a union under
a `{"result": ...}` wrapper, which costs every reader a level of nesting to save
this file a few Optionals.

Nothing here holds an accuracy figure, and nothing may learn one -- ADR 013, and
test_no_written_accuracy.py scans this file.
"""

from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, Field

# How many per-sample predictions a lot returns when the caller names no limit.
# A lot of a hundred samples returns a hundred prediction objects, each carrying
# three class probabilities and a confidence, straight into a context window --
# for a tool whose per-lot figure is `ppc_prevalence`. The predictions matter for
# a handful of samples and are noise for a hundred.
DEFAULT_MAX_PREDICTIONS = 10


class Variant(BaseModel):
    """One shipped classifier, exactly as /variants describes it.

    Every accuracy here is read from that response at call time. ADR 013 forbids
    writing one into the plugin, because a figure in code drifts away from the
    model that is actually serving.
    """

    variant_id: str
    name: str
    description: str
    features: list[str] = Field(
        description="The measurements this variant requires, all of them mandatory."
    )
    test_accuracy: float = Field(
        description=(
            "What this artifact scores on the shipped test set. Report this one "
            "as the model's accuracy."
        )
    )
    published_test_accuracy: Optional[float] = Field(
        None,
        description=(
            "The paper's figure for the same variant name, on the paper's own "
            "test split. A comparison only, and null where the paper reports none."
        ),
    )
    published_source: str = Field(description="The citation the figure above comes from.")
    accuracy_note: str = Field(
        description="Why the two figures can differ, and which one to quote."
    )
    n_features: int


class NearestVariant(BaseModel):
    """A variant the lab cannot reach yet, and what would reach it.

    This is what turns a missing measurement into a decision a processor can
    price: one more day's plating, against the accuracy it buys.
    """

    variant_id: str
    name: str
    test_accuracy: float
    needs: list[str] = Field(
        description="The measurements this variant needs that the lab does not have."
    )


class ClassifierModels(BaseModel):
    """The shipped variants, sorted by test accuracy, highest first."""

    total_variants: int
    variants: list[Variant] = Field(
        description=(
            "Sorted by test_accuracy descending. Route 1 walks this order and "
            "takes the first variant whose every feature the lab has."
        )
    )


class SampleType(BaseModel):
    """One sample's spoilage type, with the position of the sample it describes."""

    sample_index: int = Field(
        description=(
            "Which sample this is, counting from 0 in the order they were sent. "
            "Stated because the prediction list can be truncated, and a position "
            "in a shortened list maps back to nothing."
        )
    )
    prediction: str = Field(description="PPC, spore spoilage, or no spoilage.")
    probabilities: dict[str, float] = Field(
        description="The three classes and their probabilities."
    )
    confidence: float = Field(
        description=(
            "The top probability. Report it beside the class: a top probability "
            "near a third, across three classes, is a coin flip wearing a label."
        )
    )


class _Typed(BaseModel):
    """The fields both typing tools share, in both of their two shapes."""

    classified: bool = Field(
        description=(
            "False when the measurements reach no shipped model. Not an error: "
            "the useful answer is then the measurement standing in the way, and "
            "`reason` and `missing_measurements` carry it."
        )
    )
    variant: Optional[Variant] = Field(
        None, description="The variant the walk selected. Null when nothing was classified."
    )
    next_best_variant: Optional[NearestVariant] = Field(
        None,
        description=(
            "The variant immediately above the selection, and the measurement it "
            "needs. Null when the walk selected the top-ranked variant, because "
            "nothing sits above it and there is no comparison to make."
        ),
    )
    reason: Optional[str] = Field(
        None, description="Why nothing was classified. Null when something was."
    )
    missing_measurements: list[str] = Field(
        default_factory=list,
        description="The measurements that would reach the nearest model. Empty on success.",
    )
    nearest_variant: Optional[NearestVariant] = Field(
        None, description="The variant closest to running, when the walk found nothing."
    )


class OneSample(_Typed):
    """One sample's spoilage type, or the measurement standing in the way."""

    prediction: Optional[str] = Field(
        None, description="PPC, spore spoilage, or no spoilage. Null when unclassified."
    )
    probabilities: dict[str, float] = Field(
        default_factory=dict, description="The three classes and their probabilities."
    )
    confidence: Optional[float] = Field(
        None, description="The top probability. Report it beside the class."
    )
    measurements_used: dict[str, float] = Field(
        default_factory=dict,
        description="The measurements this call ran on, in log10 CFU/mL.",
    )


class LotSamples(_Typed):
    """One lot's PPC prevalence, its counts, and a sample of its predictions.

    The prevalence describes the lot named in `lot_id` and shelf-life prediction
    consumes it as a per-lot figure. The counts and the prevalence always cover
    every sample sent; only `predictions` is ever shortened.
    """

    lot_id: str
    n_samples: int = Field(
        description=(
            "Samples in this lot, whether or not they were classified. Always the "
            "number sent, because an empty lot is an error rather than a zero."
        )
    )
    # Null rather than zero when nothing was classified, and the distinction is
    # load-bearing. `ppc_prevalence` is the figure shelf-life prediction consumes
    # as a per-lot input, so a placeholder zero there does not read as "unknown"
    # -- it reads as a lot with no PPC in it, which is a claim about clean
    # product that nothing measured. Same trap `RetailExit.measured` exists for
    # in response.py.
    ppc_count: Optional[int] = Field(
        None, description="Samples this lot returned PPC for. Null when unclassified."
    )
    non_ppc_count: Optional[int] = Field(
        None, description="Spore spoilage and no spoilage together. Null when unclassified."
    )
    ppc_prevalence: Optional[float] = Field(
        None,
        description=(
            "PPC samples over all samples in the lot. Computed over the whole "
            "lot, never over the predictions shown below. Null when the "
            "measurements reached no model -- never zero, which would read as a "
            "lot with no PPC rather than as a lot nothing could be said about."
        ),
    )
    predictions: list[SampleType] = Field(
        default_factory=list,
        description=(
            "Per-sample results, in the order the samples were sent, capped at "
            "`predictions_returned`. Each carries the index of its own sample."
        ),
    )
    predictions_returned: int = Field(
        0, description="How many per-sample predictions this response carries."
    )
    predictions_truncated: bool = Field(
        False, description="True when the lot has more samples than predictions shown."
    )
    predictions_note: str = Field(
        "", description="What is shown and what is not, in words worth repeating."
    )


def predictions_note(shown: int, total: int) -> str:
    """What the caller is looking at, and what it is not.

    Said in the response rather than left to be inferred from two integers,
    because the thing worth saying is the part that is *not* truncated: a
    shortened prediction list beside a complete prevalence reads like a
    prevalence over the shortened list.
    """
    if total == 0:
        return (
            "No sample was classified, so there are no predictions and no "
            "prevalence. The lot's sample count is still reported."
        )
    if shown >= total:
        return f"All {total} predictions are shown, in the order the samples were sent."
    return (
        f"Showing {shown} of {total} predictions, in the order the samples were "
        f"sent. The counts and ppc_prevalence above cover all {total} samples. "
        "Raise max_predictions to see more."
    )
