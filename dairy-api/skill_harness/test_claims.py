"""The claim() seam itself, before anything is asserted through it.

Every other test in this harness reports through claim(), so a defect here
mislabels every failure in the suite. Tested against a real route file, because
the contract is about real documents: the quote must be found across the
markdown line wrapping it was written under.
"""

import re
from pathlib import Path

import pytest

from skill_harness.claims import DOCS, claim, document_text

ROUTER = "SKILL.md"

# A sentence SKILL.md wraps across two lines. If claim() compared raw strings it
# would miss this, and every multi-line quote in the suite would false-fail.
WRAPPED = (
    "Name the intent, say which measurements it needs, ask for exactly those "
    "when they are absent, then call the tool."
)


def test_a_present_quote_lets_a_true_assertion_pass():
    with claim(ROUTER, WRAPPED):
        assert True


def test_a_failing_assertion_names_the_document_and_the_quote():
    with pytest.raises(pytest.fail.Exception) as caught:
        with claim(ROUTER, WRAPPED):
            assert 1 == 2, "the tool disagrees"
    message = str(caught.value)
    assert ROUTER in message
    assert WRAPPED[:40] in message
    assert "the tool disagrees" in message


def test_a_vanished_quote_fails_even_when_the_assertion_would_pass():
    with pytest.raises(pytest.fail.Exception) as caught:
        with claim(ROUTER, "A sentence no route file has ever stated."):
            assert True
    message = str(caught.value)
    assert ROUTER in message
    assert "no longer states" in message


def test_documents_outside_the_skill_resolve_by_repo_relative_path():
    text = document_text("docs/demonstration/facility.md")
    assert "The demonstration facility" in text


def test_every_route_file_is_reachable():
    from skill_harness.test_surface import SKILL_DOCS

    for name in SKILL_DOCS:
        assert (DOCS / name).is_file() or document_text(name)


def test_the_pure_half_never_reads_through_the_assembled_resolver():
    """No harness module may import mcp_server.guidance.

    That resolver prefers the assembled `dairy-api/guidance/` over the source
    trees, so a pure check reading through it validates a stale copy and
    reports green on exactly the edit-in-progress workflow the pure half
    exists for (PR #67, Codex P1). Pure checks read the source trees -- via
    claims.document_text or direct globs -- and only the live half reaches
    the resolver, over MCP, where the target fixture has already refused a
    stale assembly.
    """
    resolver_import = re.compile(
        r"^\s*(from mcp_server import [^\n]*\bguidance\b|import mcp_server\.guidance)",
        re.MULTILINE,
    )
    offenders = [
        module.name
        for module in sorted(Path(__file__).parent.glob("*.py"))
        if resolver_import.search(module.read_text(encoding="utf-8"))
    ]
    assert not offenders, (
        f"{offenders} resolve documents through mcp_server.guidance, which "
        f"prefers the assembled build context over the source trees"
    )
