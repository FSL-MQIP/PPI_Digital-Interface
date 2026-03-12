# ADR-002: User input data handling

## Status
Accepted

## Context
Users can upload CSV files containing time-temperature profiles for each of the 5 supply chain stages. The model needs to incorporate this data into the Monte Carlo simulation, which requires per-container (per-row) variability.

A single user CSV provides one time series for one stage — yielding a mean temperature and a temperature SD (from the readings), but only a single duration value (last timestamp minus first timestamp), with no way to derive time variability from a single observation.

## Decision

### Temperature
- Extract mean and SD from the user's temperature column
- Sample each container's stage temperature from `rnorm(mean, sd)`
- Each iteration gets a different temperature draw

### Time
- Extract duration as the difference between the last and first timestamp
- Set time SD to 0 — every container gets the same duration for user-supplied stages
- This is a deliberate simplification: a single time-temperature profile cannot provide time variability

### Stages without user data
- Keep the original pre-built values from the input CSVs (`ModelData_BCLc_input.csv`, `ModelData_D_input.csv`)
- These were generated using stage-specific distributions (triangular, Laplace, uniform, truncated normal) and already contain per-row variability

### BCLc and D models
- Both models use all 5 stage columns (`t_F`, `t_T`, `t_S`, `t_T2`, `t_H` and `T_F`, `T_T`, `T_S`, `T_T2`, `T_H`) directly from the data
- **BCLc (Buchanan model):** Stage durations define piecewise growth boundaries; consumer time comes from the `t_H` column
- **D (Baranyi dynamic model):** Stage columns construct the temperature-time profile for the ODE solver

## Consequences
- User-supplied stages have temperature variability but no time variability
- This is less realistic than the pre-built data (which has both), but is the best that can be extracted from a single CSV upload
- The summary table displays user-provided mean and SD=0 for time, making this transparent to the user
- Both BCLc and D models use the same `t_H` column for consumer stage duration, ensuring consistent behavior
