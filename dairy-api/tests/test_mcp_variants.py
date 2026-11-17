"""The variant walk — ADR 013's rule enforced by procedure.

These are pure-function tests. No API, no model artifacts: the walk is the piece
that decides which model runs, and it decides it from `/variants` alone.
"""

import pytest

from mcp_server.variants import (
    FEATURE_OF,
    measurement_label,
    nearest_miss,
    next_best,
    pick_variant,
    to_features,
)

# The ten shipped variants, in the order /variants returns them: sorted by
# test_accuracy, highest first. Accuracies are the shipped artifact's own, and
# they live here only so the tie-break can be exercised.
VARIANTS = [
    {"variant_id": "baseline", "test_accuracy": 0.9576,
     "features": ["SPC_D7", "SPC_D14", "SPC_D21", "TGN_D7", "TGN_D14", "TGN_D21"]},
    {"variant_id": "scenario_1_days14_21", "test_accuracy": 0.9415,
     "features": ["SPC_D14", "SPC_D21", "TGN_D14", "TGN_D21"]},
    {"variant_id": "scenario_3_day21", "test_accuracy": 0.9372,
     "features": ["SPC_D21", "TGN_D21"]},
    {"variant_id": "scenario_4_day14", "test_accuracy": 0.8742,
     "features": ["SPC_D14", "TGN_D14"]},
    {"variant_id": "scenario_2_days7_14", "test_accuracy": 0.8731,
     "features": ["SPC_D7", "SPC_D14", "TGN_D7", "TGN_D14"]},
    {"variant_id": "scenario_6_spc_all", "test_accuracy": 0.7831,
     "features": ["SPC_D7", "SPC_D14", "SPC_D21"]},
    {"variant_id": "scenario_8_spc_7_14", "test_accuracy": 0.7332,
     "features": ["SPC_D7", "SPC_D14"]},
    {"variant_id": "scenario_9_tgn_7_14", "test_accuracy": 0.7313,
     "features": ["TGN_D7", "TGN_D14"]},
    {"variant_id": "scenario_7_tgn_all", "test_accuracy": 0.6988,
     "features": ["TGN_D7", "TGN_D14", "TGN_D21"]},
    {"variant_id": "scenario_5_day7", "test_accuracy": 0.6279,
     "features": ["SPC_D7", "TGN_D7"]},
]


def test_to_features_drops_absent_measurements():
    assert to_features({"spc_d7": 2.1, "spc_d14": None, "tgn_d7": 1.0}) == {
        "SPC_D7": 2.1,
        "TGN_D7": 1.0,
    }


def test_every_measurement_maps_to_a_feature():
    assert set(FEATURE_OF) == {
        "spc_d7", "spc_d14", "spc_d21", "tgn_d7", "tgn_d14", "tgn_d21"
    }


def test_full_measurement_set_selects_the_top_variant():
    have = {"SPC_D7", "SPC_D14", "SPC_D21", "TGN_D7", "TGN_D14", "TGN_D21"}
    assert pick_variant(VARIANTS, have)["variant_id"] == "baseline"


def test_the_walk_takes_the_first_fit_not_the_most_features():
    """Both analytes on days 7 and 14 fit two variants. The higher one wins.

    scenario_2_days7_14 uses all four measurements and scenario_4_day14 uses two
    of them, and scenario_4 scores higher. The rule is accuracy order, so the
    two-measurement model is the answer -- picking the variant that consumes the
    most measurements would be a different, worse rule.
    """
    have = {"SPC_D7", "SPC_D14", "TGN_D7", "TGN_D14"}
    assert pick_variant(VARIANTS, have)["variant_id"] == "scenario_4_day14"


def test_one_analyte_on_two_days_reaches_a_variant():
    assert pick_variant(VARIANTS, {"SPC_D7", "SPC_D14"})["variant_id"] == "scenario_8_spc_7_14"


@pytest.mark.parametrize(
    "have",
    [
        {"SPC_D7"},                 # one analyte, one day
        {"SPC_D14", "SPC_D21"},     # SPC on days 14 and 21: the 3-day SPC model needs day 7
        {"SPC_D14", "TGN_D21"},     # a pair that does not fall on the same day
    ],
)
def test_measurement_sets_that_reach_no_variant(have):
    assert pick_variant(VARIANTS, have) is None


def test_nearest_miss_prefers_the_fewest_missing_then_the_higher_accuracy():
    """SPC at day 7 alone. Two variants are one measurement away."""
    near = nearest_miss(VARIANTS, {"SPC_D7"})
    # scenario_8_spc_7_14 (0.7332) and scenario_5_day7 (0.6279) each miss one.
    assert near["variant"]["variant_id"] == "scenario_8_spc_7_14"
    assert near["missing"] == ["SPC_D14"]


def test_nearest_miss_names_a_measurement_from_the_other_analyte():
    near = nearest_miss(VARIANTS, {"TGN_D21"})
    assert near["variant"]["variant_id"] == "scenario_3_day21"
    assert near["missing"] == ["SPC_D21"]


def test_next_best_is_the_entry_immediately_above_the_selection():
    have = {"SPC_D7", "SPC_D14"}
    selected = pick_variant(VARIANTS, have)
    above = next_best(VARIANTS, selected, have)
    assert above["variant"]["variant_id"] == "scenario_6_spc_all"
    assert above["missing"] == ["SPC_D21"]


def test_the_top_variant_has_nothing_above_it():
    have = set(FEATURE_OF.values())
    selected = pick_variant(VARIANTS, have)
    assert next_best(VARIANTS, selected, have) is None


def test_measurement_label_reads_as_a_lab_would_say_it():
    assert measurement_label("SPC_D21") == "SPC at day 21"
    assert measurement_label("TGN_D7") == "TGN at day 7"
