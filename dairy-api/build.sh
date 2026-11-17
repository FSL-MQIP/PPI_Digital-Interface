#!/bin/bash
# Build script: copies model artifacts into dairy-api/ for Docker build context.
# Run from repo root: bash dairy-api/build.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Preparing build context..."

# Copy ML model artifacts.
#
# The classifier is NOT part of this repository -- it is a separate public
# Hugging Face model repo, cloned here during development. A clean checkout has
# no MilkSpoilageClassifier/ at all, so prefer the local clone when it is there
# and fall back to the Hub when it is not. Without the fallback this script
# fails on a CI runner, a Space build, or any new machine.
rm -rf "$SCRIPT_DIR/models"
mkdir -p "$SCRIPT_DIR/models/variants"

LOCAL_CLASSIFIER="$REPO_ROOT/MilkSpoilageClassifier/model"
HF_MODEL_ID="food-ai-nexus/pasteurized-milk-spoilage-classifier"

# Pinned to a commit, never to a branch. `main` is a moving pointer: this model
# repo has advanced 15 commits already, and the ten variants only landed at the
# fourteenth -- so the same script against `main` would have fetched 0, 1 or 12
# model files depending on the day it ran. A retrain upstream would hand a clean
# build joblibs pickled by a newer scikit-learn than requirements.txt installs,
# silently, because unpickling across versions only warns.
#
# THIS SHA AND THE scikit-learn PIN IN requirements.txt MOVE TOGETHER. These
# artifacts were pickled by scikit-learn 1.8.0. Repointing this at retrained
# artifacts means repinning scikit-learn to whatever pickled them, and vice
# versa. verify_build_context.sh compares the two and fails if they disagree.
HF_MODEL_REVISION="c14e93c23b19d6d776b3a22e8d39134cb7db9596"

# The local clone is a shortcut, never an exemption from the pin. It is an
# untracked checkout of the same Hugging Face repo, so it can sit at a different
# revision, or carry uncommitted edits, and copying from it blindly would deploy
# artifacts that never went through HF_MODEL_REVISION at all. verify_build_context.sh
# cannot catch that: it excludes untracked directories by design, which is exactly
# what makes this path invisible to it.
#
# So use the clone only when it demonstrably *is* the pinned revision, clean.
# Otherwise fall through and download, which is slower and correct.
USE_LOCAL=0
if [ -d "$LOCAL_CLASSIFIER/variants" ]; then
    clone_head=$(git -C "$REPO_ROOT/MilkSpoilageClassifier" rev-parse HEAD 2>/dev/null || true)
    clone_dirty=$(git -C "$REPO_ROOT/MilkSpoilageClassifier" status --porcelain -- model/ 2>/dev/null || true)
    # Git says nothing about whether an LFS file was actually fetched. The model
    # repo tracks *.joblib through LFS, so a clone made without git-lfs, or with
    # GIT_LFS_SKIP_SMUDGE=1, leaves ~130-byte pointer files while rev-parse and
    # status --porcelain both report the pinned revision, clean. Copying those
    # produces an image that builds and then dies inside joblib.load().
    # Piped into grep rather than captured: a real joblib is binary, and command
    # substitution on it warns about ignored null bytes on every file.
    clone_pointers=""
    for jb in "$LOCAL_CLASSIFIER/variants/"*.joblib; do
        [ -e "$jb" ] || continue
        if head -c 40 "$jb" 2>/dev/null | grep -q '^version https://git-lfs'; then
            clone_pointers="yes"
            break
        fi
    done

    if [ "$clone_head" = "$HF_MODEL_REVISION" ] && [ -z "$clone_dirty" ] && [ -z "$clone_pointers" ]; then
        USE_LOCAL=1
    elif [ -n "$clone_pointers" ]; then
        echo "  local clone has unsmudged LFS pointers instead of artifacts -- downloading instead"
    elif [ -z "$clone_head" ]; then
        echo "  local clone is not a git checkout -- cannot prove its revision, downloading instead"
    elif [ "$clone_head" != "$HF_MODEL_REVISION" ]; then
        echo "  local clone is at $clone_head, not the pinned $HF_MODEL_REVISION -- downloading instead"
    else
        echo "  local clone has uncommitted changes under model/ -- downloading instead"
    fi
fi

if [ "$USE_LOCAL" = "1" ]; then
    echo "  classifier: local clone, verified at $HF_MODEL_REVISION"
    cp "$LOCAL_CLASSIFIER/variants/"*.joblib "$SCRIPT_DIR/models/variants/"
    cp "$LOCAL_CLASSIFIER/variants/variants_config.json" "$SCRIPT_DIR/models/variants/"
    cp "$LOCAL_CLASSIFIER/config.json" "$SCRIPT_DIR/models/"
else
    echo "  classifier: downloading from https://huggingface.co/$HF_MODEL_ID"
    echo "  revision:   $HF_MODEL_REVISION"

    # Find an interpreter that actually runs. Being on PATH is not enough at
    # either end: a clean Ubuntu host has python3 and no python, while Windows
    # ships a python3 App Execution Alias that is a Microsoft Store stub -- it
    # resolves through `command -v` and then exits 49 without running anything.
    # So try each candidate and keep the first that executes.
    PYTHON=""
    for cand in python3 python; do
        if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "pass" >/dev/null 2>&1; then
            PYTHON="$cand"
            break
        fi
    done
    [ -n "$PYTHON" ] || { echo "ERROR: no working python found, needed to read the Hub listing"; exit 1; }

    # The repo is public, so no token. Ask the Hub which files exist at the
    # pinned revision rather than hardcoding the variant list, so a repin to
    # retrained variants still works without editing the file list here.
    #
    # Both the listing and the downloads below name the revision. Pinning only
    # one leaves a window: a push landing between the two calls would list one
    # revision's files and fetch another's.
    #
    # Fetch and parse in separate steps. As one pipeline the exit status came
    # from the final command, so a failed curl was reported as "listed no model
    # files" while the real network or authorization error went unmentioned.
    listing=$(curl -fsSL "https://huggingface.co/api/models/$HF_MODEL_ID/revision/$HF_MODEL_REVISION") \
        || { echo "ERROR: could not reach the Hub for $HF_MODEL_ID at $HF_MODEL_REVISION"; exit 1; }

    files=$(printf '%s' "$listing" | "$PYTHON" -c "
import json, sys
d = json.loads(sys.stdin.read(), strict=False)
for s in d.get('siblings', []):
    f = s['rfilename']
    if f == 'model/config.json' or f.startswith('model/variants/'):
        print(f)
") || { echo "ERROR: could not parse the Hub listing for $HF_MODEL_ID"; exit 1; }

    # Strip the CR that Python's text-mode stdout adds on Windows; left in, it
    # lands inside the download URL and curl rejects it.
    files=$(printf '%s' "$files" | tr -d '\r')

    [ -n "$files" ] || { echo "ERROR: $HF_MODEL_ID listed no model files"; exit 1; }

    for f in $files; do
        dest="$SCRIPT_DIR/models/${f#model/}"
        mkdir -p "$(dirname "$dest")"
        curl -fsSL "https://huggingface.co/$HF_MODEL_ID/resolve/$HF_MODEL_REVISION/$f" -o "$dest" \
            || { echo "ERROR: failed to download $f at $HF_MODEL_REVISION"; exit 1; }
    done
fi

# Reset the build stamp. deploy_space.py overwrites this with the digest of the
# payload it uploads; a local build gets nulls, which is the honest answer for a
# checkout that is not a deployment. Written unconditionally so the Dockerfile
# can COPY it without a wildcard, and so a stamp left over from an earlier deploy
# never travels into an image it does not describe.
cat > "$SCRIPT_DIR/build_info.json" <<'JSON'
{
  "payload_digest": null,
  "commit": null,
  "deployed_at": null
}
JSON

# Copy the guidance read_guidance serves. Two source trees in the repository --
# the plugin's route files and the reference documents -- become one directory in
# the image, so the tool resolves a single path there and the checkout paths only
# on a development machine.
rm -rf "$SCRIPT_DIR/guidance"
mkdir -p "$SCRIPT_DIR/guidance"
cp -r "$REPO_ROOT/plugin/skills/milk-spoilage/routes" "$SCRIPT_DIR/guidance/routes"
cp -r "$REPO_ROOT/docs/reference" "$SCRIPT_DIR/guidance/reference"

# Copy R model code
rm -rf "$SCRIPT_DIR/milk-spoilage-model"
mkdir -p "$SCRIPT_DIR/milk-spoilage-model"
cp -r "$REPO_ROOT/milk-spoilage-model/config.R" "$SCRIPT_DIR/milk-spoilage-model/"
cp -r "$REPO_ROOT/milk-spoilage-model/run_model.R" "$SCRIPT_DIR/milk-spoilage-model/"
cp -r "$REPO_ROOT/milk-spoilage-model/pathways" "$SCRIPT_DIR/milk-spoilage-model/"
cp -r "$REPO_ROOT/milk-spoilage-model/scenarios" "$SCRIPT_DIR/milk-spoilage-model/"
cp -r "$REPO_ROOT/milk-spoilage-model/utils" "$SCRIPT_DIR/milk-spoilage-model/"
cp -r "$REPO_ROOT/milk-spoilage-model/input_data" "$SCRIPT_DIR/milk-spoilage-model/"

# The S1-S4 disruption profiles used to be copied here from
# PPI_Digital-Interface/, which is gitignored -- under `|| true`, so a clean
# checkout produced a context missing them and said nothing, and every S1-S4
# preset in r_bridge/run_simulation.R then failed at runtime. They now live in
# milk-spoilage-model/input_data/ and arrive with the copy above.

echo "Build context ready. Run:"
echo "  cd dairy-api && docker build -t dairy-api ."
