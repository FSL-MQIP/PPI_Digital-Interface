"""Every constant the client copies out of the R model, checked against the R.

Three copies exist, all for the same reason: the client has to state a number
before or after a call that the model owns.

- **The five stage levels and durations** (`supply_chain.py`), because a
  processor states their plant in absolutes and the API takes offsets. If
  config.R moves and the copy does not, every `facility` mapping is off by the
  difference -- a warmer stage could even be routed through the intervention door.
- **The two reference temperatures** a two-event ranking is computed at.
- **The spore-removal log reductions** (`intervention.py`). The API resolves the
  preset name itself, but ADR 012 requires the response to state the number the
  name stands for, and a client stating a level the model no longer applies is
  worse than one that states none.

Reads the R sources directly. Never runs R.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from mcp_server.intervention import SPORE_PRESETS
from mcp_server.supply_chain import (
    BASELINE,
    BUCHANAN_T0,
    FOLD_TMIN,
    PPC_BANDS,
    STAGES,
)

_MODEL = Path(__file__).resolve().parents[2] / "milk-spoilage-model"
_CONFIG = _MODEL / "config.R"
_INTERVENTIONS = _MODEL / "scenarios" / "interventions.R"
_GROWTH = _MODEL / "utils" / "growth_models.R"


def _read(path: Path) -> str:
    if not path.is_file():
        pytest.skip(f"{path.name} is not in this checkout ({path})")
    return path.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def config_text() -> str:
    return _read(_CONFIG)


@pytest.fixture(scope="module")
def interventions_text() -> str:
    return _read(_INTERVENTIONS)


@pytest.fixture(scope="module")
def growth_text() -> str:
    return _read(_GROWTH)


def _stage_block(text: str, stage: str) -> str:
    """The `stage = list(...)` entry, up to the line that closes it.

    Anchored at a line start, because `retail = list(` is also the tail of
    `transportation_facility_to_retail = list(`.
    """
    match = re.search(rf"^\s*{stage} = list\(", text, re.MULTILINE)
    assert match, f"config.R declares no stage {stage}"
    return text[match.start() : text.index("\n    )", match.start())]


def _number(text: str, key: str, where: str) -> float:
    """The value R assigns to `key`, read as the whole literal.

    The whole literal, not a decimal prefix. `(-?[\\d.]+)` stops at the `e` in
    `2.4264e1`, captures `2.4264`, and passes -- so a valid R edit to scientific
    notation moves the model's baseline by a factor of ten while this guard
    reports agreement. Every offset the client computes would then be wrong, and
    the drift test built to catch exactly that would be the thing hiding it.

    So the token runs to the delimiter and Python parses it. Python and R read
    `2.4264e1`, `.5` and `-3.62` the same way, and a literal Python cannot read
    fails here rather than being silently truncated to the part it can.
    """
    # Comments first: config.R's facility block explains a past unit error in
    # prose that repeats the figures around it.
    block = re.sub(r"#[^\n]*", "", text)
    match = re.search(rf"\b{key}\s*=\s*([^,\s)]+)", block)
    assert match, f"config.R's {where} carries no {key}"
    literal = match.group(1)
    try:
        return float(literal)
    except ValueError:
        raise AssertionError(
            f"config.R's {where} sets {key} = {literal!r}, which is not a number "
            f"Python reads the same way R does. Read it by hand and compare it "
            f"against mcp_server/supply_chain.py before trusting this suite."
        ) from None


@pytest.mark.parametrize("stage", STAGES)
def test_the_stage_baseline_is_the_one_config_r_sets(config_text, stage):
    block = _stage_block(config_text, stage)
    assert BASELINE[stage]["level"] == _number(block, "mean", stage)
    assert BASELINE[stage]["days"] == _number(block, "duration", stage)


def test_the_five_stages_are_config_rs_stage_order(config_text):
    order = config_text[config_text.index("stage_order = c(") :]
    order = order[: order.index(")")]
    assert tuple(re.findall(r'"([a-z_]+)"', order)) == STAGES


def test_the_shipped_default_is_the_medium_band(config_text):
    """config.R ships the medium row, so `plant_category` omitted must reproduce it."""
    assert PPC_BANDS["medium"] == (
        _number(config_text, "P_ppc_min", "config"),
        _number(config_text, "P_ppc_max", "config"),
    )


def test_the_fold_uses_the_models_own_ppc_minimum_growth_temperature(config_text):
    assert FOLD_TMIN == _number(config_text, "Tmin_PPC", "config")


def test_the_ranking_uses_the_buchanan_pathways_own_reference_temperature(growth_text):
    """muAtNewTemp()'s T0 default, which is the second temperature events rank at.

    Anchored on the signature: lagAtNewTemp() further down carries its own `T0`,
    at 1.15, and a whole-file search would find whichever came first.
    """
    signature = growth_text[growth_text.index("muAtNewTemp <- function(") :]
    assert BUCHANAN_T0 == _number(signature[: signature.index(")")], "T0", "muAtNewTemp")


@pytest.mark.parametrize("preset", sorted(SPORE_PRESETS))
def test_a_spore_preset_states_the_reduction_the_model_applies(
    interventions_text, preset
):
    """The response quotes this number; the run applies the R one. One number."""
    block = interventions_text[
        interventions_text.index("spore_reduction_presets <- list(") :
    ]
    assert SPORE_PRESETS[preset].log_reduction == _number(
        block[: block.index("\n)")], preset, "spore_reduction_presets"
    )


def test_the_client_carries_no_preset_the_model_would_reject(interventions_text):
    """A name the client offers and the R does not know is an HTTP 400 at run time."""
    block = interventions_text[
        interventions_text.index("spore_reduction_presets <- list(") :
    ]
    known = set(re.findall(r"^\s+(\w+) = ", block[: block.index("\n)")], re.MULTILINE))
    assert set(SPORE_PRESETS) <= known


# ---------------------------------------------------------------------------
# The guard, guarded
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("literal", "expected"),
    [
        ("2.4264", 2.4264),
        # The one that used to pass while the baseline had moved by a factor of
        # ten: a decimal-prefix regex captures 2.4264 and stops at the `e`.
        ("2.4264e1", 24.264),
        ("1.7037e-1", 0.17037),
        ("-3.62", -3.62),
        (".5", 0.5),
    ],
)
def test_a_scientific_literal_is_read_whole_not_truncated(literal, expected):
    assert _number(f"retail = list(\n  duration = {literal}\n)", "duration", "x") == (
        expected
    )


def test_a_literal_python_cannot_read_fails_rather_than_being_truncated():
    """R's `1L` is an integer literal Python's float() refuses.

    Failing is right: the alternative is reading `1` off the front of something
    and reporting agreement about a number nobody checked.
    """
    with pytest.raises(AssertionError, match="not a number"):
        _number("retail = list(\n  duration = 1L\n)", "duration", "x")


def test_a_comment_repeating_a_figure_is_not_mistaken_for_the_assignment():
    """config.R's facility block explains a past unit error in prose.

    That prose repeats `2.4264` and `2.4264 / 24` around the real assignment, so
    a reader that does not strip comments can pick up the wrong one.
    """
    block = (
        "processing_facility = list(\n"
        "  # 2.4264 days, the span of the CSV. This was duration = 99.9,\n"
        "  # treating the figure as hours.\n"
        "  duration = 2.4264\n"
        ")"
    )
    assert _number(block, "duration", "x") == 2.4264
