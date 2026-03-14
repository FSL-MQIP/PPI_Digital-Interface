# ADR 003: N0 Scaling with Poisson Re-sampling for User APC Input

## Status

Accepted

## Context

The app uses pre-generated data (`ModelData_BCLc_input.csv`, `ModelData_D_input.csv`) that encodes the full 10-step pipeline from the BTRM_HTST_Survivor_Project: community composition, relative abundances, pasteurization survival, and Poisson sampling of post-pasteurization counts. When users provide their own bulk tank raw milk APC (Aerobic Plate Count) data, we need to adjust the initial microbial concentrations (N0/log10N0) without re-running the entire pipeline.

Three approaches were considered:

1. **Full pipeline re-run** — Re-execute all 10 pre-growth steps with user APC. Accurate but extremely slow (~minutes per run) and requires bundling the full pipeline code.
2. **Proportional scaling with Poisson re-sampling** — Scale `postpastCFU` proportionally to the ratio of user APC to original APC, then re-apply Poisson sampling. Preserves stochastic container-level effects critical for low-count scenarios.
3. **Direct N0 replacement** — Simply replace N0 with a scaled value. Fastest but skips Poisson sampling, losing the stochastic low-count behavior that is scientifically important.

## Decision

Use **proportional scaling with Poisson re-sampling** (Option 2).

For each lot:
1. Sample `log10CFU_lotini_new` from `rtruncnorm(mean=user_mean, sd=user_sd, b=5)`
2. Compute scale: `scale = 10^(log10CFU_lotini_new) / CFUlotini_original`
3. Scale: `postpastCFU_new = postpastCFU_original * scale`
4. Expected per container: `exp_postpastcontainer_new = 1900 * postpastCFU_new`
5. Poisson re-sample: `postpastcontainer_new = rpois(1, exp_postpastcontainer_new)`
6. Derive: `N0 = postpastcontainer_new / 1900`, `log10N0 = log10(N0)`
7. Re-classify: rows with `postpastcontainer < 1` → no-growth

## Consequences

- Preserves community composition (genera, relative abundances, survival/growth categories)
- Correctly handles log reduction (multiplicative scaling carries through pasteurization)
- Preserves stochastic Poisson effect at container level
- Much faster than full pipeline re-run (~seconds vs minutes)
- Trade-off: does not allow changing community composition or survival parameters
