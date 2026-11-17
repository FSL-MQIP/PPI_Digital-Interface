# Milk Spoilage Model

A modular, script-based model for predicting fluid milk spoilage across the supply chain. Combines post-pasteurization contamination (PPC) bacteria modeling with two populated bacterial growth pathways (medium-growth, high-growth; a no-growth pathway exists but the current data never activates it) to estimate shelf life.


## Quick Start

### Run via the App (Shiny)

The interactive app (`App.R`) sits on top of the model and lets you set inputs, run the simulation, and view results without writing any R code.

1. Install the app packages in addition to the model [dependencies](#dependencies):

   ```r
   install.packages(c("shiny", "shinydashboard", "ggplot2"))
   ```

2. Launch the app from the repository root (the folder containing `App.R` and `milk-spoilage-model/`). Either run from a terminal:

   ```bash
   Rscript -e "shiny::runApp('App.R', launch.browser = TRUE)"
   ```

   or open `App.R` in RStudio and click **Run App**. The app must be started from the repository root, because it loads the model from `milk-spoilage-model/` using a relative path.

3. In the app, open the **Model** tab in the sidebar and set the inputs in the left panel:
   - **Simulation Settings** -- simulation duration (days)
   - **Post-Pasteurization Contamination (PPC)** -- PPC proportion of containers per lot and initial PPC reduction
   - **Raw Milk Microbial Load (APC)** -- enter a mean/SD manually or upload a CSV of APC values (one column named `apc`, `cfu`, or `count`)
   - **Interventions: Spore Reduction** -- choose a spore removal method or enter a measured log reduction
   - **Custom Time-Temperature Data (Optional)** -- upload a CSV with `time` and `temperature` columns for any supply chain stage to replace its baseline profile

4. Click **Run Simulation**. A loading indicator is shown while the model runs, which may take a few moments. Each run uses a fixed random seed (42), so the same inputs always give the same results and runs with different inputs can be compared directly.

5. Results appear in the right panel:
   - **Model Warnings** (only if any) -- e.g. when an intervention and an uploaded time-temperature profile target the same stage
   - **Pre-Consumer Spoilage** -- percentage of containers already spoiled (> 6 log10 CFU/mL) before they reach the consumer
   - **Consumer Shelf Life** -- days in consumer storage until 25% of a lot is spoiled (shown as "> X days" if the threshold is not reached within the simulation duration)
   - **Economic Value** -- shelf-life value per half-gallon container, at $0.03 per day of consumer shelf life (Lau et al. 2023)
   - **Environmental Emission** -- estimated CO₂e (kg) per container from wasted milk, weighting milk spoiled before vs. at the consumer (EPA WARM)
   - **Predicted Spoilage Over Time** -- plot of the median percentage of spoiled containers per lot by day, with the 25th-75th percentile range shaded and the 25% threshold marked
   - **Spoilage Summary** -- two tables at days 7, 14, 21, 28, 35 and 42 (days beyond the simulation duration are omitted): containers spoiled per lot (median, mean, SD, P5, P25, P75, P95 %) and microbial concentration across all containers (median, P5, P25, P75, P95 log10 CFU/mL)
   - **Applied Interventions & Disruptions** -- the interventions and uploaded profiles that were applied in the run, or a note that it was a baseline run

### Run from the Command Line

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
PPI_Digital-Interface/
├── App.R                                  # Shiny app (UI on top of the model; run from repo root)
├── milk-spoilage-model/                   # Core R simulation model
│   ├── run_model.R                        # Orchestrator (exports run_model(); sourced by App.R)
│   ├── config.R                           # Parameters & defaults
│   ├── scenario run instructions.txt      # Notes on running scenarios
│   ├── pathways/
│   │   ├── ppc_pathway.R                  # Gram-negative PPC (Baranyi ODE)
│   │   ├── nogrowth_pathway.R             # No-growth bacteria (constant)
│   │   ├── medium_growth_pathway.R        # BCLc bacteria (Buchanan model)
│   │   └── high_growth_pathway.R          # High-growth bacteria (Baranyi ODE)
│   ├── scenarios/
│   │   ├── interventions.R                # Intervention system (spore, PPC, temp overrides)
│   │   ├── disruptions.R                  # Disruption system (temp_spike, delay, profile_csv, temp_shift)
│   │   └── resolve.R                      # Pipeline orchestrator + conflict detection
│   ├── utils/
│   │   ├── growth_models.R                # Shared growth equations
│   │   └── temperature.R                  # Temperature profile construction
│   ├── input_data/
│   │   ├── baseline_*.csv                 # Baseline time-temperature profiles per stage
│   │   ├── *_growth_containers.csv        # Pre-generated non-PPC container pools
│   │   ├── ppc_growth_params.csv          # PPC growth parameters
│   │   ├── ppc_st_frequency.csv           # PPC sequence-type frequencies
│   │   ├── scenario_s*.csv                # Recorded disruption profiles (S1-S4)
│   │   └── trip_csv_exports_sampled_cold_start_trips/  # Sampled transport trip logs
│   └── output/                            # Simulation results
└── verification/                          # Baseline distributions + R test/verification scripts
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
| Retail Storage | static | 2.3 C | 1.82 days (SD 3.3) |
| Transport to Home | static | 8.5 C | 0.04 days (SD 0.02) |
| Consumer Home | static | 6.5 C | 27.96 days |

Pre-consumer window: **4.62 days** (sum of the mean durations of the four stages before Consumer Home).

The two dynamic stages (Processing Facility, Transport to Retail) take their temperature
*and their span* from the baseline profile CSVs; the temperature and duration shown for them
are the profile averages/spans. The three static stages use `config.R`'s `mean`
temperature and `duration`. Where a `duration_sd` is set, each container's stage
duration is drawn from a normal distribution with that SD (floored at 0.001 days).
The facility default previously read `2.4264 / 24` and was documented as 2.4 hours,
an hours/days error — its profile spans 2026-02-11 21:44:58 to 2026-02-14 07:58:58,
which is 2.4264 **days**. The profile always drove the simulation, so only the
reported shelf life was affected; baseline consumer shelf life is 2.7 days, not the
5.1 previously reported. See `docs/research/2026-08-06-port-audit.md` (D7).

## Interventions

The intervention system (`scenarios/interventions.R`) supports three categories of modifications that can be combined via `apply_interventions()`:

- **Category A -- Spore Reduction**: Presets for microfiltration (2.2 log), low-efficiency microfiltration (0.6 log), single bactofugation (1.4 log), and double bactofugation (2.0 log). Each reduces the initial load of the spore-forming genera only (`Bacillus`, `Paenibacillus`); the model has no spore *state*, so this is a shift in starting concentration, not a removal of spores as such. Every value is published -- see [`docs/reference/spore-removal-log-reductions.md`](docs/reference/spore-removal-log-reductions.md) -- and all are estimates that a processor's own measured reduction should override. The benefit is conditional: it appears in a long shelf-life plant and is invisible in a medium or short one, where PPC ends shelf life first (ADR 012).


## Configuration

Edit `config.R` to change simulation parameters:
- `n_lots` / `n_units` -- simulation size (default: 10 lots, 100 units)
- `P_ppc_min` / `P_ppc_max` -- PPC frequency range
- `sim_duration` -- total days (default: 40)
- `spoilage_threshold` -- log10 CFU/mL (default: 6.0)
- `temperature_stages` -- per-stage temperature mode (`"dynamic"` or `"static"`), CSV paths, and mean/sd fallbacks

## Dependencies

R 4.4+ with packages: `dplyr`, `tidyr`, `tibble`, `purrr`, `deSolve`, `lamW`, `formula.tools`, `truncnorm`, `furrr`, `future`

