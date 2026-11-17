"""Route 3 -- economics and environment: the two-run comparison.

No tool chains two runs; the comparison lives in the conversation. So what the
harness can execute is each run's half of the contract: the echoed seed, the
per-container figures, the truncation trap, the comparability verdict, and the
worked examples the route states as measured.
"""

from __future__ import annotations

import pytest

from mcp_server.disruption import Delay, Disruption
from mcp_server.facility import Run, plan
from mcp_server.response import reshape
from skill_harness import live
from skill_harness.claims import claim
from skill_harness.conftest import synthetic_raw

DOC = "routes/3-economics-and-environment.md"

# Where route 3's measured worked examples moved (issue #34): the route keeps
# each rule inline and points here for the numbers.
ECONOMICS_DOC = "docs/reference/shelf-life-economics.md"

RUN = Run(seed=42)


# ---------------------------------------------------------------------------
# Pure -- the reshaping route 3 reads
# ---------------------------------------------------------------------------

def test_the_per_container_figures_and_their_divisor():
    with claim(
        DOC,
        "So the response returns `shelf_life_value_usd_per_container` and "
        "`co2e_kg_per_container` beside them, with `containers_priced` naming "
        "the divisor it used.",
    ):
        request = plan(Run(seed=42, containers_per_lot=50))
        raw = synthetic_raw(economics={"shelf_life_value_usd": 16.12, "co2e_kg": 6.06})
        economics = reshape(raw, request).economics
        assert economics.containers_priced == 50
        assert economics.shelf_life_value_usd_per_container == pytest.approx(
            16.12 / 50
        )
        assert economics.co2e_kg_per_container == pytest.approx(6.06 / 50)


def test_only_a_pre_consumer_duration_change_breaks_comparability():
    with claim(
        DOC,
        "Each run reports retail spoilage at **its own** pre-consumer day, so "
        "a scenario that changed a pre-consumer duration measures it on a "
        "different day from the baseline, and the difference between the two "
        "mixes more spoilage with later measurement.",
    ):
        pre_consumer = plan(
            RUN,
            disruption=Disruption(delays=[Delay(stage="retail", days=1.0, celsius=6.0)]),
        )
        assert pre_consumer.pre_consumer_duration_changed is True

        # The consumer stage is past retail exit, so lengthening it moves nothing.
        consumer_only = plan(
            RUN,
            disruption=Disruption(
                delays=[Delay(stage="consumer", days=1.0, celsius=6.0)]
            ),
        )
        assert consumer_only.pre_consumer_duration_changed is False


def test_the_verdict_names_what_to_do_in_words():
    with claim(
        DOC,
        "**The run decides this for you.** "
        "`comparability.pct_spoiled_at_retail_comparable` is computable from "
        "one run's own scenario without seeing the other, so the response "
        "carries it, along with `stages_changed` and a `verdict` in words.",
    ):
        request = plan(
            RUN,
            disruption=Disruption(delays=[Delay(stage="retail", days=1.0, celsius=6.0)]),
        )
        comparability = reshape(synthetic_raw(), request).comparability
        assert comparability.pct_spoiled_at_retail_comparable is False
        assert comparability.stages_changed == ["retail"]
        assert "daily_spoilage" in comparability.verdict
        assert "co2e_kg inherits the restriction" in comparability.verdict


# ---------------------------------------------------------------------------
# Live -- the seed, the worked examples, the formulas
# ---------------------------------------------------------------------------

def test_live_every_response_echoes_the_seed(
    long20_baseline, long20_micro, med40_baseline, med40_retail_warm,
    adr012_medium_baseline,
):
    with claim(
        DOC,
        "Every response echoes the seed in `scenario.seed`; check that the two "
        "agree before subtracting.",
    ):
        for run in (long20_baseline, long20_micro, med40_baseline, med40_retail_warm):
            assert run["scenario"]["seed"] == 42
        assert adr012_medium_baseline["scenario"]["seed"] == 7


def test_live_the_returned_value_does_not_reconcile_with_rounded_days(
    long20_baseline,
):
    # Route 3 keeps the rule; the measured gap lives behind its pointer in the
    # reference document (issue #34). Both claims are bound.
    with claim(
        DOC,
        "**Diff `shelf_life_value_usd` as returned. Never recompute it from "
        "`consumer_days`.**",
    ), claim(
        ECONOMICS_DOC,
        "a run reporting `consumer_days: 10.7` at 50 containers per lot "
        "returns **$16.12**, where 10.7 x $0.03 x 50 is $16.05.",
    ):
        shelf_life = long20_baseline["shelf_life"]
        economics = long20_baseline["economics"]
        assert shelf_life["consumer_days"] == 10.7
        assert economics["shelf_life_value_usd"] == 16.12
        assert round(10.7 * 0.03 * 50, 2) == 16.05
        assert economics["shelf_life_value_usd"] != 16.05


def test_live_the_truncation_example_reproduces(long20_baseline, long20_micro):
    # Route 3 keeps the truncation gate; the measured worked table lives
    # behind its pointer in the reference document (issue #34).
    with claim(
        DOC,
        "**Check `shelf_life.truncated` in both runs before you subtract "
        "anything.**",
    ), claim(ECONOMICS_DOC, "| baseline | 19 | 10.7 | false | $16.12 |"):
        assert long20_baseline["shelf_life"]["total_days"] == 19
        assert long20_baseline["shelf_life"]["consumer_days"] == 10.7
        assert long20_baseline["shelf_life"]["truncated"] is False
        assert long20_baseline["economics"]["shelf_life_value_usd"] == 16.12

    with claim(
        ECONOMICS_DOC,
        "| microfiltration | **a bound, > 20** | **a bound, > 11.7** | "
        "**true** | **$0** |",
    ):
        shelf_life = long20_micro["shelf_life"]
        assert shelf_life["truncated"] is True
        assert shelf_life["total_days"]["more_than_days"] == 20
        assert shelf_life["consumer_days"]["more_than_days"] == 11.7
        assert long20_micro["economics"]["shelf_life_value_usd"] == 0

    with claim(
        ECONOMICS_DOC,
        "Subtracting gives **-$16.12** for an intervention that pushed the "
        "crossing *past* the horizon.",
    ):
        assert (
            long20_micro["economics"]["shelf_life_value_usd"]
            - long20_baseline["economics"]["shelf_life_value_usd"]
        ) == pytest.approx(-16.12)


def test_live_the_run_floors_full_precision_not_the_rounded_response(target):
    with claim(
        DOC,
        "A true window of 8.9546 d comes back as `9.0`, so flooring it gives 9 "
        "where the run used 8.",
    ):
        result = live.call(
            target,
            "predict_customize",
            {
                "run": {"seed": 42, "lots": 2, "containers_per_lot": 10, "days": 12},
                # 0.7 d longer at retail puts the true window at 8.9546 d.
                "facility": {"stage_durations": {"retail": 6.1583}},
            },
        )
        assert result["shelf_life"]["pre_consumer_days"] == 9.0
        assert result["shelf_life"]["pre_consumer_day"] == 8


def test_live_retail_exit_matches_the_daily_series_in_both_arms(
    med40_baseline, med40_retail_warm
):
    with claim(
        DOC,
        "Measured, 4 lots, 50 containers per lot, same seed, retail stated 3 "
        "°C above baseline: both runs report `evaluated_on_day: 8`, and each "
        "run's `percent` — 18 and 37 — is the same number as its own day-8 "
        "row. The curve delta is **+19.00 pp at retail exit**, the day the "
        "processor is asking about.",
    ):
        percents = []
        for run in (med40_baseline, med40_retail_warm):
            exit_ = run["economics"]["pct_spoiled_at_retail"]
            assert exit_["evaluated_on_day"] == 8
            day8 = next(row for row in run["daily_spoilage"] if row["day"] == 8)
            assert exit_["percent"] == day8["median_pct"]
            percents.append(exit_["percent"])
        assert percents == [18, 37]
        assert percents[1] - percents[0] == pytest.approx(19.00)


def test_live_a_temperature_only_change_keeps_the_verdict_comparable(
    med40_retail_warm,
):
    with claim(
        DOC,
        "- **Comparable** — difference the two figures, and name the day both "
        "were read at.",
    ):
        comparability = med40_retail_warm["comparability"]
        assert comparability["pct_spoiled_at_retail_comparable"] is True
        assert comparability["stages_changed"] == []


def test_live_a_shared_leg_makes_both_arms_report_not_comparable(target):
    with claim(
        DOC,
        "**The verdict compares this run against the New York baseline, never "
        "against the other run.**",
    ):
        runs = [
            live.call(
                target,
                "predict_customize",
                {
                    "run": {"seed": 42, "lots": 2, "containers_per_lot": 10, "days": 14},
                    "facility": {
                        "extra_legs": [
                            {
                                "after": "transportation_facility_to_retail",
                                "days": 1.0,
                                "celsius": 5.0,
                            }
                        ]
                    },
                },
            )
            for _ in range(2)
        ]
        for run in runs:
            comparability = run["comparability"]
            assert comparability["pct_spoiled_at_retail_comparable"] is False
            assert comparability["stages_changed"] == [
                "transportation_facility_to_retail"
            ]
        assert (
            runs[0]["shelf_life"]["pre_consumer_day"]
            == runs[1]["shelf_life"]["pre_consumer_day"]
        )


def test_live_a_change_after_retail_exit_cannot_move_the_co2e(
    adr012_long_baseline, adr012_long_micro
):
    with claim(
        DOC,
        "Measured: a long shelf-life plant with microfiltration gained three "
        "consumer days and $4.50 of shelf-life value while reporting identical "
        "CO2e, 6.06 kg in both runs.",
    ):
        gained_days = (
            adr012_long_micro["shelf_life"]["consumer_days"]
            - adr012_long_baseline["shelf_life"]["consumer_days"]
        )
        gained_value = (
            adr012_long_micro["economics"]["shelf_life_value_usd"]
            - adr012_long_baseline["economics"]["shelf_life_value_usd"]
        )
        assert gained_days == pytest.approx(3.0)
        assert gained_value == pytest.approx(4.50)
        assert adr012_long_baseline["economics"]["co2e_kg"] == 6.06
        assert adr012_long_micro["economics"]["co2e_kg"] == 6.06


def test_live_the_methods_state_the_constants_the_route_relies_on(target):
    methods = live.call_text(target, "explain_calculations")
    with claim(DOC, "`container_volume_L` is fixed at 1.893."):
        assert "1.893" in methods
    with claim(
        DOC,
        "the run turns containers into litres and multiplies by 0.55 and 0.20 "
        "kg CO2e/L.",
    ):
        assert "0.55" in methods
        assert "0.2" in methods
    with claim(
        DOC,
        "Lau et al. (2023) supports the $0.03 and nothing else; EPA WARM "
        "supports the 0.55 and 0.20 kg CO2e/L factors and nothing else.",
    ):
        assert "0.03" in methods
        assert "Lau" in methods
        assert "WARM" in methods


def test_live_the_unclamped_waste_formula_is_still_published(target):
    with claim(
        DOC,
        "**Do not quote its consumer-waste formula.** It publishes",
    ):
        methods = live.call_text(target, "explain_calculations")
        assert "consumer_waste_L" in methods, (
            "route 3 warns against a formula explain_calculations no longer "
            "publishes -- if the formula was fixed or renamed, retire the warning"
        )
