#!/usr/bin/env python
"""Fail when the Space is running something older than this checkout.

Issues #38 and #42 were the same defect twice: the deployment lagged the
repository, and the only symptom was a field the route files told an agent to
read and the deployment did not return. Under ADR 016 the plugin declares one
URL, so that lag now breaks tool calls rather than only documentation.

Run after every deploy, and before trusting any demonstration run:

    bash dairy-api/build.sh
    python dairy-api/check_deployment.py --space chenhaoq87/dairy-spoilage-api

It checks five things, reports every one that fails, and exits non-zero if any
did:

  1. The deployment's payload digest equals this build context's.
  2. The deployment carries no file this build context does not. The digest
     cannot see that -- it hashes the local manifest -- so a file the
     repository dropped and the Space kept leaves the digest matching. Needs
     the Hub API, so it runs only with --space.
  3. /health reports the R runtime up and every classifier variant loaded.
  4. /mcp completes the MCP handshake.
  5. Every tool in EXERCISE lists, and every one of them executes -- which covers
     all three call paths: the bundled files read_guidance serves, the loopback
     proxy behind the classifier tools, and the R subprocess behind the
     prediction tools.
"""

from __future__ import annotations

import argparse
import asyncio
import sys

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from payload import CONTEXT, digest

# Every tool the deployment must serve, and a call that exercises it. Listing is
# not enough: a tool whose loopback call fails lists perfectly well.
_SAMPLE = {
    "spc_d7": 2.1, "spc_d14": 4.7, "spc_d21": 6.4,
    "tgn_d7": 1.0, "tgn_d14": 3.7, "tgn_d21": 5.3,
}
#
# A tool added to the server and not added here turns the drift check red, which
# is the point: the served tool list and this map have to be the same set.
#
# The two prediction tools run a real simulation, so they are the slow entries.
# The run below is deliberately tiny -- the production default takes about 40
# seconds on the free CPU-basic Space, and this check is not measuring the model.
_TINY_RUN = {"seed": 7, "lots": 2, "containers_per_lot": 3, "days": 12}
EXERCISE = {
    "read_guidance": {"route": 1},
    "list_classifier_models": {},
    "type_one_sample": _SAMPLE,
    # More samples than the default prediction cap, so the deployment has to
    # demonstrate the truncation rather than merely carry the code for it. One
    # HTTP call either way -- the classifier runs them as a batch.
    "type_lot_samples": {
        "lot_id": "deployment-check",
        "samples": [
            {name: value + i * 0.01 for name, value in _SAMPLE.items()}
            for i in range(12)
        ],
    },
    "predict_default": {"run": _TINY_RUN},
    "predict_customize": {
        # Both doors in one call: a colder stage is an intervention, a leg the
        # five shipped stages do not have is a disruption. A deployment that
        # serves an older `facility` mapping fails here rather than silently
        # answering for a different cold chain.
        "run": _TINY_RUN,
        "facility": {
            "stage_temperatures": {"retail": {"shift": -2.5}},
            "extra_legs": [
                {"after": "transportation_facility_to_retail", "celsius": 5.0, "days": 1.0}
            ],
        },
    },
    "model_an_intervention": {
        # A named lever, so the response has to carry the level it resolved to. A
        # deployment serving the name without the number fails the assertion
        # below rather than answering with a citation-shaped hole.
        "run": _TINY_RUN,
        "intervention": {"named": ["increase_equipment_cleaning"]},
    },
    "model_a_disruption": {
        # A thermal excursion on one stage and a delay on another: the mixed
        # scenario two separate tools could not have modelled.
        "run": _TINY_RUN,
        "disruption": {
            "thermal_events": [
                {"stage": "processing_facility", "celsius": 18.0, "days": 0.3}
            ],
            "delays": [
                {
                    "stage": "transportation_facility_to_retail",
                    "days": 0.5,
                    "celsius": 12.0,
                }
            ],
        },
    },
    "explain_calculations": {},
}


def _lot_truncated(lot: dict) -> bool:
    """The lot capped its predictions and still counted every sample.

    Both halves matter. A cap that also shortened the counts would turn a lot's
    PPC prevalence into a prevalence over the ten samples that happened to be
    shown, which is the figure route 2 consumes.
    """
    sent = len(EXERCISE["type_lot_samples"]["samples"])
    return (
        lot.get("predictions_truncated") is True
        and len(lot.get("predictions") or []) < sent
        and lot.get("n_samples") == sent
        and lot.get("ppc_count", 0) + lot.get("non_ppc_count", 0) == sent
    )


def space_url(space: str) -> str:
    return f"https://{space.replace('/', '-').lower()}.hf.space"


def describe(exc: BaseException) -> str:
    """An exception a reader can act on.

    The MCP client runs its transport in a task group, so a 404 from a Space
    serving an older build arrives as "ExceptionGroup: unhandled errors in a
    TaskGroup (1 sub-exception)" -- which says nothing about what went wrong.
    Flatten to the leaves.
    """
    nested = getattr(exc, "exceptions", None)
    if nested:
        return "; ".join(describe(sub) for sub in nested)
    return f"{type(exc).__name__}: {exc}"


def check_file_set(space: str) -> list[str]:
    """Files the Space carries that this build context does not.

    The digest cannot see these. It hashes the local manifest, so a file the
    repository dropped but the Space still holds leaves the digest matching
    while the deployment carries something the repository does not. Only a
    listing of what is actually deployed catches it, which needs the Hub API
    and therefore a Space id -- `--url` skips this check and says so.
    """
    from huggingface_hub import HfApi

    from payload import stale_remote_files

    deployed = HfApi().list_repo_files(repo_id=space, repo_type="space")
    stale = stale_remote_files(deployed, CONTEXT)
    if not stale:
        return []
    return [
        "The deployment carries files this checkout does not: "
        + ", ".join(stale)
        + ". Redeploy -- deploy_space.py mirrors the manifest, so a deploy "
        "removes them."
    ]


async def check(base_url: str) -> list[str]:
    """Every failure found, as messages. Empty means the deployment is current."""
    failures: list[str] = []

    try:
        async with httpx.AsyncClient(timeout=120) as client:
            health = (await client.get(f"{base_url}/health")).json()
    except (httpx.HTTPError, ValueError) as exc:
        return [f"{base_url}/health did not answer: {exc}"]

    local = digest(CONTEXT)
    deployed = health.get("build", {}).get("payload_digest")
    if deployed is None:
        failures.append(
            "The deployment reports no payload digest. Either it predates "
            "build_info.json or deploy_space.py did not stamp it, and either way "
            "it cannot be shown to be this checkout. Redeploy."
        )
    elif deployed != local:
        failures.append(
            "The deployment is not this checkout.\n"
            f"    deployed: {deployed}  (commit {health['build'].get('commit')}, "
            f"{health['build'].get('deployed_at')})\n"
            f"    local:    {local}\n"
            "  Redeploy, or check out the commit the Space is running."
        )

    if not health.get("r_runtime"):
        failures.append("The deployment reports r_runtime false: /simulate cannot run.")
    if health.get("classifier_missing"):
        failures.append(
            "The deployment is missing classifier variants: "
            + ", ".join(health["classifier_missing"])
        )

    try:
        async with streamable_http_client(f"{base_url}/mcp") as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                listed = await session.list_tools()
                names = {tool.name for tool in listed.tools}

                if names != set(EXERCISE):
                    failures.append(
                        f"/mcp lists {sorted(names)}, expected {sorted(EXERCISE)}"
                    )

                for tool in listed.tools:
                    # An informative outputSchema, not merely a present one. A
                    # tool annotated `-> dict[str, Any]` declares
                    # `{"type": "object", "additionalProperties": true}`, which
                    # validates any object at all -- so a deployment serving a
                    # pre-#60 build passes a presence check and tells a client
                    # nothing. The two tools that serve prose are exempt: FastMCP
                    # wraps a `str` return, and that wrapper is honest.
                    schema = tool.outputSchema or {}
                    if list(schema.get("properties") or {}) == ["result"]:
                        continue
                    if not schema.get("properties") or schema.get("additionalProperties"):
                        failures.append(
                            f"{tool.name} declares no usable outputSchema: {schema}"
                        )

                for tool, arguments in EXERCISE.items():
                    if tool not in names:
                        continue
                    result = await session.call_tool(tool, arguments)
                    if result.isError:
                        failures.append(f"{tool} failed: {result.content}")
                    elif tool == "type_one_sample" and not (
                        result.structuredContent or {}
                    ).get("classified"):
                        # The one call that reaches a model. A tool that answers
                        # without classifying means the walk found no variant,
                        # which for a full measurement set means the deployment
                        # is serving a classifier it should not be.
                        failures.append(
                            f"type_one_sample did not classify a full measurement "
                            f"set: {result.structuredContent}"
                        )
                    elif tool == "type_lot_samples" and not _lot_truncated(
                        result.structuredContent or {}
                    ):
                        # The cap, checked where it matters. The call above sends
                        # more samples than the default, so a deployment that
                        # returns every prediction -- or that truncates the
                        # counts along with them -- fails here.
                        failures.append(
                            "type_lot_samples did not cap its predictions while "
                            f"counting every sample: {result.structuredContent}"
                        )
                    elif tool == "predict_customize" and not (
                        result.structuredContent or {}
                    ).get("scenario", {}).get("disruptions_applied"):
                        # The facility mapping's own evidence. The call above
                        # carries an extra leg, which reaches the API through the
                        # disruption door, so an empty record means the deployment
                        # dropped the leg and answered for the shipped chain.
                        failures.append(
                            "predict_customize applied no disruption for a call "
                            f"carrying an extra leg: {result.structuredContent}"
                        )
                    elif tool == "model_an_intervention" and not (
                        result.structuredContent or {}
                    ).get("scenario", {}).get("resolved_levels"):
                        # ADR 012's criterion, checked on the deployment. The call
                        # above names a lever rather than stating a level, so an
                        # empty record means the deployment reported the name and
                        # never said what number it stood for.
                        failures.append(
                            "model_an_intervention resolved a named lever to no "
                            f"published level: {result.structuredContent}"
                        )
                    elif tool == "model_a_disruption" and len(
                        (result.structuredContent or {})
                        .get("scenario", {})
                        .get("disruptions_applied", {})
                    ) != 2:
                        # The mixed scenario, checked on the deployment: an
                        # excursion on one stage and a delay on another have to
                        # arrive as two records from one call.
                        failures.append(
                            "model_a_disruption did not carry a two-stage mixed "
                            f"scenario through: {result.structuredContent}"
                        )
    except Exception as exc:  # noqa: BLE001 -- any failure here is a failed check
        failures.append(f"/mcp did not serve the handshake: {describe(exc)}")

    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--space", help="e.g. chenhaoq87/dairy-spoilage-api")
    parser.add_argument("--url", help="base URL, if not a Hugging Face Space")
    args = parser.parse_args()

    if not (args.space or args.url):
        parser.error("name a --space or a --url")

    if not (CONTEXT / "models" / "variants").is_dir():
        print("No build context to compare against. Run `bash dairy-api/build.sh` first.")
        return 1

    base_url = (args.url or space_url(args.space)).rstrip("/")
    print(f"Checking {base_url}")

    failures = asyncio.run(check(base_url))
    if args.space:
        failures += check_file_set(args.space)
    else:
        print("  (--url given, so the deployed file set is not compared)")
    if failures:
        print(f"\n{len(failures)} check(s) failed:\n")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print(
        f"Current: the deployment matches this checkout, and all "
        f"{len(EXERCISE)} tools answer."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
