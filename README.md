# Milk Spoilage Model

A modular, script-based model for predicting fluid milk spoilage across the supply chain. Combines post-pasteurization contamination (PPC) bacteria modeling with two populated bacterial growth pathways (medium-growth, high-growth; a no-growth pathway exists but the current data never activates it) to estimate shelf life.

## The plugin ships from its own public repository

This is the **private working repository**. The artifact this project ships — the `milk-spoilage`
skill plus one remote MCP server — is published to
[chenhaoq87/milk-spoilage](https://github.com/chenhaoq87/milk-spoilage), which is
the repo users install from:

```
/plugin marketplace add chenhaoq87/milk-spoilage
/plugin install milk-spoilage@chenhaoq87
```

The plugin sources here (`plugin/`, `.claude-plugin/marketplace.json`, `LICENSE`, and the public
README at `docs/plugin-repo/README.md`) are the originals; publishing is a deliberate act:

```bash
python scripts/publish_plugin.py
```

It prints the exact manifest before pushing — the same pattern `deploy_space.py` uses for the
Space. Nothing outside that manifest ever reaches the public repo.

## Quick Start

```bash
cd milk-spoilage-model
Rscript run_model.R
```

Output is written to `milk-spoilage-model/output/`:
- `spoilage_summary.csv` -- per-lot spoilage statistics at days 7, 14, 21, 28, 35
- `container_results.csv` -- daily concentrations per container per pathway

### Programmatic Use

`run_model.R` can also be `source()`'d to access the `run_model()` function directly:

```r
source("run_model.R")
result <- run_model()                         # default config
result <- run_model(user_config = my_config)  # custom config

# With interventions and disruptions
result <- run_model(
  interventions = list(
    spore_reduction = "microfiltration",
    ppc_initial_reduction_log = 1
  ),
  disruptions = list(
    processing_facility = list(type = "temp_spike", temp = 25, duration = 0.125)
  )
)

result$spoilage_summary     # per-day spoilage statistics
result$shelf_life           # total + consumer shelf life (days to 25% lot spoilage)
result$warnings             # conflict warnings (if any)
result$scenario             # applied interventions/disruptions metadata
```

## Architecture

```
milk-spoilage-model/
├── run_model.R                        # Orchestrator (exports run_model() function)
├── config.R                           # Parameters & defaults
├── pathways/
│   ├── ppc_pathway.R                  # Gram-negative PPC (Baranyi ODE)
│   ├── nogrowth_pathway.R             # No-growth bacteria (constant)
│   ├── medium_growth_pathway.R        # BCLc bacteria (Buchanan model)
│   └── high_growth_pathway.R          # High-growth bacteria (Baranyi ODE)
├── scenarios/
│   ├── interventions.R                # Intervention system (spore, PPC, temp overrides)
│   ├── disruptions.R                  # Disruption system (temp_spike, delay, profile_csv, temp_shift)
│   └── resolve.R                      # Pipeline orchestrator + conflict detection
├── utils/
│   ├── growth_models.R                # Shared growth equations
│   └── temperature.R                  # Temperature profile construction
├── input_data/                        # Growth params, container pools, temp profiles
└── output/                            # Simulation results
```

## Model Overview

Each simulation creates `n_lots` lots of `n_units` containers. Per lot:

1. A PPC frequency is sampled (default 40-62.5%)
2. Each container is assigned as **PPC** or **non-PPC**
3. **PPC containers**: initial contamination + growth parameters generated at runtime, Baranyi ODE growth with reduced Ratkowsky temperature dependence
4. **Non-PPC containers**: each is assigned one source container from the pre-generated pools and inherits its **whole bacterial community** — every genus row it carries, across both pools (2.53 genera on average; 67.9% of source containers span both). Each genus row runs through the pathway matching its source pool, medium-growth (Buchanan) or high-growth (Baranyi ODE), and the contributions are summed per container per day.
5. Spoilage = total concentration > 6 log10 CFU/mL

The no-growth pathway is implemented but inert: the pools carry no rows meeting its
criteria, and neither do the legacy originals. It populates only under user APC
input, which this port does not expose. **Two populated growth pathways, not three.**

## Supply Chain Stages

| Stage | Mode | Default Temp | Default Duration |
|-------|------|-------------|-----------------|
| Processing Facility | dynamic | 1.7 C | 2.43 days |
| Transport to Retail | dynamic | 4.5 C | 0.33 days |
| Retail Storage | dynamic | 6.5 C | 5.46 days |
| Transport to Home | static | 8.5 C | 0.04 days |
| Consumer Home | dynamic | 6.5 C | 27.96 days |

Pre-consumer window: **8.255 days**.

Four of the five stages are dynamic and take their temperature *and their span* from
the baseline profile CSVs; `config.R`'s `duration` applies only to the static stage.
The facility default previously read `2.4264 / 24` and was documented as 2.4 hours,
an hours/days error — its profile spans 2026-02-11 21:44:58 to 2026-02-14 07:58:58,
which is 2.4264 **days**. The profile always drove the simulation, so only the
reported shelf life was affected; baseline consumer shelf life is 2.7 days, not the
5.1 previously reported. See `docs/research/2026-08-06-port-audit.md` (D7).

Retail and consumer both sit at 6.5 C, so moving days between them changes no growth
rate — worth knowing when designing a scenario around retail duration.

## Interventions

The intervention system (`scenarios/interventions.R`) supports three categories of modifications that can be combined via `apply_interventions()`:

- **Category A -- Spore Reduction**: Presets for microfiltration (2.2 log), low-efficiency microfiltration (0.6 log), single bactofugation (1.4 log), and double bactofugation (2.0 log). Each reduces the initial load of the spore-forming genera only (`Bacillus`, `Paenibacillus`); the model has no spore *state*, so this is a shift in starting concentration, not a removal of spores as such. Every value is published -- see [`docs/reference/spore-removal-log-reductions.md`](docs/reference/spore-removal-log-reductions.md) -- and all are estimates that a processor's own measured reduction should override. The benefit is conditional: it appears in a long shelf-life plant and is invisible in a medium or short one, where PPC ends shelf life first (ADR 012).
- **Category B -- PPC Controls**: Adjust PPC contamination frequency, reduce initial PPC concentration, or remove specific sequence types from the ST frequency table.
- **Category C -- Stage Temperature Overrides**: Per-stage overrides for temperature delta, mean/sd replacement, max clamping, and duration changes -- applied to both static config and dynamic profiles.

## Disruptions

The disruption system (`scenarios/disruptions.R`) models adverse supply chain events:

| Type | What it does | Parameters |
|------|-------------|------------|
| `temp_shift` | Entire stage runs warmer/cooler | `temp_delta` |
| `temp_spike` | Temp jumps for a period, then returns | `temp`, `duration` |
| `delay` | Stage takes longer at a specified temp | `duration_delta`, `temp` |
| `profile_csv` | Replace stage with a recorded disruption profile | `path` |

Disruptions are keyed by stage name, so one stage carries at most one disruption. When an intervention and a disruption target the same stage, a conflict warning is emitted in `result$warnings`, naming whether the run **composed** the two (`temp_spike`, `delay`, `temp_shift`) or **replaced** the intervention's temperature series (`profile_csv`).

## Configuration

Edit `config.R` to change simulation parameters:
- `n_lots` / `n_units` -- simulation size (default: 10 lots, 100 units)
- `P_ppc_min` / `P_ppc_max` -- PPC frequency range
- `sim_duration` -- total days (default: 40)
- `spoilage_threshold` -- log10 CFU/mL (default: 6.0)
- `temperature_stages` -- per-stage temperature mode (`"dynamic"` or `"static"`), CSV paths, and mean/sd fallbacks

## Dependencies

R 4.4+ with packages: `dplyr`, `tidyr`, `tibble`, `purrr`, `deSolve`, `lamW`, `formula.tools`, `truncnorm`, `furrr`, `future`

## Verification

Baseline distributions are stored in `verification/`. Run comparison:

```bash
Rscript verification/compare_distributions.R
```

Each pathway reproduces its source model's distribution exactly **when run in isolation at the
baseline temperature profile**. That is the scope of the claim: this script applies a baseline
temperature override to the pools that `run_model()` does not apply, so it verifies the growth
mathematics and not the model end to end. See `docs/research/2026-08-06-port-audit.md` (V0).

Structural verification of container assembly and pathway routing:

```bash
Rscript verification/verify_structure.R
```

This asserts the invariants `compare_distributions.R` cannot see, at three seams:

1. **the pool CSVs and profile CSVs at load** — container composition, cross-pool additivity,
   timestamp resolution
2. **`run_model()`'s returned `container_results`** — pathway coverage across lots, per-pathway
   scenario reach, growth to the simulation horizon
3. **scenario resolution** — the two halves of the model must agree on the **growth** a scenario
   implies. The Buchanan pathway splits its history at stage boundaries read off the container row
   while the ODE pathways integrate one spliced time/temperature series, and every scenario-reach
   defect found in this work was one disagreement between them. This checks the whole control ×
   stage-mode matrix at once rather than one control at a time, and needs no simulation, so it runs
   in seconds.

   Growth space, not temperature space. `muAtNewTemp()` squares `(T - T0)`, so two thermal histories
   can share a mean temperature while implying different growth. Compared on mean temperature this
   matrix agreed to 0.0001 °C on every row while the Buchanan pathway was losing 47% of the growth in
   a 25 °C spike.

   Stage **totals**, so it is blind to the shape inside a stage. That is what
   `test_buchanan_trajectory.R` below is for.

All 59 checks pass. S2.14 covers the other direction of `duration_delta` (issue #51): a delta that
takes a stage to zero or below is refused in either mode, and a shortening that stays positive still
runs. It is asserted through `run_model()` because that is the path the API drives — the guard was
first written only into `test_interventions.R`, which this gate does not run, so deleting the fix
failed nothing.

S2.15 covers the same sign error one layer down, on the disruption side (issue #52). The two checks
do not overlap: S2.14 fires on the resulting stage **duration**, S2.15 on the **sign** of an appended
segment, so a `duration_delta` of `-1e-9` on `consumer` walks past S2.14 with its full 27.9583 d
untouched and still stored the profile out of order. Mutation-tested — with the guard deleted, S2.15
is the only one of the 59 that fails, which also measures how invisible the defect was to the other 58.

It also pins the row **order** for a positive duration, which the sign check alone does not deliver.
The offset placing an appended segment's opening row was a flat 1e-5 d, so any `0 < duration < 1e-5`
put the closing row first and rebuilt the same malformed profile from a value the guard accepts. That
one moves no prediction — the swapped rows carry the same temperature by construction, so both
integrators read one 0.04001 d stage and agree to `0.000e+00` — so the check asserts the order
directly instead of looking for a divergence there is none of.

Bounding the offset is not sufficient by itself, because the addition absorbs the result: against a
stage starting at 0.04, a duration of `1e-17` lands both rows on the same double and `1e-18`
collapses both onto the start, which emits the duplicate timestamp `approxfun()` averages. The guard
therefore tests the two timestamps it computed rather than the magnitude that produced them — the
only form that stays correct as a stage's start grows through a long run — and S2.15 asserts
`is.unsorted(..., strictly = TRUE)`, since the plain form reports a tie as sorted.

The `S1.5.*` group covers what a profile's own rows mean (issue #21). It measures
both integrators against an oracle written straight from the CSV, never against each other: they both
read the profile after `normalise_profile()` has touched it, so comparing them passes whenever they
agree on the same wrong series. Mutation-tested — dropping a tied row, averaging it, nudging backward,
and leaving the nudge uncapped are all invisible to an agreement check and all caught here. Five cases:
a mid-profile tie, a tie at the profile's end, a profile sampled every second, an out-of-order CSV, and
the same-temperature tie `resize_profile()` makes, which must stay harmless.

S1.4 pins the two-pathway precondition rather than demanding three: the shipped
pools carry no `Growth_category == "A"` rows and no zero-cell containers, and neither do PPI's
originals, so the no-growth pathway is correctly inert. It populates only under user APC input, which
this port does not expose. If a future data drop makes it live, S1.4 fires — and the paper's
two-pathway claim needs revisiting. See `docs/research/2026-08-06-port-audit.md`.

Trajectory verification of the Buchanan pathway:

```bash
Rscript verification/test_buchanan_trajectory.R
```

The medium-growth pathway must equal the integral of its own growth rate over the real thermal
history at **every** day, not only over a whole stage. Ten profile shapes × 8 seeds, plus four
scenarios resolved the way a user reaches the model, × 3 containers — checked against a dense
quadrature of the same spliced series the ODE pathways integrate.

This is a separate suite because neither of the others can see it. `compare_distributions.R` runs
every stage isothermal, where the question does not arise. Seam 3 compares stage totals — and the
retired evaluation collapsed a stage to the one temperature reproducing that total, so it preserved
the total by derivation while destroying the trajectory inside the stage. Measured over 7 shapes ×
4 seeds × 3 containers, the day-40 endpoint agreed to 0.0000 log10 while a reported day was out by
4.98 and 7.1% of spoilage calls flipped. See `docs/adr/007-buchanan-integrated-exactly.md`.

To regenerate the combined-model regression baseline after a verified behaviour change:

```bash
Rscript verification/generate_model_baseline.R
```

That reference is a self-regression — it comes from `run_model()` itself, so it detects change rather
than correctness. Verify behaviour with `verify_structure.R` and `compare_distributions.R` first;
regenerating to clear a red check just re-pins whatever the model now does.

The S2.4 checks measure **per-pathway scenario reach**: a temperature disruption must move each
pathway's own median, not merely the aggregate. Asserting the aggregate hides a pathway that ignores
scenarios entirely, which is how D6 survived.

`verification/verify_scenarios.R` reports 41 passed, 0 failed.

Scenario-level regression tests are in `verification/test_run_model_function.R`, with baselines in `verification/scenario_baselines/`.

The plugin's tool surface has its own suite, the **skill harness** (issue #33):

```bash
python -m pytest dairy-api/skill_harness                        # pure half
python -m pytest dairy-api/skill_harness --skill-target local   # + live half
```

It executes every procedure in `plugin/skills/milk-spoilage/` against the tool
surface. Each check is bound to the route-file sentence it verifies, so a red run
names the document and the claim; the live half runs only against a named target
pinned to this checkout — in-process, or a URL whose `/health` payload digest
matches — and fails outright when the target is stale. See
`dairy-api/skill_harness/README.md`.

Full scenario integration verification (regression, direction, conflict detection, S1-S4 reproduction, metadata):

```bash
Rscript ../verification/verify_scenarios.R
```

## Dairy API

A unified FastAPI service at `dairy-api/` providing ML classification and supply chain simulation endpoints. Designed for LLM agent consumption.

```bash
bash dairy-api/build.sh     # fetches the classifier artifacts; required first
cd dairy-api
pip install -r requirements.txt
uvicorn app:app --reload
```

`build.sh` is not Docker-only. The classifier artifacts live in a separate
Hugging Face model repo, so a clean checkout has nothing for the API to load
and `uvicorn` fails at import until `build.sh` has run.

### All Endpoints

| Endpoint | Method | Runtime | Description |
|----------|--------|---------|-------------|
| `/classify` | POST | Python (~ms) | Single-sample 3-class prediction (PPC, no spoilage, spore spoilage) |
| `/classify/batch` | POST | Python (~ms) | Batch predictions + PPC prevalence summary |
| `/variants` | GET | Python (~ms) | List all 10 model variants sorted by accuracy |
| `/simulate` | POST | R (~30-60s) | Run spoilage simulation with interventions/disruptions |
| `/scenarios` | GET | Python (~ms) | List valid intervention/disruption options |
| `/simulate/methods` | GET | Python (~ms) | Economics calculation methodology and references |
| `/health` | GET | Both (~ms) | Check Python + R runtime status, and the deployed build identity |
| `/mcp` | POST/GET | Python (~ms) | The `milk-spoilage` MCP server, streamable HTTP (ADR 016) |

### Classification

Features in log10 CFU/mL (`spc_d7`, `spc_d14`, `spc_d21`, `tgn_d7`, `tgn_d14`, `tgn_d21`), each
bounded to `[0, 12]`. A raw plate count entered where its logarithm belongs — 4,700,000 for a sample
that is 6.67 — returns 422 naming the field, and the batch endpoint names the sample index too.
`classify_sample` computes `10 ** value`, so unbounded that mistake either raised `OverflowError` as
a 500 or, one order of magnitude down, returned a confident prediction on nonsense. Both the
endpoint and the MCP tools import the one bound from `services/classifier.py`.

`GET /variants` returns the ten variants sorted by `test_accuracy`, highest first. A caller walks that list from the top and takes the first variant whose every feature the lab has — what was measured decides `model_variant`, never preference. `baseline` needs all six. **An agent does not do this walk**: `type_one_sample` and `type_lot_samples` perform it inside the MCP server and take no model name, so the skill never mentions a variant id.

**Read every accuracy from that response.** No accuracy figure appears in this file, in the MCP server or in the skill, and `dairy-api/tests/test_no_written_accuracy.py` fails when one does. A number written into prose drifts away from the model that is actually serving, which is what [ADR 013](docs/adr/013-quote-the-accuracy-the-shipped-model-scores.md) exists to prevent — it had already drifted three times before that rule was written, and this line was a fourth.

### Simulation

`POST /simulate` accepts `config`, `interventions`, `disruptions`, and `seed`. Returns two spoilage series — `daily_spoilage`, one row per simulated day, and `spoilage_summary` at days 7, 14, 21, 28, 35 with the lot-to-lot spread — plus shelf life (total + consumer, and `pre_consumer_day`, the whole day the run evaluates retail exit on), economics (USD value + CO₂e), and a spoilage curve plot (base64 PNG).

### Docker Build

```bash
bash dairy-api/build.sh     # copies model artifacts into build context
cd dairy-api && docker build -t dairy-api .
docker run -p 8000:7860 dairy-api
```

The container listens on 7860, which is the port a Hugging Face Docker Space
expects; map it to whatever you like locally. `dairy-api/README.md` carries the
Space front matter and the deployment notes.

### Classifier → Simulation Pipeline

Over HTTP: `/classify/batch` → take `ppc_prevalence` → feed into `/simulate` as `config.P_ppc_min`/`P_ppc_max`.

Through the tools, the agent chains `type_lot_samples` → `facility.observed_ppc`, one proportion per lot, and the client turns the measured prevalence into the bounds — reporting which rule it applied in `scenario.ppc_frequency_source`. The chain still lives in the conversation, which is the thesis; only the arithmetic moved.

## Plugin

The artifact this project ships, at `plugin/`. Two components: a remote MCP server and the curated
skills. It is installed into an assistant the practitioner already runs, and that assistant does the
orchestrating (ADR 008).

```
plugin/
├── .claude-plugin/plugin.json           # Name, version, description
├── .mcp.json                            # One remote entry, pointing at the Space's /mcp
└── skills/milk-spoilage/
    ├── SKILL.md                         # Router -- triage table, sample questions, disclaimer, out-of-scope rule
    └── routes/
        ├── 0-general-information.md     # Reference-doc map, three thresholds, declining well
        ├── 1-spoilage-typing.md         # Variant selection, then classification
        ├── 2-shelf-life-prediction.md   # predict_default / predict_customize -- owns the call and the read for routes 3-5
        ├── 3-economics-and-environment.md   # Two runs, same seed; which fields compare between runs, and the truncation and comparability gates
        ├── 4-prevention-strategies.md   # Lau Table 4 levels, gated on plant category
        └── 5-disruption-scenarios.md    # Temperature abuse and delays, the one-change-per-stage refusal, the folding recipe
```

The skills carry the judgement a tool schema cannot: which classifier variant the available
measurements support, and which scenario answers a given question. One router read on every
question, plus six route files, one per intent (ADR 010, ADR 011).

There is no stdio server, no `.mcpb` and no npm package. The plugin declares one URL, and the server
runs co-hosted in the Space beside `dairy-api` ([ADR 016](docs/adr/016-the-plugin-declares-a-remote-mcp-server.md)),
so one deploy moves the tools and the API together.

**The route files name tools, never HTTP endpoints.** [ADR 015](docs/adr/015-the-tool-surface-is-intent-shaped.md) settles the MCP server on **nine tools named for what a processor says** rather than seven endpoint proxies, and [issue #40](https://github.com/chenhaoq87/milk-spoilage-dev/issues/40) rewrote every route file to match. Some passages disappeared rather than moved: the client absorbed route 5's segment integral and event ranking, and route 3's per-container rescale.

### The MCP server

At `dairy-api/mcp_server/`, mounted into the FastAPI app at `/mcp`. All nine tools ship
([#56](https://github.com/chenhaoq87/milk-spoilage-dev/issues/56),
[#57](https://github.com/chenhaoq87/milk-spoilage-dev/issues/57),
[#58](https://github.com/chenhaoq87/milk-spoilage-dev/issues/58)), so every one of the six intents
works end to end. `/scenarios` and `/health` get no tool deliberately — the first is redundant
once three simulation tools carry narrow schemas, and the second is operational.

| Tool | Reaches |
|---|---|
| `read_guidance(route \| document)` | Bundled route files and reference documents |
| `list_classifier_models()` | `/variants` |
| `type_one_sample(...)` | `/variants`, then `/classify` |
| `type_lot_samples(lot_id, samples, max_predictions?)` | `/variants`, then `/classify/batch` |
| `predict_default(run, plant_category?)` | `/simulate`, on the shipped cold chain |
| `predict_customize(facility, run)` | `/simulate`, on the processor's own |
| `model_an_intervention(run, intervention, facility?)` | `/simulate`, on a change for the better |
| `model_a_disruption(run, disruption, facility?)` | `/simulate`, on an adverse event |
| `explain_calculations()` | `/simulate/methods` |

`app.py`'s lifespan enters the MCP session manager. A mounted ASGI application's own lifespan never
runs, so without that every request to `/mcp` fails on the first call after a cold start.

`type_one_sample` and `type_lot_samples` walk `/variants` from the top and take the first variant
whose every feature the lab has, so no accuracy figure is written into the server at all — ADR 013's
rule enforced by procedure. When nothing fits they name the missing measurement instead of failing.

`mcp_server/classification.py` types what both return, so their `outputSchema` describes their
fields rather than merely declaring an object. A tool annotated `-> dict[str, Any]` does emit a
schema, so presence is not the bar: it emits `{"type": "object", "additionalProperties": true}`,
which validates anything. Both are flat models rather than a union of a classified and an
unclassified shape, because FastMCP buries a union under a `{"result": ...}` wrapper.

`type_lot_samples` classifies and counts **every** sample, and caps only the per-sample predictions
— `max_predictions`, default 10, raisable when a processor asks about individual samples. The
counts and `ppc_prevalence` always cover the whole lot, `predictions_note` says how many of how many
are shown, and each prediction carries its own `sample_index`, since a position in a shortened list
maps back to nothing.

#### `facility`, and the door it picks

The API splits a change by **direction** — colder or shorter is an `intervention`, warmer or longer a
`disruption`. A processor splits it by **purpose**: this is my plant, against this is a change I am
weighing. `mcp_server/facility.py` carries the whole of that mismatch, so `facility` describes a plant
in either direction and the client picks the door by sign. `shift`, `flat` and `cap` name what happens
to a stage's measured shape, which is what `temp_delta` against `temp_mean` against `temp_max` hides
behind key names; `shift` is the default and keeps the New York baseline's within-stage trace.

Three things it computes rather than passing through. A stage stated in absolute days becomes an
offset against `mcp_server/supply_chain.py`'s baseline table, which is copied from `config.R` and
guarded by `tests/test_supply_chain_matches_config.py`. An `extra_legs` `readings[]` series folds at
the **growth-equivalent** temperature by `stage_growth_integral()`'s own segment rule, never at the
arithmetic mean — a mean lost 26.3% of a stage's growth when measured here, in the direction that
overpredicts shelf life. And a stage needing two disruptions is **rejected**, because the API takes
one per stage and a silent overwrite would answer for a different cold chain.

One case needs **both** doors at once. No disruption type flattens a stage, so a `flat` *above*
baseline cannot reach the API through the disruption door alone: it becomes an intervention flattening
at the baseline's own level, which is no thermal improvement, plus a disruption carrying the whole
of the warming. The run then reports a stage flat at the stated level, and `disruptions_applied`
stays an honest record of a plant running warmer than the New York baseline.

#### Weighing a change against the baseline

`model_an_intervention` and `model_a_disruption` carry only their own kind of change, and both take
`facility` optionally beside it ([ADR 017](docs/adr/017-a-change-is-stated-against-the-call-s-own-chain.md)).

An intervention's `cool_stage` uses `by`, `to` and `cap` rather than `facility`'s `shift`, `flat` and
`cap`, because the two arrive in one call and `shift` would otherwise mean "from the shipped
baseline" in one and "from your plant" in the other. **`by` and `to` read against the chain that same
call describes**: `by: 2` on a facility stating retail at 4.0 is retail at 2.0, and on no facility at
all it is 4.5. A statement that would leave the stage warmer is rejected, naming `model_a_disruption`.

Every named lever resolves to a published level the response states in `scenario.resolved_levels`,
with the plant action and the publication behind it — ADR 012's rule that a name must hand back its
number. A level the processor measured is passed straight through and resolves to nothing, because it
hides nothing.

A disruption takes `thermal_events` and `delays` as separate parameters on one tool. The API
implements them identically; a processor distinguishes them, and so must the tool, because appending
a delay is **exact** while appending temperature abuse lengthens a hold that was happening anyway.
One tool rather than two, because a chiller tripping in one stage and the load then waiting for a
truck in another is one scenario, and two tools would make it two runs.

**A second event on one stage is rejected, not merged.** Growth squares the temperature displacement,
so a merge understates it every time — measured at 9 d shelf life and 0.0 consumer days encoded
faithfully against 10 d and 0.5 merged. The rejection hands back both events ranked by
`duration x (T - Tmin)^2` at **both** reference temperatures the model carries, -4.15 and -3.62, and
states the direction each metric then bounds. When the two orderings disagree it refuses to pick at
all, because the events then contribute so nearly equally that dropping either loses about half the
added growth.

#### The reshaped response

`mcp_server/response.py` types the whole response, so both prediction tools carry an `outputSchema`.
`total_days` and `consumer_days` come back as a number **or** as a bound object rather than a bare
`-1`, and the two bounds are different numbers — the horizon bounds one, the horizon less the
supply-chain window bounds the other. Economics returns per-container figures beside the totals,
because both raw figures scale with `n_units` while `n_lots` enters neither.
`pct_spoiled_at_retail` returns with the day it was evaluated on, and says when that day fell outside
the horizon so a placeholder zero is never read as clean product. The base64 plot is dropped.

The response also states **route 3's comparability verdict** — whether the scenario changed a duration
in one of the four pre-consumer stages — which is determinable from one run's own scenario, so the
agent stops deciding it.

### Deploying, and checking for drift

```bash
bash dairy-api/build.sh
docker build -t dairy-api dairy-api/
python dairy-api/deploy_space.py --space chenhaoq87/dairy-spoilage-api
python dairy-api/check_deployment.py --space chenhaoq87/dairy-spoilage-api
```

**Build the image before deploying.** The suite passing here is not evidence
that the image works: `mcp>=1.26` once resolved to 2.0.0 on the clean install
inside the image, 2.0 had moved `FastMCP` out of `mcp.server.fastmcp`, and the
container died at import while all 86 tests passed against the 1.26.0 already
on the machine. The scikit-learn pin is exact; `mcp` carries `>=1.26,<2`, which
is the upper bound the SDK's own migration guide prescribes until a package
migrates — and the bound, not exactness, is what closes that hazard
([ADR 018](docs/adr/018-the-server-stays-on-the-mcp-sdk-s-1-x-line.md)).
`verify_build_context.sh` fails any `mcp` requirement that could resolve to 2.x.

Deploy into the **existing** Space. Hugging Face gates *creating* a Docker Space behind PRO, and
that gate already cost this project a Space once.

`check_deployment.py` exits non-zero when the Space is running something older than this checkout.
It compares a digest of the published payload, which `deploy_space.py` stamps into `build_info.json`
and `/health` reports, then completes the MCP handshake and executes **every** tool in its `EXERCISE`
map. Issues #38 and #42 were both this lag, and under ADR 016 it breaks tool calls rather than only
documentation. A tool added to the server and not added to that map turns the check red on purpose:
the served list and the map have to be the same set. It also asserts every listed tool declares a
usable `outputSchema` rather than merely some object, and that a lot larger than the prediction cap
comes back truncated with its counts still complete.

**Point it at the local container before pointing it at the Space.** `--url http://127.0.0.1:PORT`
against the image you just built exercises every tool through the same path, and the only check that
cannot pass there is the payload digest — `deploy_space.py` is what stamps `build_info.json`. That
ordering catches a clean-install failure while the Space is still serving the previous build, which
matters because a bad MCP deploy takes the API down with it.

## Legacy Apps

- `Digital-dairy-platform/` -- original Shiny app (PPC + spore-former model)
- `PPI_Digital-Interface/` -- original Shiny app (A + BCLc + D pathways)

These will be removed once the combined model is finalized.

## Documentation

- [Architecture Decision Records](docs/adr/) -- key design decisions (ADR 001-016)
- [Reference Documents](docs/reference/) -- condensed primary sources behind every parameter the model reports, with a citation-verification table
- [Plugin](plugin/) -- the remote MCP entry and the curated skills: [the router](plugin/skills/milk-spoilage/SKILL.md) and its six route files
- [Demonstration material](docs/demonstration/) -- what the paper's Results section shows, and the working notes behind it:
  - [`facility.md`](docs/demonstration/facility.md) -- the one synthetic facility both artifacts share: the plant, the lot and what the shipped classifier returned for it, the two distribution-centre traces and their growth-equivalent temperatures
  - [`artifacts.md`](docs/demonstration/artifacts.md) -- the eight questions and the expected procedure for each, written against today's route files. The acceptance criterion for the convergence loop in issue #10
  - [`triage-figure.html`](docs/demonstration/triage-figure.html) -- the specification and the paper's candidate figure: question to intent to gate to parameter, with the tool expected at each node
  - [`traps.md`](docs/demonstration/traps.md) -- 26 places an agent hands a processor a wrong number, split by whether the figure or only the reading is wrong
  - [`parameter-inventory.md`](docs/demonstration/parameter-inventory.md) -- everything a processor can state, its default, and where the default comes from
  - [`gate-inventory.md`](docs/demonstration/gate-inventory.md) -- every gate in the route files, traced line by line. The working superset the other three are cut from
