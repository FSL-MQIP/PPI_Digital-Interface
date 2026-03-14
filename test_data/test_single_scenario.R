# Test a single scenario vs baseline
# Usage: Rscript test_data/test_single_scenario.R s2

setwd("D:/GitHub/PPI_Digital-Interface")

args <- commandArgs(trailingOnly = TRUE)
sid <- if (length(args) > 0) args[1] else "s1"

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

default_profiles <- list()
for (stage in names(default_profile_paths)) {
  path <- default_profile_paths[[stage]]
  if (!is.null(path) && file.exists(path)) {
    default_profiles[[stage]] <- extract_temp_profile(read.csv(path, stringsAsFactors = FALSE))
  }
}

scenario_profiles <- list()
for (name in names(scenario_profile_paths)) {
  info <- scenario_profile_paths[[name]]
  if (file.exists(info$path)) {
    scenario_profiles[[name]] <- list(
      profile = extract_temp_profile(read.csv(info$path, stringsAsFactors = FALSE)),
      stage = info$stage,
      label = info$label
    )
  }
}

ModelData_BCLc_input <- read_csv("input_data/ModelData_BCLc_input.csv", show_col_types = FALSE)
ModelData_D_input <- read_csv("input_data/ModelData_D_input.csv", show_col_types = FALSE)

containers <- 1000
vol <- 1.893

compute_co2e <- function(res, consumer_days, n) {
  retail_frac <- res$pct_spoiled_at_retail / 100
  total_frac <- mean(res$consumer_spoil_times <= consumer_days)
  consumer_frac <- max(0, total_frac - retail_frac)
  retail_frac * n * vol * 0.55 + consumer_frac * n * vol * 0.2
}

# Load precomputed baseline
baseline <- readRDS("input_data/baseline_result.rds")
ref_consumer_days <- baseline$days_to_25pct_consumer
b_co2e <- compute_co2e(baseline, ref_consumer_days, containers)

cat("BASELINE: shelf_life=", baseline$days_to_25pct_consumer,
    " pre_consumer=", baseline$pct_spoiled_at_retail, "%",
    " ref_consumer_days=", ref_consumer_days,
    " co2e=", round(b_co2e, 2), "kg\n\n")

# Run scenario
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

delta_days <- baseline$days_to_25pct_consumer - result$days_to_25pct_consumer
econ_loss <- delta_days * 0.03 * containers
s_co2e <- compute_co2e(result, ref_consumer_days, containers)
delta_co2e <- s_co2e - b_co2e

cat("  shelf_life=", result$days_to_25pct_consumer, " (delta=", round(delta_days, 1), " days)\n")
cat("  pre_consumer=", result$pct_spoiled_at_retail, "%\n")
cat("  econ_loss= $", round(econ_loss, 2), "\n")
cat("  co2e=", round(s_co2e, 2), "kg (delta=", round(delta_co2e, 2), ")\n")
cat("  econ_loss > 0:", econ_loss > 0, "\n")
cat("  delta_co2e > 0:", delta_co2e > 0, "\n")
