# verification/verify_scenarios.R
# Full integration verification for intervention and disruption scenarios.
# Run from milk-spoilage-model/: Rscript ../verification/verify_scenarios.R
#
# Compares against quantitative reference baselines:
#   - PPC interventions: PPC-only runs (P_ppc=1.0) vs ppc_*.csv
#   - Disruption S1-S4: combined model vs PPI scenario baselines
#   - Combined model: regression vs milk_model_baseline.csv

source("run_model.R")

outdir <- "../verification/scenario_baselines"
pass_count <- 0
fail_count <- 0
skip_count <- 0

check <- function(name, condition) {
  if (condition) {
    cat(sprintf("  PASS: %s\n", name))
    pass_count <<- pass_count + 1
  } else {
    cat(sprintf("  FAIL: %s\n", name))
    fail_count <<- fail_count + 1
  }
}

skip <- function(name, reason) {
  cat(sprintf("  SKIP: %s (%s)\n", name, reason))
  skip_count <<- skip_count + 1
}

# Helpers for shelf life from result$shelf_life
total_sl <- function(result) result$shelf_life$total_days
consumer_sl <- function(result) result$shelf_life$consumer_days

# ============================================================
# 1. No-change regression (combined model)
# ============================================================
cat("\n=== 1. No-change regression ===\n")
set.seed(42)
result_base <- run_model()
baseline <- read.csv(file.path(outdir, "milk_model_baseline.csv"))

check("same columns", identical(names(result_base$spoilage_summary), names(baseline)))
check("same row count", nrow(result_base$spoilage_summary) == nrow(baseline))
check("no warnings", length(result_base$warnings) == 0)
check("shelf_life present", is.list(result_base$shelf_life))
check("shelf_life has total_days", is.numeric(result_base$shelf_life$total_days))
check("shelf_life has consumer_days", is.numeric(result_base$shelf_life$consumer_days))
check("consumer_days < total_days", result_base$shelf_life$consumer_days < result_base$shelf_life$total_days)
cat(sprintf("  INFO: baseline total_sl=%dd, consumer_sl=%.1fd, pre_consumer=%.1fd\n",
            total_sl(result_base), consumer_sl(result_base),
            result_base$shelf_life$pre_consumer_days))

# Seed-matched exact comparison
for (d in baseline$day) {
  got <- result_base$spoilage_summary[result_base$spoilage_summary$day == d, "median_pct_spoiled"]
  ref <- baseline[baseline$day == d, "median_pct_spoiled"]
  check(sprintf("day-%d median matches baseline (got=%.1f, ref=%.1f)", d, got, ref),
        abs(got - ref) < 0.01)
}

# ============================================================
# 2. PPC-only intervention tests (quantitative vs reference)
# ============================================================
cat("\n=== 2. PPC-only intervention tests (P_ppc=1.0) ===\n")

# PPC-only config: all containers are PPC
ppc_only_cfg <- config
ppc_only_cfg$P_ppc_min <- 1.0
ppc_only_cfg$P_ppc_max <- 1.0

# Tolerance for stochastic comparison (10 lots, parallel execution)
ppc_tol <- 10  # pp

# 2a. PPC baseline
set.seed(42)
r_ppc_base <- run_model(user_config = ppc_only_cfg)
ppc_ref <- read.csv(file.path(outdir, "ppc_baseline.csv"))
ppc_ref_d14 <- ppc_ref[ppc_ref$day == 14, "median_pct"]
got <- r_ppc_base$spoilage_summary[r_ppc_base$spoilage_summary$day == 14, "median_pct_spoiled"]
cat(sprintf("  INFO: PPC baseline day-14: got=%.1f%%, ref=%.1f%%\n", got, ppc_ref_d14))
check(sprintf("PPC baseline day-14 within %dpp of reference (%.1f vs %.1f)", ppc_tol, got, ppc_ref_d14),
      abs(got - ppc_ref_d14) <= ppc_tol)

# 2b. PPC initial -1 log
set.seed(42)
r_ppc_1 <- run_model(user_config = ppc_only_cfg,
                      interventions = list(ppc_initial_reduction_log = 1))
ppc_ref_1 <- read.csv(file.path(outdir, "ppc_init_minus1log.csv"))
ref_d14 <- ppc_ref_1[ppc_ref_1$day == 14, "median_pct"]
got <- r_ppc_1$spoilage_summary[r_ppc_1$spoilage_summary$day == 14, "median_pct_spoiled"]
cat(sprintf("  INFO: PPC -1log day-14: got=%.1f%%, ref=%.1f%%\n", got, ref_d14))
check(sprintf("PPC -1log day-14 within %dpp of reference (%.1f vs %.1f)", ppc_tol, got, ref_d14),
      abs(got - ref_d14) <= ppc_tol)

# 2c. PPC initial -3 log
set.seed(42)
r_ppc_3 <- run_model(user_config = ppc_only_cfg,
                      interventions = list(ppc_initial_reduction_log = 3))
ppc_ref_3 <- read.csv(file.path(outdir, "ppc_init_minus3log.csv"))
ref_d14 <- ppc_ref_3[ppc_ref_3$day == 14, "median_pct"]
got <- r_ppc_3$spoilage_summary[r_ppc_3$spoilage_summary$day == 14, "median_pct_spoiled"]
cat(sprintf("  INFO: PPC -3log day-14: got=%.1f%%, ref=%.1f%%\n", got, ref_d14))
check(sprintf("PPC -3log day-14 within %dpp of reference (%.1f vs %.1f)", ppc_tol, got, ref_d14),
      abs(got - ref_d14) <= ppc_tol)

# 2d. PPC no ST 100
set.seed(42)
r_ppc_no100 <- run_model(user_config = ppc_only_cfg,
                          interventions = list(ppc_remove_st = c("100")))
ppc_ref_no100 <- read.csv(file.path(outdir, "ppc_no_st100.csv"))
ref_d14 <- ppc_ref_no100[ppc_ref_no100$day == 14, "median_pct"]
got <- r_ppc_no100$spoilage_summary[r_ppc_no100$spoilage_summary$day == 14, "median_pct_spoiled"]
cat(sprintf("  INFO: PPC no ST100 day-14: got=%.1f%%, ref=%.1f%%\n", got, ref_d14))
check(sprintf("PPC no ST100 day-14 within %dpp of reference (%.1f vs %.1f)", ppc_tol, got, ref_d14),
      abs(got - ref_d14) <= ppc_tol)

# 2e. PPC no ST 13 & 9
set.seed(42)
r_ppc_no13_9 <- run_model(user_config = ppc_only_cfg,
                            interventions = list(ppc_remove_st = c("13", "9")))
ppc_ref_no13_9 <- read.csv(file.path(outdir, "ppc_no_st13_9.csv"))
ref_d14 <- ppc_ref_no13_9[ppc_ref_no13_9$day == 14, "median_pct"]
got <- r_ppc_no13_9$spoilage_summary[r_ppc_no13_9$spoilage_summary$day == 14, "median_pct_spoiled"]
cat(sprintf("  INFO: PPC no ST13&9 day-14: got=%.1f%%, ref=%.1f%%\n", got, ref_d14))
check(sprintf("PPC no ST13&9 day-14 within %dpp of reference (%.1f vs %.1f)", ppc_tol, got, ref_d14),
      abs(got - ref_d14) <= ppc_tol)

# 2f. PPC ordering: -3log < -1log < no_st13_9 < no_st100 < baseline
ppc_vals <- list(
  baseline = r_ppc_base$spoilage_summary[r_ppc_base$spoilage_summary$day == 14, "median_pct_spoiled"],
  minus1 = r_ppc_1$spoilage_summary[r_ppc_1$spoilage_summary$day == 14, "median_pct_spoiled"],
  minus3 = r_ppc_3$spoilage_summary[r_ppc_3$spoilage_summary$day == 14, "median_pct_spoiled"],
  no100 = r_ppc_no100$spoilage_summary[r_ppc_no100$spoilage_summary$day == 14, "median_pct_spoiled"],
  no13_9 = r_ppc_no13_9$spoilage_summary[r_ppc_no13_9$spoilage_summary$day == 14, "median_pct_spoiled"]
)
check("ordering: -3log < -1log < baseline",
      ppc_vals$minus3 < ppc_vals$minus1 && ppc_vals$minus1 <= ppc_vals$baseline)
check("ordering: no_st13_9 < no_st100 < baseline",
      ppc_vals$no13_9 <= ppc_vals$no100 && ppc_vals$no100 <= ppc_vals$baseline)

# ============================================================
# 3. Combined model intervention direction tests
# ============================================================
cat("\n=== 3. Combined model intervention direction ===\n")

day14_base <- result_base$spoilage_summary[result_base$spoilage_summary$day == 14, ]

# 3a. PPC -3log in combined model should substantially reduce
set.seed(42)
r_combined_ppc3 <- run_model(interventions = list(ppc_initial_reduction_log = 3))
got <- r_combined_ppc3$spoilage_summary[r_combined_ppc3$spoilage_summary$day == 14, "median_pct_spoiled"]
cat(sprintf("  INFO: Combined PPC -3log day-14: got=%.1f%%, baseline=%.1f%%\n",
            got, day14_base$median_pct_spoiled))
check("combined PPC -3log reduces day-14 spoilage",
      got < day14_base$median_pct_spoiled)

# 3b. Microfiltration (affects non-PPC spore-formers)
set.seed(42)
r_micro <- run_model(interventions = list(spore_reduction = "microfiltration"))
got <- r_micro$spoilage_summary[r_micro$spoilage_summary$day == 14, "median_pct_spoiled"]
cat(sprintf("  INFO: Combined microfiltration day-14: got=%.1f%%, baseline=%.1f%%\n",
            got, day14_base$median_pct_spoiled))
check("combined microfiltration reduces or maintains spoilage",
      got <= day14_base$median_pct_spoiled + 1)

# 3c. PPC frequency halved
set.seed(42)
r_freq <- run_model(interventions = list(ppc_frequency_factor = 0.5))
got <- r_freq$spoilage_summary[r_freq$spoilage_summary$day == 14, "median_pct_spoiled"]
cat(sprintf("  INFO: Combined freq halved day-14: got=%.1f%%, baseline=%.1f%%\n",
            got, day14_base$median_pct_spoiled))
check("combined freq halved reduces spoilage",
      got <= day14_base$median_pct_spoiled)

# ============================================================
# 4. Disruption tests
# ============================================================
cat("\n=== 4. Disruption direction tests ===\n")

# 4a. Consumer +3C should increase spoilage at day 14
set.seed(42)
r_warm <- run_model(
  disruptions = list(consumer = list(type = "temp_shift", temp_delta = 3)))
got <- r_warm$spoilage_summary[r_warm$spoilage_summary$day == 14, "median_pct_spoiled"]
cat(sprintf("  INFO: Consumer +3C day-14: got=%.1f%%, baseline=%.1f%%\n",
            got, day14_base$median_pct_spoiled))
check("Consumer +3C increases day-14 spoilage",
      got > day14_base$median_pct_spoiled)

# 4b. Consumer +3C should reduce both shelf life metrics
cat(sprintf("  INFO: total_sl baseline=%dd, consumer+3C=%dd\n",
            total_sl(result_base), total_sl(r_warm)))
cat(sprintf("  INFO: consumer_sl baseline=%.1fd, consumer+3C=%.1fd\n",
            consumer_sl(result_base), consumer_sl(r_warm)))
check("Consumer +3C reduces total shelf life", total_sl(r_warm) <= total_sl(result_base))
check("Consumer +3C reduces consumer shelf life", consumer_sl(r_warm) <= consumer_sl(result_base))

# ============================================================
# 5. S1-S4 profile_csv reproduction
# ============================================================
cat("\n=== 5. S1-S4 profile_csv reproduction ===\n")

# Reference: PPI baselines use Median_Proportion (0-1 scale)
# Our combined model uses pct_spoiled (0-100 scale)
# Absolute values differ (combined has PPC); verify direction + ordering

s1_s4_scenarios <- list(
  s1 = list(
    stage = "processing_facility",
    path = "../PPI_Digital-Interface/input_data/scenario_s1_storage_cooling_disruption.csv",
    label = "S1: Storage cooling disruption"),
  s2 = list(
    stage = "processing_facility",
    path = "../PPI_Digital-Interface/input_data/scenario_s2_delivery_delay.csv",
    label = "S2: Delivery delay"),
  s3 = list(
    stage = "transportation_facility_to_retail",
    path = "../PPI_Digital-Interface/input_data/scenario_s3_trunk_opening.csv",
    label = "S3: Trunk opening"),
  s4 = list(
    stage = "transportation_facility_to_retail",
    path = "../PPI_Digital-Interface/input_data/scenario_s4_delivery_cooling_disruption.csv",
    label = "S4: Delivery cooling disruption")
)

# PPI reference values: Median_Proportion at day 35 (proportion spoiled, 0-1)
# baseline=0.55, s1=0.55, s2=0.50, s3=0.55, s4=0.55
# PPI reference: Median_Proportion at day 28
# baseline=0.40, s1=0.50, s2=0.20, s3=0.40, s4=0.40
# (S2 lower at day 28 because delay extends facility time at cold temps,
#  less consumer-stage growth at that calendar day)

s_results <- list()

for (sname in names(s1_s4_scenarios)) {
  scenario <- s1_s4_scenarios[[sname]]
  cat(sprintf("  Running %s: %s\n", sname, scenario$label))

  if (!file.exists(scenario$path)) {
    skip(paste0(sname, " runs"), paste0("CSV not found: ", scenario$path))
    next
  }

  disruption <- list()
  disruption[[scenario$stage]] <- list(type = "profile_csv", path = scenario$path)

  set.seed(42)
  result_s <- run_model(disruptions = disruption)

  check(paste0(sname, " runs without error"), is.data.frame(result_s$spoilage_summary))
  check(paste0(sname, " produces all output days"),
        nrow(result_s$spoilage_summary) == length(config$output_days))

  s_results[[sname]] <- result_s

  # Report per-day spoilage and shelf life
  for (d in c(14, 21, 28, 35)) {
    got <- result_s$spoilage_summary[result_s$spoilage_summary$day == d, "median_pct_spoiled"]
    cat(sprintf("    %s day-%d: %.1f%%\n", sname, d, got))
  }
  cat(sprintf("    %s total_sl=%dd, consumer_sl=%.1fd\n",
              sname, total_sl(result_s), consumer_sl(result_s)))
}

# Verify S1 direction: S1 (cooling failure at facility) should reduce consumer shelf life
# PPI ref: S1 days_to_25pct_consumer = 15.4 vs baseline 17.4 (worse)
if (!is.null(s_results$s1)) {
  cat(sprintf("  INFO: S1 consumer_sl=%.1fd vs baseline=%.1fd\n",
              consumer_sl(s_results$s1), consumer_sl(result_base)))
  check("S1 cooling failure reduces consumer shelf life",
        consumer_sl(s_results$s1) <= consumer_sl(result_base))
}

# S2 direction: delivery delay means milk spends more time at cold facility
# PPI ref: S2 days_to_25pct_consumer = 16.4 vs baseline 17.4 (slightly worse)
# At fixed calendar day (e.g. day 28), less consumer-stage time → less spoilage
if (!is.null(s_results$s2)) {
  s2_d28 <- s_results$s2$spoilage_summary[s_results$s2$spoilage_summary$day == 28, "median_pct_spoiled"]
  base_d28 <- result_base$spoilage_summary[result_base$spoilage_summary$day == 28, "median_pct_spoiled"]
  cat(sprintf("  INFO: S2 day-28=%.1f%% vs baseline=%.1f%% (less consumer time at day 28)\n",
              s2_d28, base_d28))
  check("S2 delivery delay reduces day-28 spoilage (more cold facility time)",
        s2_d28 <= base_d28)
  # But consumer shelf life should be slightly worse (facility was warmer during delay)
  cat(sprintf("  INFO: S2 consumer_sl=%.1fd vs baseline=%.1fd\n",
              consumer_sl(s_results$s2), consumer_sl(result_base)))
}

# Shelf life summary (both metrics)
cat("  INFO: Shelf life summary (total / consumer):\n")
cat(sprintf("    baseline: %dd / %.1fd\n", total_sl(result_base), consumer_sl(result_base)))
for (sname in names(s_results)) {
  cat(sprintf("    %s: %dd / %.1fd\n", sname,
              total_sl(s_results[[sname]]), consumer_sl(s_results[[sname]])))
}

# ============================================================
# 6. Conflict detection
# ============================================================
cat("\n=== 6. Conflict detection ===\n")

set.seed(42)
r_conflict <- run_model(
  interventions = list(stage_temp_overrides = list(retail = list(temp_delta = -2))),
  disruptions = list(retail = list(type = "temp_shift", temp_delta = 5)))
check("conflict warning emitted", length(r_conflict$warnings) > 0)
check("warning mentions retail", any(grepl("retail", r_conflict$warnings)))
cat(sprintf("  INFO: warnings = %s\n", paste(r_conflict$warnings, collapse = "; ")))

# ============================================================
# 7. Scenario metadata
# ============================================================
cat("\n=== 7. Scenario metadata ===\n")

check("baseline has empty interventions",
      length(result_base$scenario$interventions_applied) == 0)
check("baseline has empty disruptions",
      length(result_base$scenario$disruptions_applied) == 0)
check("PPC -3log records intervention",
      r_ppc_3$scenario$interventions_applied$ppc_initial_reduction_log == 3)
check("consumer +3C records disruption",
      "consumer" %in% names(r_warm$scenario$disruptions_applied))

# ============================================================
# Summary
# ============================================================
cat(sprintf("\n=== Results: %d passed, %d failed, %d skipped ===\n",
            pass_count, fail_count, skip_count))
if (fail_count > 0) stop("Verification failed")
cat("All scenario verifications passed.\n")
