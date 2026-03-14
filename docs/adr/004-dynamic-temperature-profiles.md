# ADR-004: Dynamic temperature profiles for D pathway ODE solver

## Status
Accepted

## Context
The D pathway growth model uses the Baranyi ODE solver (`deSolve::ode()`) with `approxfun` interpolation over a temperature-time profile. Previously, each supply chain stage was represented as a 2-point piecewise-constant step function, stored in fixed-width 10-column matrices (`env_cond_time`, `env_cond_temp`). When users uploaded hourly temperature CSVs, `process_csv_file()` reduced them to mean/SD — all temporal detail was lost.

The ODE solver already supports arbitrary time-varying temperature profiles via `approxfun`. The infrastructure was there but not utilized.

## Decision
Replace the fixed-width env_cond matrices with a `build_env_conditions()` function that constructs variable-length temperature profiles per container. For stages with hourly data, the actual time-temperature series is spliced in. For stages without, 2-point step functions are used (identical to previous behavior). Epsilon gaps (1e-5 days) between stages maintain sharp temperature transitions.

The BCLc pathway stays static — it continues using mean temperature per stage via `muAtNewTemp()`, since BCLc bacteria lack ODE parameters (`mu_opt`, `Q0`, `Tmin`, etc.).

Stage duration is determined by the profile span when hourly data is provided. Irregular sampling intervals are handled naturally by `approxfun` interpolation.

## Consequences
- D pathway responds to actual temperature fluctuations instead of just mean values
- More realistic spoilage predictions for stages with variable temperatures
- No changes needed to `predict_dynamic_growth()` or `approx_env()` — they already handle variable-length input
- `extract_temp_profile()` helper preserves raw time-series from uploaded CSVs alongside existing mean/SD extraction
- Same profile used for all containers in a simulation run (no per-container sampling for dynamic stages)
