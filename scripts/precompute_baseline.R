# Pre-compute baseline model results and save to RDS
# Run this script whenever default parameters or input data change
# Usage: Rscript scripts/precompute_baseline.R

setwd("D:/GitHub/PPI_Digital-Interface")

cat("Loading dependencies...\n")
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

plan(multisession, workers = min(4, max(1, parallel::detectCores() - 1)))

# Load baseline temperature profiles
default_profiles <- list()
for (stage in names(default_profile_paths)) {
  path <- default_profile_paths[[stage]]
  if (!is.null(path) && file.exists(path)) {
    data <- read.csv(path, stringsAsFactors = FALSE)
    default_profiles[[stage]] <- extract_temp_profile(data)
  }
}

# Load input data
ModelData_BCLc_input <- read_csv("input_data/ModelData_BCLc_input.csv", show_col_types = FALSE)
ModelData_D_input <- read_csv("input_data/ModelData_D_input.csv", show_col_types = FALSE)

cat("Running baseline model...\n")
baseline_result <- run_spoilage_model(
  ModelData_BCLc_input = ModelData_BCLc_input,
  ModelData_D_input = ModelData_D_input,
  stage_stats = NULL,
  selected_stages = NULL,
  default_profiles = default_profiles
)

cat("Saving to input_data/baseline_result.rds...\n")
saveRDS(baseline_result, "input_data/baseline_result.rds")

cat("Done.\n")
cat("  Pre-consumer spoilage:", baseline_result$pct_spoiled_at_retail, "%\n")
cat("  Consumer days to 25%:", baseline_result$days_to_25pct_consumer, "\n")
