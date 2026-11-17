# verification/test_integration.R
# Integration tests for scenario pipeline wired into run_model()
# Run from milk-spoilage-model/: Rscript ../verification/test_integration.R

source("run_model.R")

# Test 1: PPC initial reduction changes result
set.seed(42)
result_base <- run_model()
set.seed(42)
result_ppc <- run_model(interventions = list(ppc_initial_reduction_log = 3))

base_d14 <- result_base$spoilage_summary[result_base$spoilage_summary$day == 14, "median_pct_spoiled"]
ppc_d14 <- result_ppc$spoilage_summary[result_ppc$spoilage_summary$day == 14, "median_pct_spoiled"]
cat(sprintf("Baseline day-14: %.1f%%\n", base_d14))
cat(sprintf("PPC -3log day-14: %.1f%%\n", ppc_d14))
stopifnot(ppc_d14 < base_d14)
cat("PASS: PPC -3log reduces spoilage\n")

# Test 2: conflict warning
set.seed(42)
result_conflict <- run_model(
  interventions = list(stage_temp_overrides = list(retail = list(temp_delta = -2))),
  disruptions = list(retail = list(type = "temp_shift", temp_delta = 5))
)
stopifnot(length(result_conflict$warnings) > 0)
stopifnot(any(grepl("retail", result_conflict$warnings)))
cat("PASS: conflict warning emitted\n")

# Test 3: scenario metadata populated
stopifnot(result_ppc$scenario$interventions_applied$ppc_initial_reduction_log == 3)
cat("PASS: intervention metadata recorded\n")

# Test 4: disruption metadata
set.seed(42)
result_dis <- run_model(disruptions = list(retail = list(type = "temp_shift", temp_delta = 3)))
stopifnot("retail" %in% names(result_dis$scenario$disruptions_applied))
cat("PASS: disruption metadata recorded\n")

cat("\nAll integration tests passed.\n")
