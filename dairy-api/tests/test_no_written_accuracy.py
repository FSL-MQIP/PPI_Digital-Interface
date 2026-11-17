"""No accuracy figure is written into the tool, the skill, or the READMEs.

ADR 013's rule is enforced by procedure, never by prose: the walk reads
`test_accuracy` from `/variants`, so a figure typed into a file is drift waiting
to happen. It had been caught three times before the rule was written.

The two READMEs joined the scan after a fourth: the repository README described
`baseline` as "all 6 features, 95.8%", which is the shipped artifact's accuracy
rounded, sitting in prose where nothing could keep it honest. A file that tells
a reader which variant to use is close enough to the skill to be held to the
skill's rule.
"""

import json
from pathlib import Path

import pytest

_API = Path(__file__).resolve().parent.parent
_REPO = _API.parent

SEARCHED = sorted(
    list((_API / "mcp_server").rglob("*.py"))
    + list((_REPO / "plugin" / "skills" / "milk-spoilage").rglob("*.md"))
    + [_REPO / "README.md", _API / "README.md"]
)


def _accuracies() -> list[float]:
    config = json.loads(
        (_API / "models" / "variants" / "variants_config.json").read_text(
            encoding="utf-8"
        )
    )
    served = [v["test_accuracy"] for v in config["variants"].values()]
    # The paper's figures for the same variants. Quoting one of these as the
    # shipped model's accuracy is trap 3 in the demonstration.
    published = [0.964, 0.942, 0.863, 0.899, 0.605, 0.771, 0.699, 0.728, 0.739]
    return served + published


def _forbidden() -> set[str]:
    written = set()
    for accuracy in _accuracies():
        written.add(f"{accuracy:.3f}")           # 0.958
        written.add(f"{accuracy:.4f}")           # 0.9576
        written.add(f"{accuracy * 100:.1f}")     # 95.8
    return written


def test_there_are_files_to_search():
    """A path typo would otherwise make this suite pass by searching nothing."""
    assert len(SEARCHED) >= 9
    assert all(path.is_file() for path in SEARCHED), [
        p for p in SEARCHED if not p.is_file()
    ]


@pytest.mark.parametrize("path", SEARCHED, ids=lambda p: p.name)
def test_no_shipped_accuracy_is_written_into_the_file(path):
    text = path.read_text(encoding="utf-8")
    found = sorted(figure for figure in _forbidden() if figure in text)
    assert not found, (
        f"{path.relative_to(_REPO)} writes {found}. Read every accuracy from the "
        "/variants response instead -- ADR 013."
    )
