# Generate baseline + S1-S4 scenario outputs for comparison
# Run from repo root: Rscript verification/generate_scenario_baselines.R

setwd("PPI_Digital-Interface")

library(tidyverse)
library(fitdistrplus)
library(rmutil)
library(truncnorm)
library(EnvStats)
library(MCMCpack)
library(furrr)
library(deSolve)

source("config/default_parameters.R")
source("utils/helpers.R")
source("utils/model_helpers.R")
source("model/run_model.R")

plan(multisession, workers = 4)

# Load input data
ModelData_BCLc <- read.csv("input_data/ModelData_BCLc_input.csv")
ModelData_D <- read.csv("input_data/ModelData_D_input.csv")

# Load baseline temperature profiles
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

# Use 10 lots worth of data (subsample)
set.seed(42)
lots_to_keep <- sample(unique(ModelData_BCLc$lot_id), 10)
BCLc_sub <- ModelData_BCLc %>% filter(lot_id %in% lots_to_keep)
D_sub <- ModelData_D %>% filter(lot_id %in% lots_to_keep)

cat("Subsampled to 10 lots: BCLc =", nrow(BCLc_sub), "rows, D =", nrow(D_sub), "rows\n")

# Output directory
outdir <- file.path("..", "verification", "scenario_baselines")
dir.create(outdir, recursive = TRUE, showWarnings = FALSE)

# --- Baseline (no scenario) ---
cat("\n=== Running BASELINE ===\n")
baseline <- run_spoilage_model(
  BCLc_sub, D_sub,
  default_profiles = default_profiles
)
write.csv(baseline$SpoilStats_all, file.path(outdir, "baseline.csv"), row.names = FALSE)
cat("Baseline: pct_spoiled_at_retail =", baseline$pct_spoiled_at_retail, "\n")
cat("Baseline: days_to_25pct_consumer =", baseline$days_to_25pct_consumer, "\n")
print(baseline$SpoilStats_all)

# --- S1-S4 scenarios ---
for (sname in c("s1", "s2", "s3", "s4")) {
  cat("\n=== Running", toupper(sname), ":", scenario_profiles[[sname]]$label, "===\n")

  overrides <- list()
  overrides[[scenario_profiles[[sname]]$stage]] <- scenario_profiles[[sname]]$profile

  result <- run_spoilage_model(
    BCLc_sub, D_sub,
    default_profiles = default_profiles,
    scenario_overrides = overrides
  )

  write.csv(result$SpoilStats_all, file.path(outdir, paste0(sname, ".csv")), row.names = FALSE)
  cat(sname, ": pct_spoiled_at_retail =", result$pct_spoiled_at_retail, "\n")
  cat(sname, ": days_to_25pct_consumer =", result$days_to_25pct_consumer, "\n")
  print(result$SpoilStats_all)
}

plan(sequential)
cat("\nAll scenario baselines written to verification/scenario_baselines/\n")
