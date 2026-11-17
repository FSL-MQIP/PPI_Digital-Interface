# verification/test_resolve.R
# Run from milk-spoilage-model/: Rscript ../verification/test_resolve.R

library(dplyr)
source("config.R")
source("utils/temperature.R")
source("scenarios/interventions.R")
source("scenarios/disruptions.R")
source("scenarios/resolve.R")

# --- conflict_check tests ---

# Test 1: no conflict on different stages
warnings1 <- conflict_check(
  list(stage_temp_overrides = list(consumer = list(temp_delta = -1))),
  list(retail = list(type = "temp_shift", temp_delta = 3)),
  config)
stopifnot(length(warnings1) == 0)
cat("PASS: no conflict on different stages\n")

# Test 2: same-stage conflict, on a disruption that composes.
# The caller repeats this text to the processor, so it has to name what the run
# did. temp_shift ADDS its offset to the already-shifted profile, so the
# intervention is still in effect and the old word "overrides" said otherwise.
warnings2 <- conflict_check(
  list(stage_temp_overrides = list(retail = list(temp_delta = -1))),
  list(retail = list(type = "temp_shift", temp_delta = 3)),
  config)
stopifnot(length(warnings2) == 1)
stopifnot(grepl("retail", warnings2[1]))
stopifnot(grepl("composes", warnings2[1]))
stopifnot(!grepl("[Oo]verrid", warnings2[1]))
cat("PASS: same-stage conflict names composition\n")

# Test 2b: the one disruption type that really does replace the intervention.
# Every preset expands to profile_csv in the bridge, so this is the common path.
warnings2b <- conflict_check(
  list(stage_temp_overrides = list(retail = list(temp_delta = -1))),
  list(retail = list(type = "profile_csv", path = "input_data/whatever.csv")),
  config)
stopifnot(length(warnings2b) == 1)
stopifnot(grepl("retail", warnings2b[1]))
stopifnot(grepl("replaces", warnings2b[1]))
cat("PASS: profile_csv conflict names replacement\n")

# Test 2c: an unclassified type errors rather than defaulting to "composes".
# FALSE is the right answer for three of the four types, so a silent default is
# indistinguishable from a real one -- and it would tell a processor their
# intervention survived a disruption that had thrown it away.
stopifnot(inherits(try(disruption_replaces_profile("teleport"), silent = TRUE),
                   "try-error"))
stopifnot(inherits(try(disruption_replaces_profile(NULL), silent = TRUE),
                   "try-error"))
# The validation and the classification read one list, so they cannot disagree.
stopifnot(setequal(disruption_types(),
                   c("temp_spike", "delay", "temp_shift", "profile_csv")))
stopifnot(disruption_replaces_profile("profile_csv"))
stopifnot(!disruption_replaces_profile("temp_shift"))
cat("PASS: an unclassified disruption type fails loudly\n")

# Test 3: duration overflow
cfg_overflow <- config
cfg_overflow$temperature_stages$consumer$duration <- 50
warnings3 <- conflict_check(list(), list(), cfg_overflow)
stopifnot(any(grepl("exceeds sim_duration", warnings3)))
cat("PASS: duration overflow detected\n")

# --- resolve_scenario tests ---
ppc_ST_freq <- read.csv("input_data/ppc_st_frequency.csv")
temp_profiles <- list(
  consumer = data.frame(time_days = c(0, 1), temperature = c(6.5, 6.5))
)

# Test 4: resolve with both interventions and disruptions
result <- resolve_scenario(
  config, temp_profiles, ppc_ST_freq,
  interventions = list(spore_reduction = "microfiltration", ppc_frequency_factor = 0.5),
  disruptions = list(retail = list(type = "temp_shift", temp_delta = 3)))
stopifnot(result$spore_log_reduction == 2.2)
stopifnot(result$config$P_ppc_min == config$P_ppc_min * 0.5)
stopifnot(result$config$temperature_stages$retail$mean ==
          config$temperature_stages$retail$mean + 3)
stopifnot(is.character(result$warnings))
cat("PASS: resolve_scenario chains interventions then disruptions\n")

# Test 5: resolve with empty lists is no-op
result_empty <- resolve_scenario(config, temp_profiles, ppc_ST_freq, list(), list())
stopifnot(identical(result_empty$config$P_ppc_min, config$P_ppc_min))
stopifnot(result_empty$spore_log_reduction == 0)
cat("PASS: resolve with empty lists is no-op\n")

cat("\nAll resolve tests passed.\n")
