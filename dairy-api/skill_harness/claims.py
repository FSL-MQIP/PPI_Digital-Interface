"""Bind an assertion to the sentence in the skill that makes the claim.

Issue #33's acceptance criterion is that a red run points at the document to
fix. So every check in this harness runs inside `claim(doc, quote)`, and the
binding cuts both ways:

- The quote must still exist in the document. A claim that was reworded or
  dropped fails the harness even when the code would pass, because the harness
  would otherwise be verifying a sentence nobody reads any more.
- An assertion that fails reports the document and the sentence, not only the
  values, so the failure names the prose that promised the behaviour.

Quotes are compared with whitespace collapsed, because route files hard-wrap
their sentences and a claim is one sentence regardless of where the wrap fell.
"""

from __future__ import annotations

import re
from contextlib import contextmanager
from functools import lru_cache
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]

# Where a bare document name resolves: the skill this harness executes.
DOCS = REPO / "plugin" / "skills" / "milk-spoilage"

# The reference documents route 0 serves, read from the source tree -- never
# through mcp_server.guidance, which prefers the assembled build context and
# so can hand a pure check a stale copy (PR #67, Codex P1).
REFERENCE = REPO / "docs" / "reference"


def _collapse(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


@lru_cache(maxsize=None)
def document_text(name: str) -> str:
    """One document's text: a skill file by bare name, anything else repo-relative."""
    for base in (DOCS, REPO):
        path = base / name
        if path.is_file():
            return path.read_text(encoding="utf-8")
    raise FileNotFoundError(
        f"No document named {name!r} under {DOCS} or {REPO}."
    )


@contextmanager
def claim(doc: str, quote: str):
    """Run assertions about one claim a document makes, named on failure."""
    if _collapse(quote) not in _collapse(document_text(doc)):
        pytest.fail(
            f"{doc} no longer states the claim under test:\n"
            f'  "{quote}"\n'
            f"Either the sentence was reworded -- update this harness to quote "
            f"it as written -- or the claim was dropped and the checks bound to "
            f"it should go too.",
            pytrace=False,
        )
    try:
        yield
    except AssertionError as failure:
        pytest.fail(
            f"{doc} makes a claim the tool surface does not honour.\n"
            f'  claim: "{quote}"\n'
            f"  failure: {failure}",
            pytrace=False,
        )
