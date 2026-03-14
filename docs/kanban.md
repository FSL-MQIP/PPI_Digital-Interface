# Kanban Board

## Backlog

- Implement control strategies (intervention options to reduce spoilage)
- Add environmental impact analysis (CO2 emissions associated with control strategies)


## In Progress


## Done

- (2026-03-12) Extend simulation horizon from 28 to 35 days and restore Day 35 output
- (2026-03-12) Fix duplicate `Day` column from `cbind(SpoilStats, Bacterial_Concentration_Stats)` in `run_model.R`
- (2026-03-12) Refactor `fix_simulation` to accept `row_run` as parameter instead of global variable injection
- (2026-03-12) BCLc now uses `t_H` column for consumer stage duration, consistent with D model
- (2026-03-12) Reorganize Model tab: inputs left, output right
- (2026-03-12) Apply Cornell red theme consistently, fix progress bar color
- (2026-03-12) Add mock test data and backend test script
- (2026-03-12) User APC input: Q1 UI with manual entry and CSV upload, N0 recalculation with Poisson re-sampling
- (2026-03-12) Add spoilage prediction plot with P25-P75 ribbon and shelf life marker
- (2026-03-12) Fix `adjustLag` dead code
- (2026-03-12) Back button now resets Q1 and Q2 (repurposed with APC feature)
- (2026-03-12) Redundant `process_csv_file` call resolved
- (2026-03-12) Time SD=0 for user uploads documented in ADR 002
- (2026-03-14) Dynamic temperature support: D pathway ODE solver uses hourly temperature profiles from uploaded CSVs
- (2026-03-14) Baseline temperature profiles: replace static defaults with CSV data for 4 stages, rename files
- (2026-03-14) Disruption scenarios: S1-S4 as combinable Q3 dropdowns, overlay baseline profiles
