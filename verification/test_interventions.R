# verification/test_interventions.R
# Run from milk-spoilage-model/: Rscript ../verification/test_interventions.R

library(dplyr)
# apply_stage_temp_overrides() calls resize_profile(), and stage_growth_integral()
# calls muAtNewTemp(), so interventions.R alone is not enough to load. Since 9ab2066
# added the resize_profile() call, every check below it died on "could not find
# function" -- this file is not one of the three suites CLAUDE.md lists, so nothing
# reported it.
source("utils/growth_models.R")
source("utils/temperature.R")
source("scenarios/interventions.R")

# --- Category A: Spore reduction ---
stopifnot(get_spore_log_reduction("microfiltration") == 2.2)
stopifnot(get_spore_log_reduction("bactofugation_single") == 1.4)
stopifnot(get_spore_log_reduction("bactofugation_double") == 2.0)
stopifnot(get_spore_log_reduction("none") == 0)
cat("PASS: spore reduction presets correct\n")

# Each fixture carries one sporeformer and one non-sporeformer. The reduction must
# move the first row and leave the second alone: microfiltration and bactofugation
# act on spores, not on vegetative cells (D12).
SPORE_GENERA <- c("Bacillus", "Paenibacillus")
bclc_sample <- data.frame(Genus = c("Bacillus", "Microbacterium"),
                          log10N0 = c(2.0, 3.0), N0 = c(100, 1000))
d_sample <- data.frame(Genus = c("Paenibacillus", "Enterococcus"),
                       log10N0 = c(1.5, 2.5), N0 = c(10^1.5, 10^2.5))
bclc_out <- apply_spore_reduction(bclc_sample, reduction_log = 2.2, SPORE_GENERA)
d_out <- apply_spore_reduction(d_sample, reduction_log = 2.2, SPORE_GENERA)
stopifnot(all(abs(bclc_out$log10N0 - c(-0.2, 3.0)) < 1e-10))
stopifnot(all(abs(bclc_out$N0 - c(10^-0.2, 1000)) < 1e-6))
stopifnot(all(abs(d_out$log10N0 - c(-0.7, 2.5)) < 1e-10))
cat("PASS: apply_spore_reduction reduces sporeformers only\n")

bclc_noop <- apply_spore_reduction(bclc_sample, reduction_log = 0, SPORE_GENERA)
stopifnot(identical(bclc_noop$log10N0, bclc_sample$log10N0))
cat("PASS: zero reduction is no-op\n")

# A pool without a Genus column must fail loudly rather than reduce everything.
no_genus <- data.frame(log10N0 = c(2.0, 3.0), N0 = c(100, 1000))
stopifnot(inherits(try(apply_spore_reduction(no_genus, 2.2, SPORE_GENERA),
                       silent = TRUE), "try-error"))
cat("PASS: a missing Genus column is an error, not a silent whole-pool reduction\n")

# And a user_config predating spore_forming_genera must fail loudly too. NULL would
# otherwise make `Genus %in% NULL` false for every row, so the run would report the
# intervention as applied while reducing nothing.
for (missing in list(NULL, character(0))) {
  stopifnot(inherits(try(apply_spore_reduction(bclc_sample, 2.2, missing),
                         silent = TRUE), "try-error"))
}
cat("PASS: a missing spore_forming_genera is an error, not a silent no-op\n")

# --- Category B: PPC controls ---
source("config.R")
ppc_ST_freq <- read.csv("input_data/ppc_st_frequency.csv")

result_b <- apply_ppc_interventions(config, ppc_ST_freq, list(ppc_frequency_factor = 0.5))
stopifnot(result_b$config$P_ppc_min == config$P_ppc_min * 0.5)
stopifnot(result_b$config$P_ppc_max == config$P_ppc_max * 0.5)
cat("PASS: ppc_frequency_factor halves P_ppc range\n")

result_b2 <- apply_ppc_interventions(config, ppc_ST_freq, list(ppc_initial_reduction_log = 1))
stopifnot(result_b2$config$mean_ppc_N0 == config$mean_ppc_N0 - 1)
cat("PASS: ppc_initial_reduction_log subtracts from mean_ppc_N0\n")

result_b3 <- apply_ppc_interventions(config, ppc_ST_freq, list(ppc_remove_st = c("100")))
stopifnot(!"100" %in% result_b3$ppc_ST_freq$ClosestST)
stopifnot(nrow(result_b3$ppc_ST_freq) < nrow(ppc_ST_freq))
cat("PASS: ppc_remove_st filters ST frequency table\n")

result_b4 <- apply_ppc_interventions(config, ppc_ST_freq, list())
stopifnot(identical(result_b4$config$P_ppc_min, config$P_ppc_min))
cat("PASS: empty PPC interventions is no-op\n")

# --- Category C: Stage temperature overrides ---
temp_profiles <- list(
  consumer = data.frame(time_days = c(0, 1, 2), temperature = c(6.5, 6.5, 6.5))
)

result_c <- apply_stage_temp_overrides(
  config, temp_profiles, list(consumer = list(temp_delta = -1)))
stopifnot(result_c$config$temperature_stages$consumer$mean == config$temperature_stages$consumer$mean - 1)
stopifnot(all(result_c$temp_profiles$consumer$temperature == c(5.5, 5.5, 5.5)))
cat("PASS: temp_delta shifts mean and profile\n")

result_c2 <- apply_stage_temp_overrides(
  config, temp_profiles, list(consumer = list(temp_mean = 1.8, temp_sd = 0.5)))
stopifnot(result_c2$config$temperature_stages$consumer$mean == 1.8)
stopifnot(result_c2$config$temperature_stages$consumer$sd == 0.5)
stopifnot(all(result_c2$temp_profiles$consumer$temperature == 1.8))
cat("PASS: temp_mean replaces mean and flattens profile\n")

temp_profiles_high <- list(
  consumer = data.frame(time_days = c(0, 1, 2), temperature = c(4.0, 8.0, 10.0))
)
result_c3 <- apply_stage_temp_overrides(
  config, temp_profiles_high, list(consumer = list(temp_max = 6)))
stopifnot(all(result_c3$temp_profiles$consumer$temperature == c(4.0, 6.0, 6.0)))
stopifnot(result_c3$config$temperature_stages$consumer$temp_max == 6)
cat("PASS: temp_max clamps profile and stores for static clamping\n")

result_c4 <- apply_stage_temp_overrides(
  config, temp_profiles, list(consumer = list(duration_delta = 2)))
stopifnot(result_c4$config$temperature_stages$consumer$duration ==
          config$temperature_stages$consumer$duration + 2)
cat("PASS: duration_delta extends stage duration\n")

# A static stage never reached resize_profile()'s guard, so a duration_delta at or
# past its whole duration wrote a non-positive one and the run proceeded.
# transportation_retail_to_home is the shipped stage with no measured profile and
# the shortest duration (0.04 d), so it is the one this bites: -0.04 wrote exactly
# 0 and -5 wrote -4.96. pre_consumer_days sums the four pre-consumer durations, so
# it took the value straight through and reported a window shorter than its own
# stages. See issue #51.
for (delta in c(-0.04, -5)) {
  err <- try(apply_stage_temp_overrides(config, list(),
    list(transportation_retail_to_home = list(duration_delta = delta))),
    silent = TRUE)
  stopifnot(inherits(err, "try-error"))
  stopifnot(grepl("must stay positive", err))
}
cat("PASS: a non-positive duration on a STATIC stage is an error\n")

# The guard must reject only a non-positive result, so a shortening that leaves the
# stage positive still applies -- to the config and to the profile alike.
result_c5 <- apply_stage_temp_overrides(
  config, temp_profiles, list(consumer = list(duration_delta = -1)))
stopifnot(abs(result_c5$config$temperature_stages$consumer$duration -
              (config$temperature_stages$consumer$duration - 1)) < 1e-10)
stopifnot(max(result_c5$temp_profiles$consumer$time_days) == 1)
cat("PASS: duration_delta shortens a stage that stays positive\n")

# resize_profile() keeps its own guard as defence in depth. It measures the
# profile's span, not the configured duration, so it still fires on a delta the
# check above lets through: the consumer stage is configured for 27.9583 d and this
# fixture profile spans 2 d.
err_dyn <- try(apply_stage_temp_overrides(
  config, temp_profiles, list(consumer = list(duration_delta = -3))), silent = TRUE)
stopifnot(inherits(err_dyn, "try-error"))
stopifnot(grepl("must stay positive", err_dyn))
cat("PASS: resize_profile still guards a profile shorter than its configured stage\n")

# Through the unified entry point too, in the shape the API actually sends -- the
# checks above call apply_stage_temp_overrides() directly, which is one delegation
# short of the path a request travels.
err_unified <- try(apply_interventions(config, list(), ppc_ST_freq,
  list(stage_temp_overrides = list(
    transportation_retail_to_home = list(duration_delta = -0.04)))), silent = TRUE)
stopifnot(inherits(err_unified, "try-error"))
stopifnot(grepl("must stay positive", err_unified))
cat("PASS: the guard holds through apply_interventions()\n")

tryCatch({
  apply_stage_temp_overrides(config, temp_profiles, list(nonexistent = list(temp_delta = -1)))
  stop("Should have errored")
}, error = function(e) {
  stopifnot(grepl("Unknown stage", e$message))
  cat("PASS: unknown stage produces error\n")
})

# --- Unified apply_interventions ---
ppc_ST_freq_full <- read.csv("input_data/ppc_st_frequency.csv")
temp_profiles_full <- list(
  consumer = data.frame(time_days = c(0, 1), temperature = c(6.5, 6.5))
)

result_all <- apply_interventions(
  config, temp_profiles_full, ppc_ST_freq_full,
  list(spore_reduction = "microfiltration", ppc_frequency_factor = 0.5,
       ppc_initial_reduction_log = 1,
       stage_temp_overrides = list(consumer = list(temp_delta = -1))))
stopifnot(result_all$spore_log_reduction == 2.2)
stopifnot(result_all$config$P_ppc_min == config$P_ppc_min * 0.5)
stopifnot(result_all$config$mean_ppc_N0 == config$mean_ppc_N0 - 1)
stopifnot(all(result_all$temp_profiles$consumer$temperature == 5.5))
cat("PASS: unified apply_interventions() applies all categories\n")

result_empty <- apply_interventions(config, temp_profiles_full, ppc_ST_freq_full, list())
stopifnot(identical(result_empty$config$P_ppc_min, config$P_ppc_min))
stopifnot(result_empty$spore_log_reduction == 0)
cat("PASS: empty interventions is no-op\n")

cat("\nAll intervention tests passed.\n")
