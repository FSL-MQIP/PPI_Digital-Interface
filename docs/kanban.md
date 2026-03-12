# Kanban Board

## Backlog

- Fix `adjustLag` dead code: `else` branch is overwritten regardless of `restartExp`
- Remove or repurpose "Back" button (Q1 is commented out, button has no destination)
- Eliminate redundant `process_csv_file` call in `renderTable` (already called in observer)
- Investigate time SD=0 for user uploads — consider allowing user-specified SD or computing from data

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
