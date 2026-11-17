"""Bundled guidance — the six route files and the reference documents.

ADR 011 serves these from a **tool** rather than a resource, because a resource
is application-controlled and the model cannot decide mid-answer that it now
needs the route-4 file. Self-triage is the artifact under test, so the model has
to be able to fetch.

Two directories, resolved the way services/classifier.py resolves its variants:
the assembled build context first -- which is also the in-image location -- then
the development checkout.
"""

from __future__ import annotations

import re
from pathlib import Path

_HERE = Path(__file__).resolve().parent  # dairy-api/mcp_server
_API = _HERE.parent  # dairy-api, and /app inside the image
_REPO = _API.parent

# build.sh assembles `guidance/` from the two source trees below, so the image
# carries one directory and a clean checkout needs no build step to serve either.
_ROUTE_DIRS = [
    _API / "guidance" / "routes",
    _REPO / "plugin" / "skills" / "milk-spoilage" / "routes",
]
_DOCUMENT_DIRS = [
    _API / "guidance" / "reference",
    _REPO / "docs" / "reference",
]

_ROUTE_FILE = re.compile(r"^(\d+)-")


def _resolve(candidates: list[Path], what: str) -> Path:
    for path in candidates:
        if path.is_dir():
            return path
    raise FileNotFoundError(
        f"Cannot locate the {what} directory. Run `bash dairy-api/build.sh` to "
        "assemble the build context. Tried: "
        + ", ".join(str(p) for p in candidates)
    )


def _routes() -> dict[int, Path]:
    directory = _resolve(_ROUTE_DIRS, "route file")
    found = {}
    for path in sorted(directory.glob("*.md")):
        match = _ROUTE_FILE.match(path.name)
        if match:
            found[int(match.group(1))] = path
    return found


def _documents() -> dict[str, Path]:
    directory = _resolve(_DOCUMENT_DIRS, "reference document")
    return {path.stem: path for path in sorted(directory.glob("*.md"))}


def route_numbers() -> list[int]:
    return sorted(_routes())


def document_names() -> list[str]:
    return sorted(_documents())


# ValueError rather than KeyError throughout: the message reaches the agent as
# the tool's error text, and KeyError's repr wraps it in quotes.
def read_route(route: int) -> str:
    routes = _routes()
    if route not in routes:
        raise ValueError(
            f"No route file for intent {route}. The intents are "
            + ", ".join(str(n) for n in sorted(routes))
        )
    return routes[route].read_text(encoding="utf-8")


def read_document(document: str) -> str:
    documents = _documents()
    name = document[:-3] if document.endswith(".md") else document
    if name not in documents:
        raise ValueError(
            f"No reference document named {document!r}. Available: "
            + ", ".join(sorted(documents))
        )
    return documents[name].read_text(encoding="utf-8")


def index() -> str:
    """What `read_guidance` can be asked for, when it is asked for nothing."""
    routes = _routes()
    lines = ["Route files, by intent -- read the route before answering:"]
    lines += [f"  route={n}  {routes[n].stem}" for n in sorted(routes)]
    lines.append("")
    lines.append("Reference documents:")
    lines += [f"  document={name}" for name in sorted(_documents())]
    return "\n".join(lines)
