"""Route 1 -- spoilage typing: the variant walk, the lot, the dead ends.

ADR 013's rule shapes everything here: no accuracy figure is written anywhere,
so every check about accuracy is a check that the figure comes from a response.
"""

from __future__ import annotations

import math

import pytest
from pydantic import ValidationError

from mcp_server.server import Sample
from mcp_server.variants import pick_variant, to_features
from skill_harness import live
from skill_harness.claims import claim

DOC = "routes/1-spoilage-typing.md"

FULL_SAMPLE = {
    "spc_d7": 2.1, "spc_d14": 4.7, "spc_d21": 6.4,
    "tgn_d7": 1.0, "tgn_d14": 3.7, "tgn_d21": 5.3,
}


@pytest.fixture(scope="session")
def variants(target):
    """The shipped variant list, fetched once from the tool that serves it."""
    return live.call(target, "list_classifier_models")["variants"]


# ---------------------------------------------------------------------------
# Intake
# ---------------------------------------------------------------------------

def test_a_raw_plate_count_is_rejected_rather_than_corrected():
    with claim(
        DOC,
        "**Counts go in as log10 CFU/mL.** A plate count of 4,700,000 CFU/mL "
        "is 6.67. Convert before the call, because a raw count entered where "
        "its logarithm belongs is rejected rather than corrected.",
    ):
        assert round(math.log10(4_700_000), 2) == 6.67
        Sample(spc_d7=6.67)
        with pytest.raises(ValidationError):
            Sample(spc_d7=4_700_000)


def test_day_10_is_a_feature_of_no_variant(variants):
    with claim(
        DOC,
        "- **Day 10 is a feature of no variant.** A d-10 count cannot be used, "
        "and saying so early saves the processor hunting for it.",
    ):
        # Neither the tool arguments nor any shipped variant carry a d-10 slot.
        assert set(Sample.model_fields) == {
            "spc_d7", "spc_d14", "spc_d21", "tgn_d7", "tgn_d14", "tgn_d21",
        }
        for variant in variants:
            assert not any("D10" in feature for feature in variant["features"])


def test_live_a_variant_needs_a_shared_day_or_one_analyte_on_7_and_14(variants):
    with claim(
        DOC,
        "A variant exists only when the lab has **both analytes on at least "
        "one day**, or **one analyte on days 7 and 14**.",
    ):
        for variant in variants:
            features = set(variant["features"])
            shared_day = any(
                {f"SPC_D{day}", f"TGN_D{day}"} <= features for day in (7, 14, 21)
            )
            early_pair = any(
                {f"{analyte}_D7", f"{analyte}_D14"} <= features
                for analyte in ("SPC", "TGN")
            )
            assert shared_day or early_pair, (
                f"{variant['variant_id']} is reachable from measurements the "
                f"intake rule says reach no variant: {sorted(features)}"
            )


def test_live_the_three_dead_end_measurement_sets_reach_no_variant(variants):
    cases = [
        ("- SPC at d 7 alone — no variant.", {"spc_d7": 2.1}),
        (
            "- SPC at d 14 and d 21, with no TGN — no variant. The three-day "
            "SPC model needs d 7 as well.",
            {"spc_d14": 4.7, "spc_d21": 6.4},
        ),
        (
            "- SPC at d 14 with TGN at d 21 — no variant. The pair has to fall "
            "on the same day.",
            {"spc_d14": 4.7, "tgn_d21": 5.3},
        ),
    ]
    for quote, measurements in cases:
        with claim(DOC, quote):
            assert pick_variant(variants, to_features(measurements)) is None


# ---------------------------------------------------------------------------
# The call
# ---------------------------------------------------------------------------

def test_live_the_walk_takes_the_most_accurate_variant_the_lab_reaches(
    variants, target
):
    with claim(
        DOC,
        "**The tool selects the model**: it walks the ten shipped variants "
        "from the most accurate down and uses the first whose every feature is "
        "present.",
    ):
        accuracies = [variant["test_accuracy"] for variant in variants]
        assert len(variants) == 10
        assert accuracies == sorted(accuracies, reverse=True)

        result = live.call(target, "type_one_sample", FULL_SAMPLE)
        assert result["classified"] is True
        assert result["variant"]["variant_id"] == variants[0]["variant_id"]


def test_live_a_lot_caps_its_predictions_and_counts_every_sample(target):
    samples = [
        {name: value + i * 0.01 for name, value in FULL_SAMPLE.items()}
        for i in range(12)
    ]
    lot = live.call(
        target,
        "type_lot_samples",
        {"lot_id": "harness-lot", "samples": samples},
    )
    with claim(
        DOC,
        "**A lot returns ten per-sample predictions by default, and the list "
        "is the only thing shortened.**",
    ):
        assert lot["predictions_returned"] == 10
        assert lot["predictions_truncated"] is True
        assert len(lot["predictions"]) == 10
    with claim(
        DOC,
        "The counts and the prevalence always cover **every** sample whatever "
        "it is set to, so a truncated list never moves the per-lot figure.",
    ):
        assert lot["n_samples"] == 12
        assert lot["ppc_count"] + lot["non_ppc_count"] == 12
        assert lot["ppc_prevalence"] == pytest.approx(lot["ppc_count"] / 12)
    with claim(
        DOC,
        "Each prediction carries `prediction`, `probabilities` across the "
        "three classes, `confidence`, and `sample_index` — its position in the "
        "lot as sent, which matters because the list can be shortened.",
    ):
        for index, prediction in enumerate(lot["predictions"]):
            assert prediction["sample_index"] == index
            assert prediction["prediction"]
            assert len(prediction["probabilities"]) == 3
            assert 0 < prediction["confidence"] <= 1


def test_live_an_unclassifiable_lot_reports_null_not_zero(target):
    with claim(
        DOC,
        "`n_samples` is always the number sent, and the three figures above it "
        "are **null rather than zero** when the measurements reached no model.",
    ):
        lot = live.call(
            target,
            "type_lot_samples",
            {
                "lot_id": "harness-thin-lot",
                "samples": [{"spc_d7": 2.1}, {"spc_d7": 2.4}],
            },
        )
        assert lot["classified"] is False
        assert lot["n_samples"] == 2
        assert lot["ppc_prevalence"] is None
        assert lot["ppc_count"] is None
        assert lot["non_ppc_count"] is None


# ---------------------------------------------------------------------------
# Reading the result
# ---------------------------------------------------------------------------

def test_live_the_accuracy_figure_comes_from_the_response(target):
    with claim(
        DOC,
        "- `variant.test_accuracy` — the accuracy of the model that just ran. "
        "Report this one.",
    ):
        result = live.call(target, "type_one_sample", FULL_SAMPLE)
        assert 0 < result["variant"]["test_accuracy"] <= 1


def test_live_next_best_is_null_at_the_top_and_priced_below_it(target):
    with claim(
        DOC,
        "It is **null when the walk took the top-ranked variant**, and then "
        "there is no comparison to make",
    ):
        top = live.call(target, "type_one_sample", FULL_SAMPLE)
        assert top["next_best_variant"] is None

    with claim(
        DOC,
        "A `next_best_variant` turns a missing measurement into a decision the "
        'processor can price: "d 21 SPC and TGN would move you from four '
        'measurements to six, and the accuracy from X to Y."',
    ):
        partial = live.call(
            target,
            "type_one_sample",
            {"spc_d7": 2.1, "spc_d14": 4.7, "tgn_d7": 1.0, "tgn_d14": 3.7},
        )
        assert partial["classified"] is True
        next_best = partial["next_best_variant"]
        assert next_best is not None
        assert next_best["needs"]
        assert next_best["test_accuracy"] > partial["variant"]["test_accuracy"]


def test_live_no_variant_is_an_answer_not_an_error(target):
    with claim(
        DOC,
        "The tool does not error there — it returns `classified: false` with "
        "`reason`, `missing_measurements` and `nearest_variant`.",
    ):
        result = live.call(target, "type_one_sample", {"spc_d7": 2.1})
        assert result["classified"] is False
        assert result["reason"]
        assert result["missing_measurements"]
        assert result["nearest_variant"] is not None
        assert result["prediction"] is None
        assert result["variant"] is None


def test_live_every_variant_object_carries_the_published_comparison(
    variants, target
):
    with claim(
        DOC,
        "It returns all ten sorted by accuracy, and every `variant` object — "
        "here and on a typing response — carries `published_test_accuracy` and "
        "`accuracy_note`.",
    ):
        for variant in variants:
            assert "published_test_accuracy" in variant
            assert variant["accuracy_note"]

        typed = live.call(target, "type_one_sample", FULL_SAMPLE)["variant"]
        assert "published_test_accuracy" in typed
        assert typed["accuracy_note"]
