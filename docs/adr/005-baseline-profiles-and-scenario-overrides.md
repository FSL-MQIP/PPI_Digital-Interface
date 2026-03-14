# ADR-005: Baseline temperature profiles and scenario override precedence

## Status
Accepted

## Context
The model previously used static mean/SD values from `default_parameters.R` as defaults when users didn't upload temperature data. We now have actual baseline temperature CSV recordings for 4 of 5 supply chain stages, plus 4 disruption scenario CSVs (S1-S4) that represent real cold chain events (cooling failures, delivery delays, trunk openings).

The question of precedence arises: when a user uploads data for a stage AND selects a disruption scenario for the same stage, which should win?

## Decision
Adopt a three-tier precedence chain applied in order:

1. **Baseline profiles** (lowest priority) — loaded from CSV files at app startup, applied first to override pre-generated values in the input data
2. **User-uploaded data** — overrides baselines when user selects a stage and uploads a CSV
3. **Scenario overrides** (highest priority) — applied last, override everything including user data

This is implemented via two separate parameters to `run_spoilage_model()`:
- `default_profiles`: baseline profiles, applied before the user data loop
- `scenario_overrides`: scenario profiles, applied after the user data loop

When a scenario overrides user-uploaded data, a warning notification is shown to the user.

Scenarios are presented in the UI as two independent dropdowns within Q2 (Facility Storage: None/S1/S2, Delivery: None/S3/S4), allowing users to combine one scenario from each category since they affect different stages.

## Consequences
- Baseline CSV data replaces static mean/SD defaults for 4 stages (processing facility, transport to retail, retail, consumer)
- Transportation from retail to home retains static defaults (no baseline CSV)
- Disruption scenarios always take precedence, preventing silent override by user data
- Users are warned when their uploaded data is overridden by a scenario
- No model logic changes needed for new scenarios — just add CSV files and config entries to `scenario_profile_paths`
