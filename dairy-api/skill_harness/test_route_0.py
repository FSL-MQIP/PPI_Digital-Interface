"""Route 0 -- general information: the served documents and the fixed numbers.

No model runs on this route, so what is executable is the serving itself --
every name the table promises resolves -- plus the numeric claims the route
states as published figures.
"""

from __future__ import annotations

import math
import re

import pytest

from skill_harness import live
from skill_harness.claims import REFERENCE, REPO, claim, document_text

DOC = "routes/0-general-information.md"
ROUTER = "SKILL.md"


def reference_text(name: str) -> str:
    """A reference document, from the source tree it is edited in.

    Never through mcp_server.guidance: that resolver prefers the assembled
    build context, so a pure check reading through it can validate a stale
    copy (PR #67, Codex P1). What the assembled copy serves is the live
    half's question, asserted byte-equal against these same files below.
    """
    return document_text(f"docs/reference/{name}.md")

# The five condensed Cornell MQIP extension fact sheets route 0's traceability
# rule covers. The other six documents carry their own citations.
MQIP_FACT_SHEETS = [
    "general-dairy-bacteriology",
    "vsl-program",
    "shelf-life-evaluation-methods",
    "ppc-prevention-practices",
    "psychrotrophic-spore-formers",
]


def table_documents() -> list[str]:
    return re.findall(r"\| `([a-z0-9-]+)` \|", document_text(DOC))


def test_the_document_table_names_eleven_documents():
    with claim(
        DOC,
        'Reach one by name — `read_guidance(document="general-dairy-bacteriology")`.',
    ):
        names = table_documents()
        assert len(names) == 11
        on_disk = {path.stem for path in REFERENCE.glob("*.md")}
        assert set(names) == on_disk - {"README"}


def test_every_mqip_fact_sheet_carries_its_source_url():
    with claim(
        DOC,
        "**link the source URL from the file's header alongside anything you "
        "quote from it**. The URL is in each file's provenance block.",
    ):
        for name in MQIP_FACT_SHEETS:
            assert "cals.cornell.edu" in reference_text(name), (
                f"{name} has no Cornell source URL to link"
            )


def test_the_unpublished_manuscript_is_marked_in_press():
    with claim(
        DOC,
        "`non-ppc-growth-model` condenses a manuscript that is not yet "
        "published. Cite it as in press, and keep to its conclusions rather "
        "than its text.",
    ):
        assert "in press" in reference_text("non-ppc-growth-model")


def test_the_three_thresholds_hold_their_numbers():
    with claim(
        DOC,
        "| PMO regulatory limit | 20,000 cfu/mL (4.3 log10) | the legal limit "
        "while milk is offered for sale |",
    ):
        assert round(math.log10(20_000), 1) == 4.3
    with claim(
        DOC,
        "| Model spoilage threshold | **6 log10 cfu/mL** | the line this "
        "simulation calls spoilage |",
    ):
        config = (REPO / "milk-spoilage-model" / "config.R").read_text(
            encoding="utf-8"
        )
        assert re.search(r"spoilage_threshold\s*=\s*6(\.0)?\b", config), (
            "config.R no longer sets the spoilage threshold at 6 log10"
        )


def test_the_two_speed_pattern_quotes_its_source():
    with claim(
        DOC,
        "Milk recontaminated after pasteurisation is commonly spoiled by "
        "*Pseudomonas*, which can spoil it **7 to 10 days** after processing.",
    ):
        vsl = reference_text("vsl-program")
        assert "7 to 10 days" in vsl
        assert "17 to 21 days" in vsl


# ---------------------------------------------------------------------------
# Live -- the serving itself
# ---------------------------------------------------------------------------

def test_live_the_bare_call_returns_the_full_index(target):
    with claim(
        DOC,
        "Calling `read_guidance()` with no argument returns the index of every "
        "name below, plus the six route numbers.",
    ):
        index = live.call_text(target, "read_guidance")
        for number in range(6):
            assert f"route={number}" in index
        for name in table_documents():
            assert name in index


@pytest.mark.parametrize(
    "name",
    sorted(set(re.findall(r"\| `([a-z0-9-]+)` \|", document_text(
        "routes/0-general-information.md"
    )))),
)
def test_live_every_named_document_is_served_and_is_this_checkouts(target, name):
    with claim(DOC, f"| `{name}` |"):
        served = live.call_text(target, "read_guidance", {"document": name})
        assert served == document_text(f"docs/reference/{name}.md")


@pytest.mark.parametrize("route", [0, 1, 2, 3, 4, 5])
def test_live_the_served_route_files_are_this_checkouts(target, route):
    """The pinned target serves the same route files this harness asserts about.

    A drift here means the image or the assembled build context carries an
    older skill -- the staleness class the digest pin exists for, caught at
    the content level, per file.
    """
    with claim(
        ROUTER,
        "Name the **intent** from the question, then call `read_guidance(route=N)` "
        "for that intent **before you answer**.",
    ):
        by_route = {
            0: "0-general-information.md",
            1: "1-spoilage-typing.md",
            2: "2-shelf-life-prediction.md",
            3: "3-economics-and-environment.md",
            4: "4-prevention-strategies.md",
            5: "5-disruption-scenarios.md",
        }
        served = live.call_text(target, "read_guidance", {"route": route})
        assert served == document_text(f"routes/{by_route[route]}")
