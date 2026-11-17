"""The route files name tools, and only tools.

ADR 015 renamed the surface for what a processor says; issue #40 rewrote the
route files to it. These checks are what stop them drifting back: a route file
naming an HTTP endpoint or a raw /simulate body key is a failure, and so is a
route file naming a tool the server does not serve.

The canonical tool list is check_deployment.EXERCISE, which the deploy check
already holds equal to what the server serves -- one list, three enforcers.
"""

from __future__ import annotations

import re

import pytest

from check_deployment import EXERCISE
from skill_harness import live
from skill_harness.claims import DOCS, REFERENCE, document_text

TOOLS = set(EXERCISE)

SKILL_DOCS = [
    "SKILL.md",
    "routes/0-general-information.md",
    "routes/1-spoilage-typing.md",
    "routes/2-shelf-life-prediction.md",
    "routes/3-economics-and-environment.md",
    "routes/4-prevention-strategies.md",
    "routes/5-disruption-scenarios.md",
]

# The surface ADR 015 hides. An agent is told none of these exist, so a route
# file teaching one is teaching a parameter the tools reject.
ENDPOINTS = ["/simulate", "/classify", "/variants", "/scenarios", "/health", "/mcp"]
RAW_KEYS = [
    "temp_delta", "temp_mean", "temp_max", "temp_spike", "temp_shift",
    "duration_delta", "P_ppc_min", "P_ppc_max", "n_units", "n_lots",
    "sim_duration", "stage_temp_overrides", "ppc_frequency_factor",
    "ppc_initial_reduction_log", "ppc_remove_st", "spore_reduction",
    "profile_csv",
]

# `something(` inside backticks is a call the route file tells the agent to
# make. Every one must be a served tool. `max(...)` is arithmetic notation in
# route 3's waste-cohort formula, not a call.
_CALLABLE = re.compile(r"`([a-z_][a-z0-9_]*)\(")
_NOT_CALLS = {"max"}


@pytest.mark.parametrize("doc", SKILL_DOCS)
def test_no_route_file_names_an_endpoint_or_a_raw_api_key(doc):
    text = document_text(doc)
    offences = [
        token
        for token in ENDPOINTS + RAW_KEYS
        if re.search(rf"(?<![\w/]){re.escape(token)}(?!\w)", text)
    ]
    assert not offences, (
        f"{doc} names the HTTP surface ADR 015 hides: {offences}. Name the "
        f"tool and its parameters instead."
    )


@pytest.mark.parametrize("doc", SKILL_DOCS)
def test_every_call_a_route_file_prescribes_is_a_served_tool(doc):
    called = set(_CALLABLE.findall(document_text(doc))) - _NOT_CALLS
    unknown = called - TOOLS
    assert not unknown, (
        f"{doc} tells the agent to call {sorted(unknown)}, which the server "
        f"does not serve. The nine tools are {sorted(TOOLS)}."
    )


def test_every_served_tool_is_prescribed_by_some_route_file():
    text = "\n".join(document_text(doc) for doc in SKILL_DOCS)
    unmentioned = {tool for tool in TOOLS if tool not in text}
    assert not unmentioned, (
        f"No route file mentions {sorted(unmentioned)}: a served tool no "
        f"procedure reaches is either dead or undocumented."
    )


def test_every_route_number_the_router_names_has_a_file():
    numbers = sorted(
        int(path.name.split("-")[0]) for path in (DOCS / "routes").glob("*.md")
    )
    assert numbers == [0, 1, 2, 3, 4, 5]


def test_every_document_route_0_names_exists_at_source():
    """Route 0's table is a promise that read_guidance can serve each name.

    Checked against the source tree the documents are edited in, never through
    mcp_server.guidance -- see test_claims. What the target actually serves is
    the live half's question, asserted byte-equal in test_route_0.
    """
    named = set(re.findall(r"\| `([a-z0-9-]+)` \|", document_text("routes/0-general-information.md")))
    assert named, "route 0's document table was not found"
    on_disk = {path.stem for path in REFERENCE.glob("*.md")}
    missing = named - on_disk
    assert not missing, (
        f"routes/0-general-information.md names documents docs/reference does "
        f"not hold: {sorted(missing)}. On disk: {sorted(on_disk)}."
    )


def test_the_live_target_serves_exactly_the_nine_tools(target):
    assert live.tool_names(target) == TOOLS
