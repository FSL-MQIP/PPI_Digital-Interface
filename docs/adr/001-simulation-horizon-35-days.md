# ADR-001: Use 35-day simulation horizon

## Status
Accepted

## Context
The standalone `Model.R` used a 40-day total simulation horizon, reporting spoilage statistics at days 7, 14, 21, 28, and 35. When adapted to the Shiny app, `t_H` was sourced from the consumer stage default time (28 days), which reduced the simulation horizon from 40 to 28 and dropped Day 35 from the output.

The confusion arose because `t_H` was used for two different purposes: the consumer stage duration (a model parameter) and the total simulation horizon (a simulation control parameter).

## Decision
Set the total simulation horizon to a fixed 35 days, decoupled from the consumer stage time parameter. The consumer stage duration continues to be derived as `horizon - sum(pre-consumer stages)` for BCLc bacteria, and from the `t_H` column in the input data for D bacteria.

## Consequences
- Day 35 results are restored in the Shiny app output
- Simulation horizon is no longer affected by user-uploaded consumer time data
- Consumer stage gets ~26.5 days of storage time with default parameters (35 - ~8.5), which is realistic
- Slightly shorter than the original 40-day horizon, but 35 is sufficient since no results are extracted beyond Day 35
