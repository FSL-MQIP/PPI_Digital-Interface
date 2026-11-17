# verification/test_run_model_function.R
# Smoke test: run_model() exists and returns expected structure
# Run from milk-spoilage-model/: Rscript ../verification/test_run_model_function.R

source("run_model.R")

# Test 1: run_model is a function
stopifnot(is.function(run_model))

# Test 2: call with defaults returns a list
result <- run_model()
stopifnot(is.list(result))
stopifnot("spoilage_summary" %in% names(result))
stopifnot("container_results" %in% names(result))
stopifnot("warnings" %in% names(result))
stopifnot("scenario" %in% names(result))

# Test 3: spoilage_summary is a data frame with expected columns
stopifnot(is.data.frame(result$spoilage_summary))
stopifnot(all(c("day", "median_pct_spoiled") %in% names(result$spoilage_summary)))

# Test 4: warnings is a character vector
stopifnot(is.character(result$warnings))

# Test 5: no-change regression structure
baseline <- read.csv("../verification/scenario_baselines/milk_model_baseline.csv")
stopifnot(identical(names(result$spoilage_summary), names(baseline)))
stopifnot(nrow(result$spoilage_summary) == nrow(baseline))

cat("PASS: run_model() returns expected structure\n")
cat("PASS: no-change regression structure matches baseline\n")

# Test 6: pct_spoiled_at_retail is present and valid
stopifnot("pct_spoiled_at_retail" %in% names(result$shelf_life))
stopifnot(is.numeric(result$shelf_life$pct_spoiled_at_retail))
stopifnot(result$shelf_life$pct_spoiled_at_retail >= 0)
stopifnot(result$shelf_life$pct_spoiled_at_retail <= 100)
cat("PASS: pct_spoiled_at_retail present and valid\n")

# Test 7: daily_median_spoilage is a data frame with expected columns
stopifnot("daily_median_spoilage" %in% names(result))
stopifnot(is.data.frame(result$daily_median_spoilage))
stopifnot(all(c("day", "median_pct", "P25", "P75") %in% names(result$daily_median_spoilage)))
stopifnot(nrow(result$daily_median_spoilage) == config$sim_duration + 1)
cat("PASS: daily_median_spoilage present with correct shape\n")
