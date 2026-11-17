#!/usr/bin/env python
"""Deploy dairy-api to a Hugging Face Docker Space.

Run from the repo root, after `bash dairy-api/build.sh`:

    pip install -r dairy-api/requirements-deploy.txt
    python dairy-api/deploy_space.py --space chenhaoq87/dairy-spoilage-api
    python dairy-api/deploy_space.py --space ... --dry-run   # list files, upload nothing

huggingface_hub is declared in requirements-deploy.txt, not requirements.txt:
the latter is installed into the Docker image, and this script never runs there.

Authentication comes from `hf auth login` or the HF_TOKEN environment variable.
The token is never read or printed by this script -- huggingface_hub resolves it.

What gets published: everything under dairy-api/ except the exclusions below,
plus the models/ and milk-spoilage-model/ trees that build.sh assembles there.
That includes the R model source and its input data. Read the printed manifest
before answering the confirmation prompt.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from huggingface_hub import HfApi

from build_info import BUILD_INFO_PATH
from payload import IGNORE, digest, manifest

# Without these the Space either fails to build or comes up degraded.
REQUIRED = [
    "README.md",
    "Dockerfile",
    "requirements.txt",
    "app.py",
    "guidance/routes/1-spoilage-typing.md",
    "guidance/reference/spoilage-classification-model.md",
    "models/config.json",
    "models/variants/variants_config.json",
    "milk-spoilage-model/run_model.R",
    "milk-spoilage-model/config.R",
    "milk-spoilage-model/input_data/scenario_s1_storage_cooling_disruption.csv",
]


def record_build_info(context: Path) -> dict:
    """Stamp the payload with its own digest, so /health can report what it is.

    Written before the upload and uploaded with everything else. The digest
    covers every published file except this one, which cannot identify itself.
    """
    try:
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=context,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        # A deploy from an exported tree still deploys. The digest identifies
        # the payload on its own; the commit is context for a human reading it.
        commit = None

    info = {
        "payload_digest": digest(context),
        "commit": commit,
        "deployed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    BUILD_INFO_PATH.write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    return info


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--space", required=True, help="e.g. chenhaoq87/dairy-spoilage-api")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    args = ap.parse_args()

    ctx = Path(__file__).resolve().parent

    missing = [p for p in REQUIRED if not (ctx / p).exists()]
    if missing:
        print("Build context is incomplete. Run `bash dairy-api/build.sh` first.")
        for m in missing:
            print(f"  missing: {m}")
        return 1

    # Every variant the config declares must have its artifact. Checking that
    # variants_config.json merely exists is not enough: a partial copy leaves the
    # config listing ten variants beside fewer joblibs, and nothing downstream
    # objects. ClassifierService only warns for a model it cannot load, and
    # /health derives "healthy" from the R runtime, so a Space missing half its
    # classifier reports healthy and fails one variant at a time in use.
    #
    # Read the expected set from the config rather than hardcoding ten, so a
    # retrained variant set still validates.
    cfg_path = ctx / "models" / "variants" / "variants_config.json"
    declared = sorted(json.loads(cfg_path.read_text(encoding="utf-8")).get("variants", {}))
    absent = [v for v in declared if not (ctx / "models" / "variants" / f"{v}.joblib").exists()]
    if not declared:
        print(f"{cfg_path.name} declares no variants; refusing to upload a classifier-less Space.")
        return 1
    if absent:
        print(f"Classifier payload is incomplete: {len(declared) - len(absent)}/{len(declared)}"
              " variants present. Re-run `bash dairy-api/build.sh`.")
        for v in absent:
            print(f"  missing: models/variants/{v}.joblib")
        return 1

    api = HfApi()
    who = api.whoami()
    print(f"Authenticated as {who['name']} (token role: "
          f"{who.get('auth', {}).get('accessToken', {}).get('role')})")

    # Enumerate exactly what upload_folder will publish, applying IGNORE the same
    # way. Counting every file under ctx instead described a different set from
    # the one being uploaded, so a --dry-run audit of a *public* deployment could
    # not reveal an unexpected file, which is the only thing a dry run is for.
    published = manifest(ctx)
    excluded = sum(1 for p in ctx.rglob("*") if p.is_file()) - len(published)

    variants = sorted((ctx / "models" / "variants").glob("*.joblib"))
    total = sum(p.stat().st_size for p, _ in published)
    print(f"\nSpace:      {args.space}  (public)")
    print(f"Classifier: {len(variants)} variants")
    print(f"Payload:    {len(published)} files, ~{total / 1e6:.1f} MB "
          f"({excluded} excluded by IGNORE)")
    print(f"Digest:     {digest(ctx)}")
    print("\nThis publishes the R model source and its input data, including the")
    print("container pool CSVs, to a public repository.")

    if args.dry_run:
        print("\nFiles that would be published:")
        for _, rel in published:
            print(f"  {rel}")
        print("\n--dry-run: nothing uploaded.")
        return 0

    if not args.yes:
        if input("\nType 'publish' to continue: ").strip() != "publish":
            print("Aborted.")
            return 1

    info = record_build_info(ctx)
    print(f"\nStamped build_info.json: {info['payload_digest'][:12]} "
          f"at {info['deployed_at']}")

    # Only create when the Space is absent. Hugging Face gates the create
    # endpoint for Docker Spaces behind PRO -- it returns 402 even with
    # exist_ok=True, because the request reaches the gate before the existence
    # check. Writing to a Space that already exists is not gated, so an existing
    # Space is deployed to directly.
    if api.repo_exists(repo_id=args.space, repo_type="space"):
        print(f"Space exists, deploying into it: {args.space}")
    else:
        try:
            api.create_repo(
                repo_id=args.space,
                repo_type="space",
                space_sdk="docker",
                private=False,
            )
            print(f"Space created: {args.space}")
        except Exception as e:
            if "402" in str(e):
                print("\nERROR: creating a new Docker Space requires Hugging Face PRO.")
                print("Deploy into a Space you already own, or rename one to this id:")
                print("  HfApi().move_repo(from_id=..., to_id=..., repo_type='space')")
                print("A renamed Space keeps its free tier and still builds.")
                return 1
            raise

    api.upload_folder(
        repo_id=args.space,
        repo_type="space",
        folder_path=str(ctx),
        ignore_patterns=IGNORE,
        # Mirror the manifest rather than merely adding to it. Without this,
        # upload_folder only adds and overwrites, so a file that disappears
        # locally lives on in the Space -- and build_info.json's digest is
        # computed from the local manifest, so /health reports the expected
        # value over a deployment carrying files the repository dropped.
        # Measured: this Space carried fastapi_app.py and model.joblib from an
        # earlier incarnation through three deploys, and the check passed.
        #
        # Safe against the obvious fear of deleting the upload itself: the Hub
        # computes deletions from the remote listing, drops any path that is
        # also being added, and never deletes .gitattributes.
        delete_patterns="*",
        commit_message="Deploy dairy-api: classification and simulation endpoints",
    )

    print(f"\nPushed. The Space now builds the Dockerfile, which compiles the R")
    print(f"packages from source -- expect a long first build.")
    print(f"  https://huggingface.co/spaces/{args.space}")
    print(f"\nWhen it is running, confirm the deployment matches this checkout:")
    print(f"  python dairy-api/check_deployment.py --space {args.space}")
    print("It checks the payload digest, the MCP handshake and the R runtime.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
