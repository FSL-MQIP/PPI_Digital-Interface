# Generate PPC-only intervention reference outputs
# Run from milk-spoilage-model/: Rscript ../verification/generate_intervention_baselines.R

library(dplyr)
library(tidyr)
library(tibble)
library(purrr)
library(deSolve)
library(lamW)
library(formula.tools)
library(truncnorm)
library(furrr)
library(future)

plan(multisession, workers = 4)

source("config.R")
source("utils/growth_models.R")
source("utils/temperature.R")
source("pathways/ppc_pathway.R")

# --- Load PPC growth parameters (same as run_model.R) ---
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

temp_profiles <- load_baseline_profiles(config$temperature_stages)

# --- Helper: generate PPC containers and run pathway ---
run_ppc_scenario <- function(label, cfg, gp, st_freq, tp) {
  set.seed(42)
  n_sim <- cfg$n_lots
  n_unit <- cfg$n_units

  lot_id <- rep(seq(1, n_sim), each = n_unit)
  unit_id <- rep(seq(1, n_unit), times = n_sim)
  containers <- data.frame(lot_id, unit_id)

  for (stage in cfg$stage_order) {
    stage_cfg <- cfg$temperature_stages[[stage]]
    cols <- cfg$stage_to_cols[[stage]]
    n <- n_sim * n_unit
    if (stage_cfg$sd > 0) {
      containers[[cols$temp]] <- rnorm(n, mean = stage_cfg$mean, sd = stage_cfg$sd)
    } else {
      containers[[cols$temp]] <- rep(stage_cfg$mean, n)
    }
    duration_sd <- if (!is.null(stage_cfg$duration_sd)) stage_cfg$duration_sd else 0
    if (duration_sd > 0) {
      containers[[cols$time]] <- pmax(rnorm(n, mean = stage_cfg$duration, sd = duration_sd), 0.001)
    } else {
      containers[[cols$time]] <- rep(stage_cfg$duration, n)
    }
  }

  containers <- containers %>%
    group_by(lot_id) %>%
    mutate(P_ppc = runif(1, cfg$P_ppc_min, cfg$P_ppc_max)) %>%
    ungroup()

  # All containers are PPC for this test
  containers$container_type <- "PPC"

  cat(paste0("\n=== ", label, " ===\n"))
  result <- run_ppc_pathway(containers, cfg, gp, st_freq, tp)

  # Calculate spoilage stats (PPC only)
  result$N <- 10^result$log10_concentration
  daily <- result %>%
    group_by(lot_id, unit_id, day) %>%
    summarise(total_N = sum(N, na.rm = TRUE), .groups = "drop") %>%
    mutate(log10N = ifelse(total_N > 0, log10(total_N), -2),
           spoiled = log10N > cfg$spoilage_threshold)

  stats_list <- list()
  for (d in cfg$output_days) {
    dd <- daily %>% filter(day == d)
    if (nrow(dd) == 0) next
    lot_sp <- dd %>%
      group_by(lot_id) %>%
      summarise(pct = 100 * sum(spoiled) / n(), .groups = "drop")
    stats_list[[length(stats_list) + 1]] <- data.frame(
      day = d,
      median_pct = median(lot_sp$pct),
      mean_pct = mean(lot_sp$pct),
      sd = sd(lot_sp$pct),
      P5 = quantile(lot_sp$pct, 0.05),
      P95 = quantile(lot_sp$pct, 0.95)
    )
  }
  stats <- bind_rows(stats_list)
  cat(paste0(label, ":\n"))
  print(stats)
  stats
}

outdir <- file.path("..", "verification", "scenario_baselines")
dir.create(outdir, recursive = TRUE, showWarnings = FALSE)

# --- 1. PPC Baseline ---
ppc_baseline <- run_ppc_scenario("PPC Baseline", config, growth_parameter_ppc,
                                  ppc_ST_freq, temp_profiles)
write.csv(ppc_baseline, file.path(outdir, "ppc_baseline.csv"), row.names = FALSE)

# --- 2. PPC frequency halved ---
cfg_freq <- config
cfg_freq$P_ppc_min <- config$P_ppc_min * 0.5
cfg_freq$P_ppc_max <- config$P_ppc_max * 0.5
ppc_freq <- run_ppc_scenario("PPC Frequency Halved", cfg_freq, growth_parameter_ppc,
                              ppc_ST_freq, temp_profiles)
write.csv(ppc_freq, file.path(outdir, "ppc_freq_halved.csv"), row.names = FALSE)

# --- 3. PPC initial concentration -1 log ---
cfg_n0_1 <- config
cfg_n0_1$mean_ppc_N0 <- config$mean_ppc_N0 - 1
ppc_n0_1 <- run_ppc_scenario("PPC Initial -1 log", cfg_n0_1, growth_parameter_ppc,
                              ppc_ST_freq, temp_profiles)
write.csv(ppc_n0_1, file.path(outdir, "ppc_init_minus1log.csv"), row.names = FALSE)

# --- 4. PPC initial concentration -3 log ---
cfg_n0_3 <- config
cfg_n0_3$mean_ppc_N0 <- config$mean_ppc_N0 - 3
ppc_n0_3 <- run_ppc_scenario("PPC Initial -3 log", cfg_n0_3, growth_parameter_ppc,
                              ppc_ST_freq, temp_profiles)
write.csv(ppc_n0_3, file.path(outdir, "ppc_init_minus3log.csv"), row.names = FALSE)

# --- 5. Eliminate ST 100 ---
st_freq_no100 <- ppc_ST_freq %>% filter(ClosestST != "100")
ppc_no100 <- run_ppc_scenario("PPC No ST 100", config, growth_parameter_ppc,
                               st_freq_no100, temp_profiles)
write.csv(ppc_no100, file.path(outdir, "ppc_no_st100.csv"), row.names = FALSE)

# --- 6. Eliminate ST 13 and 9 ---
st_freq_no13_9 <- ppc_ST_freq %>% filter(!ClosestST %in% c("13", "9"))
ppc_no13_9 <- run_ppc_scenario("PPC No ST 13 & 9", config, growth_parameter_ppc,
                                st_freq_no13_9, temp_profiles)
write.csv(ppc_no13_9, file.path(outdir, "ppc_no_st13_9.csv"), row.names = FALSE)

plan(sequential)
cat("\nAll PPC intervention baselines written to verification/scenario_baselines/\n")
