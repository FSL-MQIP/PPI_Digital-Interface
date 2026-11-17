# Disruption System
# Modifies config and temperature profiles to model adverse supply chain events.

library(dplyr)

# =============================================================================
# Single disruption handlers
# =============================================================================

# The disruption types, and for each one whether it DISCARDS a temperature
# intervention already applied to the stage. profile_csv overwrites the stage's
# mean, sd, duration and profile below, so nothing the intervention wrote there
# survives; the other three compose on top of it.
#
# One list serves the validation below and conflict_check()'s warning wording,
# so a type cannot exist without an answer to the compose-or-replace question.
# Two lists let a fifth replacing type pass validation and still be reported to
# a processor as composing -- the intervention named as surviving when the run
# had thrown it away.
disruption_replaces_profile_map <- c(
  temp_spike  = FALSE,
  delay       = FALSE,
  temp_shift  = FALSE,
  profile_csv = TRUE
)

disruption_types <- function() names(disruption_replaces_profile_map)

# Errors on an unclassified type rather than returning FALSE. FALSE is the
# correct answer for three of the four, so a silent default is indistinguishable
# from a real one.
disruption_replaces_profile <- function(dtype) {
  if (is.null(dtype) || !dtype %in% disruption_types()) {
    stop(paste0("Cannot say whether disruption type '", dtype, "' replaces or ",
                "composes with a temperature intervention. Add it to ",
                "disruption_replaces_profile_map in scenarios/disruptions.R."))
  }
  unname(disruption_replaces_profile_map[[dtype]])
}

apply_single_disruption <- function(cfg, temp_profiles, stage, disruption) {
  valid_stages <- names(cfg$temperature_stages)
  if (!stage %in% valid_stages) {
    stop(paste0("Unknown stage: '", stage, "'. Valid: ",
                paste(valid_stages, collapse = ", ")))
  }

  dtype <- disruption$type
  if (is.null(dtype) || !dtype %in% disruption_types()) {
    stop(paste0("Unknown disruption type: '", dtype,
                "'. Options: ", paste(disruption_types(), collapse = ", ")))
  }

  stage_cfg <- cfg$temperature_stages[[stage]]

  if (dtype == "temp_shift") {
    cfg$temperature_stages[[stage]]$mean <- stage_cfg$mean + disruption$temp_delta
    if (!is.null(temp_profiles[[stage]])) {
      temp_profiles[[stage]]$temperature <-
        temp_profiles[[stage]]$temperature + disruption$temp_delta
    }

  } else if (dtype == "temp_spike") {
    cfg$temperature_stages[[stage]]$spike <- list(
      temp = disruption$temp, duration = disruption$duration)
    # A static stage has no profile, so the segment below had nowhere to go and the
    # spike temperature was dropped -- only its duration survived, lengthening the
    # stage at its original temperature. Synthesise one first.
    ensured <- ensure_stage_profile(stage, temp_profiles, cfg, duration = stage_cfg$duration)
    cfg <- ensured$config
    temp_profiles <- ensured$temp_profiles

    temp_profiles[[stage]] <- append_profile_segment(
      temp_profiles[[stage]], disruption$temp, disruption$duration, stage)

    cfg$temperature_stages[[stage]]$duration <-
      stage_cfg$duration + disruption$duration

  } else if (dtype == "delay") {
    cfg$temperature_stages[[stage]]$duration <-
      stage_cfg$duration + disruption$duration_delta
    cfg$temperature_stages[[stage]]$delay <- list(
      temp = disruption$temp, duration_delta = disruption$duration_delta)
    # Same as temp_spike: on a static stage the delay temperature had nowhere to
    # live, so the stage simply ran longer at its original temperature.
    ensured <- ensure_stage_profile(stage, temp_profiles, cfg, duration = stage_cfg$duration)
    cfg <- ensured$config
    temp_profiles <- ensured$temp_profiles

    temp_profiles[[stage]] <- append_profile_segment(
      temp_profiles[[stage]], disruption$temp, disruption$duration_delta, stage)

  } else if (dtype == "profile_csv") {
    raw <- read.csv(disruption$path, stringsAsFactors = FALSE)
    # Drop NA rows (some scenario CSVs have pad rows)
    valid <- !is.na(raw$temperature) & raw$temperature != "NA"
    raw <- raw[valid, ]
    temps <- as.numeric(raw$temperature)
    cfg$temperature_stages[[stage]]$mean <- mean(temps, na.rm = TRUE)
    cfg$temperature_stages[[stage]]$sd <- sd(temps, na.rm = TRUE)
    time_col <- if ("time" %in% names(raw)) raw$time else raw$time_days
    time_days <- parse_time_to_days(time_col)
    time_days <- time_days - min(time_days, na.rm = TRUE)
    cfg$temperature_stages[[stage]]$duration <- max(time_days, na.rm = TRUE)
    temp_profiles[[stage]] <- normalise_profile(data.frame(
      time_days = time_days, temperature = temps))
    # Promote, or nothing reads the series the user just supplied.
    # build_env_conditions() and apply_effective_stage_durations() both gate on
    # mode == "dynamic", so on a static stage the profile was stored and ignored:
    # every pathway ran on the CSV's arithmetic mean and duration alone. A user
    # uploading real measurements for the delivery leg got a flat stage at their
    # data's average. Measured on a 0.5 d series peaking at 24.15 C whose mean is
    # the stage's own 8.5 C: the solver saw a flat 8.50 C and lost 26.3% of the
    # stage's growth. Same promotion ensure_stage_profile() performs; see ADR 006.
    cfg$temperature_stages[[stage]]$mode <- "dynamic"
  }

  list(config = cfg, temp_profiles = temp_profiles)
}

# =============================================================================
# Unified entry point
# =============================================================================

apply_disruptions <- function(cfg, temp_profiles, disruptions) {
  if (length(disruptions) == 0) {
    return(list(config = cfg, temp_profiles = temp_profiles, applied = list()))
  }
  applied <- list()
  for (stage in names(disruptions)) {
    result <- apply_single_disruption(cfg, temp_profiles, stage, disruptions[[stage]])
    cfg <- result$config
    temp_profiles <- result$temp_profiles
    applied[[stage]] <- disruptions[[stage]]
  }
  list(config = cfg, temp_profiles = temp_profiles, applied = applied)
}
