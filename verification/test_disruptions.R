# verification/test_disruptions.R
# Run from milk-spoilage-model/: Rscript ../verification/test_disruptions.R

library(dplyr)
source("utils/temperature.R")
source("scenarios/disruptions.R")
source("config.R")

# --- temp_shift ---
temp_profiles <- list(
  retail = data.frame(time_days = c(0, 1, 2), temperature = c(6.5, 6.5, 6.5))
)
result_shift <- apply_single_disruption(
  config, temp_profiles, "retail",
  list(type = "temp_shift", temp_delta = 3))
stopifnot(result_shift$config$temperature_stages$retail$mean ==
          config$temperature_stages$retail$mean + 3)
stopifnot(all(result_shift$temp_profiles$retail$temperature == 9.5))
cat("PASS: temp_shift shifts static mean and dynamic profile\n")

# --- temp_spike ---
# Use a stage that has a dynamic profile for testing
temp_profiles_spike <- list(
  processing_facility = data.frame(time_days = c(0, 0.05, 0.1), temperature = c(1.7, 1.7, 1.7))
)
result_spike <- apply_single_disruption(
  config, temp_profiles_spike, "processing_facility",
  list(type = "temp_spike", temp = 25, duration = 0.125))
spike_cfg <- result_spike$config$temperature_stages$processing_facility
stopifnot(!is.null(spike_cfg$spike))
stopifnot(spike_cfg$spike$temp == 25)
stopifnot(spike_cfg$spike$duration == 0.125)
prof <- result_spike$temp_profiles$processing_facility
stopifnot(tail(prof$temperature, 1) == 25)
stopifnot(spike_cfg$duration == config$temperature_stages$processing_facility$duration + 0.125)
cat("PASS: temp_spike stores params and appends spike segment\n")

# --- delay ---
result_delay <- apply_single_disruption(
  config, temp_profiles, "retail",
  list(type = "delay", duration_delta = 0.25, temp = 15))
stopifnot(result_delay$config$temperature_stages$retail$duration ==
          config$temperature_stages$retail$duration + 0.25)
prof_delay <- result_delay$temp_profiles$retail
stopifnot(tail(prof_delay$temperature, 1) == 15)
cat("PASS: delay extends duration and appends segment\n")

# --- a non-positive appended duration is refused ---
# A negative duration landed the segment's closing row BEFORE its opening row, and
# nothing sorts afterwards, so the two integrators read the same stored rows
# differently. The full account and the measurements are on append_profile_segment()
# in utils/temperature.R; S2.15 asserts it through run_model(). See issue #52.
#
# The trigger is the SIGN of the delta, not the resulting duration, which is why
# #51's guard does not cover it: -1e-9 is enough, on a stage whose duration never
# moves.
for (delta in c(-0.5, -1e-9)) {
  err_delay <- try(apply_single_disruption(config, list(),
    "transportation_retail_to_home",
    list(type = "delay", temp = 20, duration_delta = delta)), silent = TRUE)
  stopifnot(inherits(err_delay, "try-error"))
  stopifnot(grepl("must be positive", err_delay))
}
cat("PASS: a negative duration_delta on delay is an error\n")

# temp_spike reaches the same append by a different key name (#36), so the guard
# has to hold there too. Checked on a stage that HAS a profile, to pin that the
# defect is not about synthesised static-stage profiles.
err_spike <- try(apply_single_disruption(config, temp_profiles, "retail",
  list(type = "temp_spike", temp = 25, duration = -0.5)), silent = TRUE)
stopifnot(inherits(err_spike, "try-error"))
stopifnot(grepl("must be positive", err_spike))
cat("PASS: a negative duration on temp_spike is an error\n")

# Zero is refused for the same reason a non-positive stage duration is (#51): the
# segment would carry no extent, so the appended temperature is stored and never
# integrated -- a request silently doing nothing.
err_zero <- try(apply_single_disruption(config, list(),
  "transportation_retail_to_home",
  list(type = "delay", temp = 20, duration_delta = 0)), silent = TRUE)
stopifnot(inherits(err_zero, "try-error"))
cat("PASS: a zero-length appended segment is an error\n")

# Rejecting the sign is not enough on its own. The offset placing the opening row was
# a flat 1e-5 d, so any 0 < duration < 1e-5 put the closing row FIRST and rebuilt the
# same malformed profile from a value the guard accepts. The offset is now bounded by
# the segment's own duration. Moves no prediction -- the swapped rows carry the same
# temperature, so both readers read one 0.04001 d stage -- so this asserts the order
# directly. Raised as a P2 on PR #55.
for (tiny in c(1e-6, 1e-9)) {
  sub_eps <- apply_single_disruption(config, list(),
    "transportation_retail_to_home",
    list(type = "delay", temp = 20, duration_delta = tiny))
  prof_sub <- sub_eps$temp_profiles$transportation_retail_to_home
  # strictly = TRUE, because the plain form calls a TIE sorted and a tie is exactly
  # the other half of this defect.
  stopifnot(!is.unsorted(prof_sub$time_days, strictly = TRUE))
}
cat("PASS: a sub-epsilon positive duration keeps the profile in timestamp order\n")

# Halving alone does not survive the addition. Against the shipped start of 0.04,
# duration 1e-17 puts both rows on the SAME double and 1e-18 collapses both back onto
# start, which emits the duplicate timestamps approxfun() averages. Refused rather
# than nudged, because there is no representable interior to nudge into.
for (absorbed in c(1e-17, 1e-18, 5e-324)) {
  err_abs <- try(apply_single_disruption(config, list(),
    "transportation_retail_to_home",
    list(type = "delay", temp = 20, duration_delta = absorbed)), silent = TRUE)
  stopifnot(inherits(err_abs, "try-error"))
  stopifnot(grepl("distinct timestamps", err_abs))
}
cat("PASS: a duration absorbed by the addition is an error, not a tie\n")

# The bound must not disturb any duration a user can actually reach: at 2e-5 d and
# above the flat 1e-5 d epsilon still applies, which is what keeps S1.5 and
# normalise_profile() agreeing on one repo-wide epsilon.
full_eps <- append_profile_segment(
  data.frame(time_days = c(0, 0.04), temperature = c(8.5, 8.5)), 20, 2, "retail")
stopifnot(abs(full_eps$time_days[3] - 0.04001) < 1e-12)
cat("PASS: a normal duration keeps the flat 1e-5 d epsilon\n")

# A delay sent the wrong key (`duration`) reaches the append with a NULL and now dies
# on `NULL <= 0` -- obscure, but loud, where before it ran silently and wrote
# numeric(0) as the stage's duration. Pinned only as "errors", not on the message,
# because the message is incidental and #36 owns the real fix. The mirror case is
# deliberately NOT pinned: R's `$` partial-matches, so a temp_spike sent
# `duration_delta` still applies the spike silently, and a test asserting the pair
# behaves alike would be asserting something false.
err_key <- try(apply_single_disruption(config, list(),
  "transportation_retail_to_home",
  list(type = "delay", temp = 20, duration = 0.5)), silent = TRUE)
stopifnot(inherits(err_key, "try-error"))
cat("PASS: a delay sent the wrong key errors instead of running silently\n")

# --- profile_csv ---
test_csv <- tempfile(fileext = ".csv")
write.csv(data.frame(
  time = c("2026-01-01 00:00:00", "2026-01-01 06:00:00", "2026-01-01 12:00:00"),
  temperature = c(10, 15, 20)), test_csv, row.names = FALSE)
result_csv <- apply_single_disruption(
  config, temp_profiles, "retail",
  list(type = "profile_csv", path = test_csv))
stopifnot(result_csv$config$temperature_stages$retail$mean == mean(c(10, 15, 20)))
stopifnot(abs(result_csv$config$temperature_stages$retail$sd - sd(c(10, 15, 20))) < 1e-10)
stopifnot(nrow(result_csv$temp_profiles$retail) == 3)
stopifnot(all(result_csv$temp_profiles$retail$temperature == c(10, 15, 20)))
cat("PASS: profile_csv replaces stage with CSV data\n")
file.remove(test_csv)

# --- apply_disruptions (unified) ---
result_multi <- apply_disruptions(
  config, temp_profiles,
  list(retail = list(type = "temp_shift", temp_delta = 2)))
stopifnot(result_multi$config$temperature_stages$retail$mean ==
          config$temperature_stages$retail$mean + 2)
stopifnot(length(result_multi$applied) == 1)
cat("PASS: apply_disruptions processes single disruption\n")

result_multi2 <- apply_disruptions(
  config, temp_profiles,
  list(retail = list(type = "temp_shift", temp_delta = 2),
       consumer = list(type = "temp_shift", temp_delta = 1)))
stopifnot(result_multi2$config$temperature_stages$retail$mean ==
          config$temperature_stages$retail$mean + 2)
stopifnot(result_multi2$config$temperature_stages$consumer$mean ==
          config$temperature_stages$consumer$mean + 1)
cat("PASS: apply_disruptions processes multiple disruptions\n")

result_none <- apply_disruptions(config, temp_profiles, list())
stopifnot(identical(result_none$config$temperature_stages$retail$mean,
                    config$temperature_stages$retail$mean))
cat("PASS: empty disruptions is no-op\n")

cat("\nAll disruption tests passed.\n")
