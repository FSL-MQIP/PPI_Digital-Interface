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
