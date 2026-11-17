---
title: Dairy Spoilage API
emoji: 🥛
colorFrom: blue
colorTo: green
sdk: docker
app_port: 7860
pinned: false
---

# Dairy Spoilage API

Milk spoilage classification and fluid-milk supply-chain simulation behind one
HTTP surface, shaped for consumption by LLM agents rather than by a browser.

It also hosts the `milk-spoilage` MCP server at `/mcp`, co-hosted here rather
than as a second service because a Docker Space routes one port (ADR 016). The
front matter above makes this directory a Hugging Face Docker Space, and
`app_port` must stay equal to the `PORT` default in the Dockerfile.

**Deploy into the Space that already exists.** Hugging Face gates *creating* a
Docker Space behind PRO, and that gate already cost this project a Space once.

## Endpoints

| Endpoint | Method | What it does |
|---|---|---|
| `/classify` | POST | Label one sample PPC, no spoilage, or spore spoilage |
| `/classify/batch` | POST | The same over many samples |
| `/variants` | GET | The 10 classifier variants and the measurements each needs |
| `/simulate` | POST | Monte Carlo simulation over five supply-chain stages |
| `/scenarios` | GET | The intervention and disruption parameter surface |
| `/simulate/methods` | GET | Shelf-life value and CO2e method notes |
| `/health` | GET | Liveness, whether the R runtime answers, and which build is deployed |
| `/mcp` | POST/GET | The MCP server, streamable HTTP, no authentication |

`/classify` returns in milliseconds. **`/simulate` takes 30-60 seconds**, so any
client needs a timeout set well above its default.

`/mcp` answers at that exact path, with no trailing slash and no redirect --
it is the URL the plugin's `.mcp.json` carries.

## Running it

Locally, without Docker, from the repository root:

```bash
bash dairy-api/build.sh
cd dairy-api && uvicorn app:app --reload
```

`build.sh` comes first here too, not only for Docker. The classifier artifacts
are not in this repository, so on a clean checkout there is nothing for the API
to load until `build.sh` fetches them, and `uvicorn` fails at import.

The MCP tools reach the API over loopback, at `127.0.0.1:$PORT` with `PORT`
defaulting to 7860 as the Dockerfile sets it. On a local run that binds
something else, tell them where the API is:

```bash
DAIRY_API_BASE_URL=http://127.0.0.1:8000 uvicorn app:app --port 8000
```

As a container, from the repository root:

```bash
bash dairy-api/build.sh && docker build -t dairy-api dairy-api/ && docker run -p 8000:7860 dairy-api
```

`build.sh` runs first because the Dockerfile copies `models/` and
`milk-spoilage-model/` from its own build context, and those are assembled from
elsewhere rather than committed here. The classifier artifacts are not in this
repository at all -- they come from the public Hugging Face model repo
`food-ai-nexus/pasteurized-milk-spoilage-classifier`, and `build.sh` downloads
them when no local clone is present.

To check that the context is complete from a clean checkout, which is what a
hosted build or a CI runner starts from:

```bash
bash dairy-api/verify_build_context.sh
```

## Checking that it came up

```bash
curl -s http://localhost:8000/health
```

A healthy response reports `"r_runtime": true`, and
`"classifier_models_loaded"` equal to `"classifier_models_declared"` with
`"classifier_missing": []`.

`"status"` is `healthy` only when both halves are sound. `"r_runtime": false`
means the image built but the R side did not -- that flag verifies all thirteen R
packages resolve, so a false there names a real missing package rather than a
dead runtime. A non-empty `"classifier_missing"` names variants that
`variants_config.json` declares and the service could not load; it warns and
carries on, so without this field the omission appears only in the container log.

`"classifier_default_loaded": false` means the config never declared the variant
every endpoint falls back to (`"classifier_default_variant"`, currently
`baseline`). That state is internally consistent -- declared equals loaded and
nothing is missing -- while `/classify` and `/classify/batch` return 400 for
every request that names no variant. Consistency is not usability, so it counts
as degraded.

Read the comparison, not the count. `"classifier_models_loaded": 10` proves
nothing on its own -- a service declaring 2 and loading 2 also reports a number.

`"build"` carries the deployment's identity: the digest of the payload uploaded
to it, the commit it was deployed from, and when. A local run reports nulls,
because a checkout is not a deployment. **`"status"` does not read it** -- a Space
running last month's code is running perfectly well, and only a caller holding
the repository can tell that it is stale:

```bash
python dairy-api/check_deployment.py --space chenhaoq87/dairy-spoilage-api
```

That exits non-zero when the digest disagrees, when the MCP handshake fails, or
when a tool does not answer. Run it after every deploy. Issues #38 and #42 were
both a Space running something older than the repository, and under ADR 016 that
lag breaks tool calls rather than only documentation.

Do not read a successful `docker build` as a working image. The build once
completed while `lamW` was missing, because `install.packages()` reports a
failure as a warning and `R -e` still exits 0. The Dockerfile now checks
explicitly and fails the build instead.

## Versions

`scikit-learn` and `mcp` are both pinned exactly, and `verify_build_context.sh`
fails a bound that is not `==`.

The classifier artifacts were pickled by scikit-learn 1.8.0, and a different
version loads them with a warning and no guarantee.

`mcp` is pinned because `mcp>=1.26` resolved to 2.0.0 on a clean install, and
2.0 removed `mcp.server.fastmcp`. The image built, shipped, and died at import,
while every test passed on a machine already holding 1.26.0. pip re-resolves
only on a fresh install, so **a green test suite here is not evidence that the
image works**. Build the image before deploying. See the notes in
`requirements.txt`.
