# Test: Verify all 4 scenarios have positive economic loss and CO2e vs baseline
# Usage: Rscript test_data/test_comparison.R

setwd("D:/GitHub/PPI_Digital-Interface")

suppressPackageStartupMessages({
  source("config/default_parameters.R")
  source("utils/helpers.R")
  source("utils/model_helpers.R")
  source("model/run_model.R")
  library(tidyverse)
  library(furrr)
  library(deSolve)
  library(truncnorm)
  library(EnvStats)
  library(rmutil)
  library(MCMCpack)
})

plan(sequential)

# Load baseline profiles
default_profiles <- list()
for (stage in names(default_profile_paths)) {
  path <- default_profile_paths[[stage]]
  if (!is.null(path) && file.exists(path)) {
    data <- read.csv(path, stringsAsFactors = FALSE)
    default_profiles[[stage]] <- extract_temp_profile(data)
  }
}

# Load scenario profiles
scenario_profiles <- list()
for (name in names(scenario_profile_paths)) {
  info <- scenario_profile_paths[[name]]
  if (file.exists(info$path)) {
    data <- read.csv(info$path, stringsAsFactors = FALSE)
    scenario_profiles[[name]] <- list(
      profile = extract_temp_profile(data),
      stage = info$stage,
      label = info$label
    )
  }
}

# Load input data
ModelData_BCLc_input <- read_csv("input_data/ModelData_BCLc_input.csv", show_col_types = FALSE)
ModelData_D_input <- read_csv("input_data/ModelData_D_input.csv", show_col_types = FALSE)

# Constants (same as App.R)
containers <- 1000
vol_per_container <- 1.893

# Helper: compute CO2e using per-container consumer spoil times
compute_co2e <- function(res, consumer_days, n) {
  retail_frac <- res$pct_spoiled_at_retail / 100
  total_frac <- mean(res$consumer_spoil_times <= consumer_days)
  consumer_frac <- max(0, total_frac - retail_frac)
  retail_L <- retail_frac * n * vol_per_container
  consumer_L <- consumer_frac * n * vol_per_container
  retail_L * 0.55 + consumer_L * 0.2
}

# --- Run baseline ---
cat("=== Running baseline ===\n")
set.seed(42)
baseline <- run_spoilage_model(
  ModelData_BCLc_input = ModelData_BCLc_input,
  ModelData_D_input = ModelData_D_input,
  stage_stats = NULL,
  selected_stages = NULL,
  default_profiles = default_profiles
)

ref_consumer_days <- baseline$days_to_25pct_consumer
b_co2e <- compute_co2e(baseline, ref_consumer_days, containers)

cat("  Shelf life (days_to_25pct_consumer):", baseline$days_to_25pct_consumer, "\n")
cat("  Pre-consumer spoilage:", baseline$pct_spoiled_at_retail, "%\n")
cat("  Reference consumer days:", ref_consumer_days, "\n")
cat("  Baseline CO2e:", round(b_co2e, 2), "kg\n\n")

# --- Run each scenario ---
scenario_ids <- c("s1", "s2", "s3", "s4")
all_passed <- TRUE

for (sid in scenario_ids) {
  cat("=== Scenario", toupper(sid), ":", scenario_profiles[[sid]]$label, "===\n")

  overrides <- list()
  overrides[[scenario_profiles[[sid]]$stage]] <- scenario_profiles[[sid]]$profile

  set.seed(42)
  result <- run_spoilage_model(
    ModelData_BCLc_input = ModelData_BCLc_input,
    ModelData_D_input = ModelData_D_input,
    stage_stats = NULL,
    selected_stages = NULL,
    default_profiles = default_profiles,
    scenario_overrides = overrides
  )

  s_days <- result$days_to_25pct_consumer
  b_days <- baseline$days_to_25pct_consumer

  delta_days <- b_days - s_days
  econ_loss <- delta_days * 0.03 * containers

  s_co2e <- compute_co2e(result, ref_consumer_days, containers)
  delta_co2e <- s_co2e - b_co2e

  cat("  Shelf life:", s_days, "days (baseline:", b_days, ", delta:", round(delta_days, 1), ")\n")
  cat("  Pre-consumer spoilage:", result$pct_spoiled_at_retail, "%\n")
  cat("  Economic loss: $", round(econ_loss, 2), "per lot\n")
  cat("  CO2e:", round(s_co2e, 2), "kg (baseline:", round(b_co2e, 2), ", delta:", round(delta_co2e, 2), ")\n")

  if (delta_days <= 0) {
    cat("  ** FAIL: expected positive shelf-life loss\n")
    all_passed <- FALSE
  }
  if (econ_loss <= 0) {
    cat("  ** FAIL: expected positive economic loss\n")
    all_passed <- FALSE
  }
  if (delta_co2e <= 0) {
    cat("  ** FAIL: expected positive delta CO2e\n")
    all_passed <- FALSE
  }

  if (delta_days > 0 && econ_loss > 0 && delta_co2e > 0) {
    cat("  PASSED\n")
  }
  cat("\n")
}

if (all_passed) {
  cat("=== ALL SCENARIOS PASSED ===\n")
} else {
  cat("=== SOME SCENARIOS FAILED ===\n")
  quit(status = 1)
}
