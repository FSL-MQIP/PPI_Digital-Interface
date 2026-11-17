# Regenerate PPC baseline using the optimized ppc_pathway.R code
# This replaces the old baseline (generated from Digital-dairy-platform)
# so that set.seed(42) comparisons are exact with the vectorized code.

set.seed(42)

library(dplyr)
library(tibble)
library(purrr)
library(deSolve)
library(lamW)
library(formula.tools)
library(truncnorm)
library(furrr)
library(future)

plan(multisession, workers = 4)

# Determine script directory
args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grep("--file=", args)])
if (length(script_path) > 0) {
  script_dir <- dirname(normalizePath(script_path))
} else {
  script_dir <- getwd()
}

model_dir <- file.path(script_dir, "..", "milk-spoilage-model")
setwd(model_dir)
cat("Working directory:", getwd(), "\n")

source("config.R")
source("utils/growth_models.R")
source("utils/temperature.R")
source("pathways/ppc_pathway.R")

set.seed(42)

# Prepare PPC growth parameters (same as run_model.R and compare_distributions.R)
data_ppc <- read.csv("input_data/ppc_growth_params.csv")
data_ppc$mumax <- config$ppc_mumax_correction * data_ppc$mumax
ppc_ST_freq <- read.csv("input_data/ppc_st_frequency.csv")

data_ppc$h0 <- data_ppc$lag * data_ppc$mumax
data_ppc$b <- sqrt(data_ppc$mumax / log(10) * 24) / (config$T_ref_PPC - config$Tmin_PPC)

growth_parameter_ppc <- data_ppc %>%
  group_by(isolate) %>%
  reframe(
    Mean_h0 = mean(h0), StdDev_h0 = sd(h0),
    Mean_b = mean(b), StdDev_b = sd(b),
    Mean_LOG10Nmax = mean(LOG10Nmax), StdDev_LOG10Nmax = sd(LOG10Nmax),
    Topt = Topt
  ) %>% distinct()
growth_parameter_ppc <- as.data.frame(growth_parameter_ppc)
growth_parameter_ppc$STorAT <- paste0("ST_", unique(data_ppc$STorAT))

# Generate 500 PPC containers (same setup as compare_distributions.R)
n_containers <- 500
ppc_containers <- data.frame(lot_id = rep(1, n_containers), unit_id = 1:n_containers)

for (stage in config$stage_order) {
  stage_cfg <- config$temperature_stages[[stage]]
  cols <- config$stage_to_cols[[stage]]
  if (stage_cfg$sd > 0) {
    ppc_containers[[cols$temp]] <- rnorm(n_containers, mean = stage_cfg$mean, sd = stage_cfg$sd)
  } else {
    ppc_containers[[cols$temp]] <- rep(stage_cfg$mean, n_containers)
  }
  duration_sd <- if (!is.null(stage_cfg$duration_sd)) stage_cfg$duration_sd else 0
  if (duration_sd > 0) {
    ppc_containers[[cols$time]] <- pmax(rnorm(n_containers, mean = stage_cfg$duration, sd = duration_sd), 0.001)
  } else {
    ppc_containers[[cols$time]] <- rep(stage_cfg$duration, n_containers)
  }
}

temp_profiles <- load_baseline_profiles(config$temperature_stages)

# Run PPC pathway
cat("Running PPC pathway for", n_containers, "containers...\n")
ppc_results <- run_ppc_pathway(ppc_containers, config, growth_parameter_ppc,
                                ppc_ST_freq, temp_profiles)

# Compute distributional summary
ppc_distribution <- ppc_results %>%
  group_by(day) %>%
  summarise(
    n = n(),
    mean = mean(log10_concentration, na.rm = TRUE),
    sd = sd(log10_concentration, na.rm = TRUE),
    P5 = quantile(log10_concentration, 0.05, na.rm = TRUE),
    P25 = quantile(log10_concentration, 0.25, na.rm = TRUE),
    median = median(log10_concentration, na.rm = TRUE),
    P75 = quantile(log10_concentration, 0.75, na.rm = TRUE),
    P95 = quantile(log10_concentration, 0.95, na.rm = TRUE),
    .groups = "drop"
  )

cat("\nNew PPC baseline at key days:\n")
print(ppc_distribution %>% filter(day %in% c(7, 14, 21, 28, 35)))

write.csv(ppc_distribution, file.path(script_dir, "baseline_ppc_distribution.csv"), row.names = FALSE)
cat("\nSaved to verification/baseline_ppc_distribution.csv\n")

plan(sequential)
