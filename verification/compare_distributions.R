# Compare combined model pathway distributions against baselines
# Runs each pathway in isolation on the same data and compares quantiles
#
# SCOPE OF THE "EXACT" CLAIM BELOW: this script overrides the pool temperatures
# with the baseline profile mean and duration (lines 147-157 and 208-218) before
# simulating, exactly as run_ppi_baseline.R does. run_model() does neither -- it
# sends the medium pool through with its own CSV temperatures. So both sides of
# this comparison agree on a configuration that production never runs, and an
# EXACT result here says the growth mathematics is faithful, NOT that the model
# is correct end to end.
#
# Container assembly, pathway routing, aggregation and lot structure are tested
# in verify_structure.R. Restoring a production-path distribution comparison
# here needs D6 fixed first: config cannot currently reach the medium pathway,
# so there is no way to drive it to the baseline temperature through run_model().
# See docs/research/2026-08-06-port-audit.md (V0).

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

# Source the combined model modules
source("config.R")
source("utils/growth_models.R")
source("utils/temperature.R")
source("pathways/ppc_pathway.R")
source("pathways/nogrowth_pathway.R")
source("pathways/medium_growth_pathway.R")
source("pathways/high_growth_pathway.R")

# Load baselines
baseline_ppc <- read.csv(file.path(script_dir, "baseline_ppc_distribution.csv"))
baseline_ppi <- read.csv(file.path(script_dir, "baseline_ppi_distributions.csv"))
baseline_counts <- read.csv(file.path(script_dir, "baseline_ppi_pathway_counts.csv"))

cat("\n========== BASELINE REFERENCE ==========\n")
cat("PPI pathway counts:\n")
print(baseline_counts)

# =========================================================================
# TEST 1: PPC Pathway — same setup as baseline script
# =========================================================================
cat("\n========== TEST 1: PPC PATHWAY ==========\n")

set.seed(42)

# Prepare PPC growth parameters (same as run_model.R section 3)
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

# Generate 500 PPC containers with same temperature setup as baseline
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
ppc_results <- run_ppc_pathway(ppc_containers, config, growth_parameter_ppc,
                                ppc_ST_freq, temp_profiles)

# Compute distribution
ppc_new_dist <- ppc_results %>%
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

# Compare at key days
cat("\nPPC comparison at key days (baseline vs combined model):\n")
cat(sprintf("%-5s | %-30s | %-30s | %-10s\n", "Day", "Baseline (P5 / med / P95)", "Combined (P5 / med / P95)", "Match?"))
cat(paste(rep("-", 85), collapse = ""), "\n")

for (d in c(7, 14, 21, 28, 35)) {
  bl <- baseline_ppc %>% filter(day == d)
  cm <- ppc_new_dist %>% filter(day == d)
  if (nrow(bl) > 0 && nrow(cm) > 0) {
    # Check if medians are within 1 log10 (same distribution, different seed draws)
    med_diff <- abs(bl$median - cm$median)
    match <- ifelse(med_diff < 1.0, "OK", "DRIFT")
    cat(sprintf("%-5d | %6.2f / %6.2f / %6.2f     | %6.2f / %6.2f / %6.2f     | %s (d=%.2f)\n",
                d, bl$P5, bl$median, bl$P95, cm$P5, cm$median, cm$P95, match, med_diff))
  }
}

# =========================================================================
# TEST 2: Medium-Growth (BCLc) Pathway — run on full pool
# =========================================================================
cat("\n========== TEST 2: MEDIUM-GROWTH (BCLc) PATHWAY ==========\n")

set.seed(42)

pool_bclc <- read.csv("input_data/medium_growth_containers.csv")
pool_bclc_active <- pool_bclc %>%
  filter(Growth_category != "A" & postpastcontainer >= 1)

# Apply baseline profile overrides (same as PPI baseline script)
stage_order <- config$stage_order
stage_to_cols <- config$stage_to_cols
for (stage in stage_order) {
  if (!is.null(temp_profiles[[stage]])) {
    cols <- stage_to_cols[[stage]]
    profile_mean <- mean(temp_profiles[[stage]]$temperature)
    profile_duration <- max(temp_profiles[[stage]]$time_days)
    if (cols$temp %in% names(pool_bclc_active)) {
      pool_bclc_active[[cols$temp]] <- rep(profile_mean, nrow(pool_bclc_active))
      pool_bclc_active[[cols$time]] <- rep(profile_duration, nrow(pool_bclc_active))
    }
  }
}

# Run medium-growth pathway on full pool
# Override sim_duration to 35 to match baseline
config_bclc <- config
config_bclc$sim_duration <- 35
medium_results <- run_medium_growth_pathway(pool_bclc_active, config_bclc)

# Compute distribution
bclc_new_dist <- medium_results %>%
  group_by(day) %>%
  summarise(
    pathway = "medium_growth",
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

# Compare
bl_bclc <- baseline_ppi %>% filter(pathway == "medium_growth")
cat("\nBCLc comparison at key days (baseline vs combined model):\n")
cat(sprintf("%-5s | %-30s | %-30s | %-10s\n", "Day", "Baseline (P5 / med / P95)", "Combined (P5 / med / P95)", "Match?"))
cat(paste(rep("-", 85), collapse = ""), "\n")

for (d in c(7, 14, 21, 28, 35)) {
  bl <- bl_bclc %>% filter(day == d)
  cm <- bclc_new_dist %>% filter(day == d)
  if (nrow(bl) > 0 && nrow(cm) > 0) {
    med_diff <- abs(bl$median - cm$median)
    match <- ifelse(med_diff < 0.01, "EXACT", ifelse(med_diff < 0.1, "OK", "DRIFT"))
    cat(sprintf("%-5d | %6.2f / %6.2f / %6.2f     | %6.2f / %6.2f / %6.2f     | %s (d=%.4f)\n",
                d, bl$P5, bl$median, bl$P95, cm$P5, cm$median, cm$P95, match, med_diff))
  }
}

# =========================================================================
# TEST 3: High-Growth (D) Pathway — run on full pool
# =========================================================================
cat("\n========== TEST 3: HIGH-GROWTH (D) PATHWAY ==========\n")

set.seed(42)

pool_d <- read.csv("input_data/high_growth_containers.csv")

# Apply baseline profile overrides
for (stage in stage_order) {
  if (!is.null(temp_profiles[[stage]])) {
    cols <- stage_to_cols[[stage]]
    profile_mean <- mean(temp_profiles[[stage]]$temperature)
    profile_duration <- max(temp_profiles[[stage]]$time_days)
    if (cols$temp %in% names(pool_d)) {
      pool_d[[cols$temp]] <- rep(profile_mean, nrow(pool_d))
      pool_d[[cols$time]] <- rep(profile_duration, nrow(pool_d))
    }
  }
}

# Run high-growth pathway on full pool
config_d <- config
config_d$sim_duration <- 35
high_results <- run_high_growth_pathway(pool_d, config_d, temp_profiles)

# Compute distribution
d_new_dist <- high_results %>%
  group_by(day) %>%
  summarise(
    pathway = "high_growth",
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

# Compare
bl_d <- baseline_ppi %>% filter(pathway == "high_growth")
cat("\nD pathway comparison at key days (baseline vs combined model):\n")
cat(sprintf("%-5s | %-30s | %-30s | %-10s\n", "Day", "Baseline (P5 / med / P95)", "Combined (P5 / med / P95)", "Match?"))
cat(paste(rep("-", 85), collapse = ""), "\n")

for (d in c(7, 14, 21, 28, 35)) {
  bl <- bl_d %>% filter(day == d)
  cm <- d_new_dist %>% filter(day == d)
  if (nrow(bl) > 0 && nrow(cm) > 0) {
    med_diff <- abs(bl$median - cm$median)
    match <- ifelse(med_diff < 0.01, "EXACT", ifelse(med_diff < 0.1, "OK", "DRIFT"))
    cat(sprintf("%-5d | %6.2f / %6.2f / %6.2f     | %6.2f / %6.2f / %6.2f     | %s (d=%.4f)\n",
                d, bl$P5, bl$median, bl$P95, cm$P5, cm$median, cm$P95, match, med_diff))
  }
}

# =========================================================================
# SUMMARY
# =========================================================================
cat("\n========== SUMMARY ==========\n")
cat("PPC: Stochastic pathway — distributions should be similar but not identical\n")
cat("     (different random draws from same parameter distributions)\n")
cat("     Median within 1 log10 = OK\n\n")
cat("BCLc: Deterministic given same input data + temperature\n")
cat("      Should match exactly (< 0.01 log10 difference)\n\n")
cat("D:    Deterministic given same input data + temperature\n")
cat("      Should match exactly (< 0.01 log10 difference)\n\n")

plan(sequential)
cat("Comparison complete.\n")
