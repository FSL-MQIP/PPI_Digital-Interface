# Development Log

## 2026-03-12: Extended simulation horizon from 28 to 35 days

When the standalone `Model.R` was adapted into the Shiny app (`run_model.R`), the total simulation horizon was inadvertently reduced from 40 to 28 days. This happened because `t_H` (the parameter controlling the simulation range) was sourced from the consumer stage's default time (28 days), conflating "consumer storage duration" with "total shelf-life horizon." These are different concepts — the consumer stage is one part of the supply chain, while the simulation horizon defines how many total days are modeled.

The standalone model uses 40 days and reports results at days 7, 14, 21, 28, 35. The Shiny app was only reporting through day 28, and Day 35 was silently dropped.

**Changes made:**
- `App.R`: Removed `t_H_value` derivation from consumer time — no longer passed to the model
- `run_model.R`: Default simulation horizon set to 35 (independent of consumer stage defaults)
- `run_model.R`: Added Day 35 extraction, statistics calculation, and inclusion in output

**Why 35 and not 40:** The team confirmed 35 days is sufficient for shelf-life reporting. The original 40 was a generous buffer, not a meaningful shelf-life target.

## 2026-03-12: Code review — issues identified

A comprehensive code review was performed comparing the Shiny app implementation against the standalone `Model.R` and the stated intent. Key issues found:

- **Day 35 missing** (fixed above)
- **Duplicate `Day` column** from `cbind(SpoilStats, Bacterial_Concentration_Stats)` in `run_model.R`
- **~~Output unit typo~~**: "QBU" is correct — Quantifiable Bacterial Unit (not a typo)
- **`fix_simulation` relies on global variable**: `row_run` injected via `assign()` to `.GlobalEnv`
- **`adjustLag` bug**: `else` branch is dead code — always overwritten by line 355
- **"Back" button** has no destination since Q1 is commented out
- **`process_csv_file` called twice** per upload (once in observer, once in summary table render)
- **Time SD hardcoded to 0** for user uploads — removes variability from user-supplied stages

These remain open for future fixes (tracked in kanban).

## 2026-03-12: Fixed duplicate Day column and fix_simulation global variable

**Duplicate Day column:** `calculate_spoil_stats` in `run_model.R` had `group_by(Day)` on `Bacterial_Concentration_Stats` which served two purposes: overriding the upstream `rowwise()` grouping (line 405) and adding a `Day` column that duplicated the one in `SpoilStats`. Replaced with `ungroup()` before `summarise` — clears the rowwise grouping without the duplicate column.

**fix_simulation global variable:** `fix_simulation()` in `model_helpers.R` relied on `row_run` from the calling environment, which `run_model.R` injected via `assign("row_run", ..., envir = .GlobalEnv)`. This is fragile and pollutes the global environment. Changed `fix_simulation` to accept `row_run` as an explicit parameter, and replaced the wrapper function with a direct `map` call.

## 2026-03-12: BCLc now uses t_H column for consumer stage duration

Previously, `simulate_growth_row` for BCLc bacteria derived consumer stage duration as `t_H_total - sum(other stage durations)`, ignoring the actual `t_H` column in the data. This meant user-uploaded consumer time data had no effect on BCLc growth — only the D model respected it.

Changed `simulate_growth_row` to read `t_H` directly from the row data, consistent with how the D model uses it. With the pre-built data (`t_H=40`), results at days 7–35 are unchanged because `time_in_stage` clamps to the simulation window. But user-uploaded consumer time will now be properly used by both growth models.

## 2026-03-12: Reorganized model tab layout — input left, output right

Restructured the Model tab from a sidebar+main panel layout (where inputs, uploads, summary, and results were mixed) into a clear two-column layout:
- **Left column (width 5):** Preliminary questions box + supply chain data input box (file uploads and Predict button)
- **Right column (width 7):** Summary box (collapsible) + Spoilage Statistics box

Split the single `prediction_section` renderUI into two: `input_section` (left) and `output_section` (right). Used shinydashboard `box()` with headers for visual grouping. Box headers use Cornell red (`status = "danger"` with CSS override to #B31B1B). Spoilage statistics table wrapped in `overflow-x: auto` for horizontal scrolling, and column names shortened (e.g., "Median Bacterial Concentration (log10 QBU/mL)" → "Median QBU").

## 2026-03-12: User APC Input Feature

Added user-facing APC (Aerobic Plate Count) input as Q1 in the model workflow. Users can now:
- Enter mean and SD of log10 CFU/mL manually
- Upload a CSV of raw APC measurements (auto-fits normal distribution)
- Or use defaults (mean=3.52, sd=0.70)

The backend applies proportional scaling with Poisson re-sampling to adjust N0 in pre-generated data without re-running the full 10-step pipeline (see ADR 003). This preserves community composition, pasteurization effects, and stochastic container-level behavior while being fast enough for interactive use.

Files modified: `App.R`, `model/run_model.R`, `utils/helpers.R`
New test data: `test_data/apc_measurements.csv`

## 2026-03-12: Spoilage prediction plot

Added a ggplot2 visualization to the output panel showing predicted spoiled % over time. Features:
- Median spoiled % line with points at days 7, 14, 21, 28, 35
- P25-P75 shaded ribbon showing interquartile range
- Horizontal dashed line at 25% marking the shelf life threshold
- When median crosses 25%, a vertical dotted line and label show the interpolated shelf life day

Plot appears above the (now collapsible) spoilage statistics table.

## 2026-03-14: Dynamic Temperature Support for D Pathway

Added support for hourly temperature profiles in the D pathway (Baranyi ODE) growth model. Previously, uploaded hourly temperature CSVs were reduced to mean/SD, losing all temporal detail. Now the raw time-series is preserved and passed directly to the ODE solver via `approxfun`, enabling more realistic growth predictions that respond to actual temperature fluctuations.

Key changes:
- `extract_temp_profile()` helper preserves raw time-temperature data from uploaded CSVs
- `build_env_conditions()` constructs variable-length temperature profiles for the ODE solver, splicing in hourly data for stages that have it and 2-point step functions for stages using defaults
- Stage duration is determined by the profile span when hourly data is provided
- BCLc pathway unchanged (continues using mean temperature)
- No UI changes — existing CSV upload flow automatically detects and uses hourly profiles

Files modified: `utils/helpers.R`, `App.R`, `model/run_model.R`

## 2026-03-14: Baseline Temperature Profiles Replace Static Defaults

Replaced the static mean/SD temperature defaults with actual baseline temperature CSV data for 4 out of 5 supply chain stages. The baseline CSVs were also renamed for clarity:

- `adjP1-A-BL FS.csv` → `baseline_facility_storage.csv` (processing facility, ~2.4 days, mean 1.7°C)
- `adjP1-A-BL DL.csv` → `baseline_transport_to_retail.csv` (transport to retail, ~8 hours, mean 4.5°C)
- `hourly_temperature_5days.csv` → `baseline_retail.csv` (retail, ~5.5 days, 6.5°C constant)
- `hourly_temperature_28days.csv` → `baseline_consumer.csv` (consumer, ~28 days, 6.5°C constant)

Transportation from retail to home retains its original static default (no baseline CSV available).

The D pathway ODE solver now uses these baseline profiles by default via `build_env_conditions()`. BCLc uses the profile mean temperature. User-uploaded data overrides the baselines for any stage. Default parameter values in `default_parameters.R` were updated to match the baseline CSV statistics.

Files modified: `config/default_parameters.R`, `App.R`, `model/run_model.R`, `test_data/test_backend.R`
Files renamed: 4 baseline CSV files in `input_data/`

## 2026-03-14: Supply Chain Disruption Scenarios (S1-S4)

Added 4 disruption scenarios as a new Q3 step in the UI workflow, after temperature data (Q2). Users select from two independent dropdowns:

- **Facility Storage** (None / S1: Storage Cooling System Disruption / S2: Delivery Delay)
- **Delivery** (None / S3: Temp Increase from Trunk Opening / S4: Delivery Cooling System Disruption)

Scenarios are combinable — users can select one from each dropdown simultaneously since they affect different supply chain stages. Selected scenarios override the baseline temperature profile for their respective stage.

Scenario CSV files were renamed for clarity:
- `adjP1-A-S1 FS.csv` → `scenario_s1_storage_cooling_disruption.csv`
- `adjP1-A-S2 FS.csv` → `scenario_s2_delivery_delay.csv`
- `adjP1-A-S3 DL.csv` → `scenario_s3_trunk_opening.csv`
- `adjP1-A-S4 DL.csv` → `scenario_s4_delivery_cooling_disruption.csv`

No model changes needed — scenarios overlay the `default_profiles` parameter already supported by `run_spoilage_model()`.

Files modified: `config/default_parameters.R`, `App.R`, `test_data/test_backend.R`
Files renamed: 4 scenario CSV files in `input_data/`

## 2026-03-14: Scenario Override Precedence and Q2/Q3 Merge

Fixed scenario override precedence: when a user uploads temperature data AND selects a disruption scenario for the same supply chain stage, the scenario now takes precedence (previously user data won silently). A warning notification is shown when this happens.

Merged the Q3 disruption scenario step into Q2 — scenario dropdowns now appear directly in the temperature data question, eliminating the extra Continue/Back step. The model now receives `scenario_overrides` as a separate parameter applied after user data, ensuring correct precedence: defaults → user data → scenario overrides.

Files modified: `model/run_model.R`, `App.R`, `test_data/test_backend.R`
