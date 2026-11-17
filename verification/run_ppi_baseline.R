# Verification baseline: PPI pathway concentration distributions
# Runs BCLc + D + nogrowth from PPI with fixed seed on the full pool data
# Saves distributional summaries (quantiles per day per pathway) for comparison

set.seed(42)

library(dplyr)
library(tidyr)
library(tibble)
library(purrr)
library(deSolve)
library(lamW)
library(formula.tools)
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
ppi_dir <- file.path(script_dir, "..", "PPI_Digital-Interface")
setwd(ppi_dir)
cat("Working directory:", getwd(), "\n")

source("utils/model_helpers.R")
source("config/default_parameters.R")
source("utils/helpers.R")

# Load input data
ModelData_BCLc_input <- read.csv("input_data/ModelData_BCLc_input.csv")
ModelData_D_input <- read.csv("input_data/ModelData_D_input.csv")
cat("BCLc pool:", nrow(ModelData_BCLc_input), "rows\n")
cat("D pool:", nrow(ModelData_D_input), "rows\n")

# Load baseline temperature profiles
load_profiles <- function(profile_paths) {
  profiles <- list()
  for (stage in names(profile_paths)) {
    path <- profile_paths[[stage]]
    if (!is.null(path) && file.exists(path)) {
      raw <- read.csv(path, stringsAsFactors = FALSE)
      time_days <- parse_time_to_days(raw$time)
      time_days <- time_days - min(time_days, na.rm = TRUE)
      profiles[[stage]] <- data.frame(time_days = time_days,
                                       temperature = as.numeric(raw$temperature))
    }
  }
  profiles
}

temp_profiles <- load_profiles(default_profile_paths)

# Shared constants
stage_order <- c("processing_facility", "transportation_facility_to_retail",
                 "retail", "transportation_retail_to_home", "consumer")
stage_to_cols <- list(
  processing_facility = list(temp = "T_F", time = "t_F"),
  transportation_facility_to_retail = list(temp = "T_T", time = "t_T"),
  retail = list(temp = "T_S", time = "t_S"),
  transportation_retail_to_home = list(temp = "T_T2", time = "t_T2"),
  consumer = list(temp = "T_H", time = "t_H")
)

# simulate_growth_row (from run_model.R lines 6-57)
simulate_growth_row <- function(row_data, t_H_total) {
  dur <- c(row_data$t_F[1], row_data$t_T[1], row_data$t_S[1],
           row_data$t_T2[1], row_data$t_H[1])
  rate <- c(row_data$newGR_F[1], row_data$newGR_T[1], row_data$newGR_S[1],
            row_data$newGR_T2[1], row_data$newGR_H[1])
  N0 <- row_data$log10N0[1]
  Nmax <- row_data$log10Nmax[1]
  days <- 0:round(t_H_total)
  n_days <- length(days)
  start <- c(0, cumsum(dur)[-length(dur)])
  end <- cumsum(dur)
  time_in_stage <- function(t, start, end) pmax(0, pmin(t, end) - start)
  N_t <- function(t_vec, N0, rate, start, end, Nmax) {
    incr <- sapply(t_vec, function(t) sum(rate * time_in_stage(t, start, end)))
    pmin(N0 + incr, Nmax)
  }
  result_df <- data.frame(Day = days, predConc = N_t(days, N0, rate, start, end, Nmax))
  for (col_name in names(row_data)) {
    if (!col_name %in% c("newGR_F", "newGR_T", "newGR_S", "newGR_T2", "newGR_H"))
      result_df[[col_name]] <- rep(row_data[[col_name]][1], n_days)
  }
  result_df
}

# build_env_conditions (from run_model.R lines 375-407)
build_env_conditions <- function(i, ModelData_D, temp_profiles, stage_order, stage_to_cols) {
  time_vec <- numeric(0); temp_vec <- numeric(0)
  cumulative_time <- 0; epsilon <- 1e-5
  for (idx in seq_along(stage_order)) {
    stage <- stage_order[idx]; cols <- stage_to_cols[[stage]]
    if (!is.null(temp_profiles[[stage]])) {
      profile <- temp_profiles[[stage]]
      start_time <- if (idx > 1) cumulative_time + epsilon else cumulative_time
      time_vec <- c(time_vec, profile$time_days + start_time)
      temp_vec <- c(temp_vec, profile$temperature)
      stage_duration <- max(profile$time_days)
    } else {
      stage_temp <- ModelData_D[[cols$temp]][i]
      stage_dur <- ModelData_D[[cols$time]][i]
      start_time <- if (idx > 1) cumulative_time + epsilon else cumulative_time
      time_vec <- c(time_vec, start_time, start_time + stage_dur)
      temp_vec <- c(temp_vec, stage_temp, stage_temp)
      stage_duration <- stage_dur
    }
    cumulative_time <- cumulative_time + stage_duration
  }
  tibble(time = time_vec, temperature = temp_vec)
}

t_H <- 35

# Apply baseline profile overrides
updated_data_bclc <- ModelData_BCLc_input
updated_data_d <- ModelData_D_input
for (stage in stage_order) {
  if (!is.null(temp_profiles[[stage]])) {
    cols <- stage_to_cols[[stage]]
    profile_mean <- mean(temp_profiles[[stage]]$temperature)
    profile_duration <- max(temp_profiles[[stage]]$time_days)
    if (cols$temp %in% names(updated_data_bclc)) {
      updated_data_bclc[[cols$temp]] <- rep(profile_mean, nrow(updated_data_bclc))
      updated_data_bclc[[cols$time]] <- rep(profile_duration, nrow(updated_data_bclc))
    }
    if (cols$temp %in% names(updated_data_d)) {
      updated_data_d[[cols$temp]] <- rep(profile_mean, nrow(updated_data_d))
      updated_data_d[[cols$time]] <- rep(profile_duration, nrow(updated_data_d))
    }
  }
}

# Separate no-growth
ModelData_nogrowth <- updated_data_bclc %>%
  filter(Growth_category == "A" | postpastcontainer < 1)
updated_data_bclc <- updated_data_bclc %>%
  filter(postpastcontainer >= 1, Growth_category != "A")

cat("Pathway counts: nogrowth =", nrow(ModelData_nogrowth),
    ", BCLc =", nrow(updated_data_bclc),
    ", D =", nrow(updated_data_d), "\n")

# Save pathway distribution
pathway_dist <- data.frame(
  pathway = c("nogrowth", "medium_growth", "high_growth"),
  n = c(nrow(ModelData_nogrowth), nrow(updated_data_bclc), nrow(updated_data_d))
)
pathway_dist$proportion <- pathway_dist$n / sum(pathway_dist$n)

# --- No-growth: trivial ---
nogrowth_dist <- data.frame()
if (nrow(ModelData_nogrowth) > 0) {
  nogrowth_dist <- data.frame(
    pathway = "nogrowth",
    day = 0,
    n = nrow(ModelData_nogrowth),
    mean = mean(ModelData_nogrowth$log10N0, na.rm = TRUE),
    sd = sd(ModelData_nogrowth$log10N0, na.rm = TRUE),
    P5 = quantile(ModelData_nogrowth$log10N0, 0.05, na.rm = TRUE),
    P25 = quantile(ModelData_nogrowth$log10N0, 0.25, na.rm = TRUE),
    median = median(ModelData_nogrowth$log10N0, na.rm = TRUE),
    P75 = quantile(ModelData_nogrowth$log10N0, 0.75, na.rm = TRUE),
    P95 = quantile(ModelData_nogrowth$log10N0, 0.95, na.rm = TRUE)
  )
  cat("\nNo-growth distribution (constant):\n")
  print(nogrowth_dist)
}

# --- BCLc pathway ---
cat("\nRunning BCLc pathway...\n")
ModelData_BCLc <- updated_data_bclc %>%
  mutate(newGR_F = muAtNewTemp(T_F, growthrate),
         newGR_T = muAtNewTemp(T_T, growthrate),
         newGR_S = muAtNewTemp(T_S, growthrate),
         newGR_T2 = muAtNewTemp(T_T2, growthrate),
         newGR_H = muAtNewTemp(T_H, growthrate))

results_list <- future_map(1:nrow(ModelData_BCLc),
                           ~ simulate_growth_row(ModelData_BCLc[.x, ], t_H))
ModelData_BCLc_result <- bind_rows(results_list)

bclc_dist <- ModelData_BCLc_result %>%
  group_by(Day) %>%
  summarise(
    pathway = "medium_growth",
    n = n(),
    mean = mean(predConc, na.rm = TRUE),
    sd = sd(predConc, na.rm = TRUE),
    P5 = quantile(predConc, 0.05, na.rm = TRUE),
    P25 = quantile(predConc, 0.25, na.rm = TRUE),
    median = median(predConc, na.rm = TRUE),
    P75 = quantile(predConc, 0.75, na.rm = TRUE),
    P95 = quantile(predConc, 0.95, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  rename(day = Day)

cat("\nBCLc distribution at key days:\n")
print(bclc_dist %>% filter(day %in% c(7, 14, 21, 28, 35)))

# --- D pathway ---
cat("\nRunning D pathway...\n")
ModelData_D <- updated_data_d
my_times <- seq(0, t_H)

run_simulation <- function(i) {
  my_primary <- list(mu_opt = ModelData_D$mu_opt[i], Nmax = ModelData_D$Nmax[i],
                     N0 = ModelData_D$N0[i], Q0 = ModelData_D$Q0[i])
  sec_temperature <- list(model = "reducedRatkowsky",
                          xmin = ModelData_D$Tmin[i], b = ModelData_D$b[i],
                          xopt = ModelData_D$Topt[i])
  my_secondary <- list(temperature = sec_temperature)
  growth <- predict_dynamic_growth(
    times = my_times,
    env_conditions = build_env_conditions(i, ModelData_D, temp_profiles, stage_order, stage_to_cols),
    my_primary, my_secondary
  )
  growth$simulation
}

all_simulations <- future_map(1:nrow(ModelData_D), run_simulation)
row_run <- t_H + 1
all_simulations_fixed <- map(all_simulations, ~ fix_simulation(.x, row_run))
all_simulations_fixed <- map(all_simulations_fixed, function(sim) {
  if (nrow(sim) != row_run) {
    if (nrow(sim) > row_run) sim <- sim[1:row_run, ]
    else {
      last_row <- sim[nrow(sim), ]
      while (nrow(sim) < row_run) {
        new_row <- last_row; new_row$time <- nrow(sim)
        sim <- bind_rows(sim, new_row)
      }
      sim <- sim[1:row_run, ]
    }
  }
  sim
})

final_conc <- do.call(rbind, all_simulations_fixed)
original_nrows <- nrow(updated_data_d)
Day <- rep(0:t_H, times = original_nrows)

d_result <- data.frame(day = Day, logN = final_conc$logN)

d_dist <- d_result %>%
  group_by(day) %>%
  summarise(
    pathway = "high_growth",
    n = n(),
    mean = mean(logN, na.rm = TRUE),
    sd = sd(logN, na.rm = TRUE),
    P5 = quantile(logN, 0.05, na.rm = TRUE),
    P25 = quantile(logN, 0.25, na.rm = TRUE),
    median = median(logN, na.rm = TRUE),
    P75 = quantile(logN, 0.75, na.rm = TRUE),
    P95 = quantile(logN, 0.95, na.rm = TRUE),
    .groups = "drop"
  )

cat("\nD pathway distribution at key days:\n")
print(d_dist %>% filter(day %in% c(7, 14, 21, 28, 35)))

# --- Save all distributions ---
output_dir <- file.path(script_dir)
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

all_distributions <- bind_rows(nogrowth_dist, bclc_dist, d_dist)
write.csv(all_distributions, file.path(output_dir, "baseline_ppi_distributions.csv"), row.names = FALSE)
write.csv(pathway_dist, file.path(output_dir, "baseline_ppi_pathway_counts.csv"), row.names = FALSE)

cat("\nSaved to verification/:\n")
cat("  baseline_ppi_distributions.csv (quantiles per pathway per day)\n")
cat("  baseline_ppi_pathway_counts.csv (pathway proportions)\n")

plan(sequential)
