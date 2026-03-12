# Kanban Board

## Backlog

- Fix duplicate `Day` column from `cbind(SpoilStats, Bacterial_Concentration_Stats)` in `run_model.R`
- Refactor `fix_simulation` to accept `row_run` as a parameter instead of global variable
- Fix `adjustLag` dead code: `else` branch is overwritten regardless of `restartExp`
- Remove or repurpose "Back" button (Q1 is commented out, button has no destination)
- Eliminate redundant `process_csv_file` call in `renderTable` (already called in observer)
- Investigate time SD=0 for user uploads — consider allowing user-specified SD or computing from data

## In Progress


## Done

- Extend simulation horizon from 28 to 35 days and restore Day 35 output
