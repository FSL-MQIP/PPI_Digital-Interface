"""What this deployment is, so drift against the repository is detectable.

Issues #38 and #42 were both the same defect: the Space was running something
older than the repository, and the only symptom was a field the route files told
an agent to read and the deployment did not return. Under ADR 016 the plugin
points at one URL, so that lag now breaks tool calls rather than only
documentation.

Nothing detected it, because `/health` carried no build identifier. It does now:
deploy_space.py writes build_info.json from the digest of the payload it is
about to upload, and check_deployment.py compares the served digest against a
freshly computed one.

Absent in a development checkout, and that is not an error -- a local run has no
deployment to identify.
"""

from __future__ import annotations

import json
from pathlib import Path

BUILD_INFO_PATH = Path(__file__).resolve().parent / "build_info.json"


def build_info() -> dict:
    """The recorded build identity, or nulls when this is not a deployment."""
    unknown = {"payload_digest": None, "commit": None, "deployed_at": None}
    try:
        recorded = json.loads(BUILD_INFO_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return unknown
    return {key: recorded.get(key) for key in unknown}
