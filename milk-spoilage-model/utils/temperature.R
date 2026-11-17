parse_time_to_days <- function(time_values) {
  if (is.null(time_values) || length(time_values) == 0) {
    return(numeric(0))
  }

  # Convert to character for consistent processing
  time_values <- as.character(time_values)

  # Try to convert to numeric first (if already in days)
  numeric_vals <- suppressWarnings(as.numeric(time_values))
  if (sum(is.na(numeric_vals)) == 0) {
    return(numeric_vals)
  }

  # Try parsing as dates
  # Common date formats to try (ordered by likelihood)
  date_formats <- c(
    "%m/%d/%Y %H:%M",      # MM/DD/YYYY HH:MM (e.g., 12/17/2025 10:00)
    "%m/%d/%Y %H:%M:%S",  # MM/DD/YYYY HH:MM:SS
    "%m/%d/%Y",           # MM/DD/YYYY
    "%Y-%m-%d %H:%M:%S",  # YYYY-MM-DD HH:MM:SS
    "%Y-%m-%d %H:%M",     # YYYY-MM-DD HH:MM
    "%Y-%m-%d",           # YYYY-MM-DD
    "%d/%m/%Y %H:%M:%S",  # DD/MM/YYYY HH:MM:SS
    "%d/%m/%Y %H:%M",     # DD/MM/YYYY HH:MM
    "%d/%m/%Y",           # DD/MM/YYYY
    "%Y/%m/%d %H:%M:%S",  # YYYY/MM/DD HH:MM:SS
    "%Y/%m/%d %H:%M",     # YYYY/MM/DD HH:MM
    "%Y/%m/%d"            # YYYY/MM/DD
  )

  # Try individual formats and use the one that parses the most values
  best_format <- NULL
  best_parsed <- NULL
  best_count <- 0

  # tz = "UTC" because a local timezone has daylight-saving gaps, and a timestamp
  # inside one does not exist locally so it parses as NA. This loop keeps whichever
  # format parses the MOST values, so a single such row demotes the whole column to
  # a coarser format: the consumer profile lost 2026-03-08 02:20:20 (the US
  # spring-forward gap), scored 671 of 672 against date-only's 672, and collapsed
  # from 672 distinct timestamps to 29 whole days. Only differences are ever taken
  # from these values, so the zone is immaterial -- it only has to be gap-free.
  for (fmt in date_formats) {
    try_parse <- suppressWarnings(as.POSIXct(time_values, format = fmt, tz = "UTC"))
    success_count <- sum(!is.na(try_parse))

    if (success_count > best_count) {
      best_count <- success_count
      best_format <- fmt
      best_parsed <- try_parse
    }

    # If we got all values, we're done
    if (success_count == length(time_values)) {
      break
    }
  }

  # If we found a good format, use it
  if (!is.null(best_parsed) && best_count > 0) {
    parsed_dates <- best_parsed
  } else {
    # Try as.POSIXct without format as last resort
    parsed_dates <- suppressWarnings(as.POSIXct(time_values))
  }

  # If we successfully parsed dates (at least some), convert to absolute POSIXct timestamps
  valid_indices <- which(!is.na(parsed_dates))
  if (length(valid_indices) > 0) {
    # Return absolute timestamps in days since epoch (1970-01-01)
    # This preserves the actual time values
    days_since_epoch <- rep(NA, length(time_values))
    days_since_epoch[valid_indices] <- as.numeric(difftime(parsed_dates[valid_indices], as.POSIXct("1970-01-01", tz = "UTC"), units = "days"))
    return(days_since_epoch)
  }

  # If all parsing failed, try one more time with as.Date
  try_date <- suppressWarnings(as.Date(time_values))
  valid_indices <- which(!is.na(try_date))
  if (length(valid_indices) > 0) {
    days_since_epoch <- rep(NA, length(time_values))
    days_since_epoch[valid_indices] <- as.numeric(difftime(try_date[valid_indices], as.Date("1970-01-01"), units = "days"))
    return(days_since_epoch)
  }

  # If all parsing failed, return NA
  return(rep(NA, length(time_values)))
}

# Put a profile into the form both halves of the model read identically: sorted by
# time, with no two rows sharing one timestamp.
#
# A CSV may carry duplicate timestamps, because that is how a recording writes a step
# change -- 4 C at 09:00 and 20 C at 09:00 means "4 until nine, 20 after". The two
# halves disagreed about what that means. approxfun() defaults to ties = mean, so the
# ODE pathways collapsed the tied rows to their average and ramped THROUGH it;
# stage_growth_integral() kept both rows and read the zero-length segment between them
# as a step. Measured on a 12-day consumer CSV carrying one tie: 2.06 log10 apart at
# the worst day and 1.02 at a reported day, with spoilage calls flipping. The stage
# TOTAL was preserved -- day 40 agreed to 0.0000 -- so only a per-day check sees it.
# See issue #21.
#
# The step is the faithful reading, and this repo has already ruled that way:
# append_profile_segment() offsets an appended segment by this same 1e-5 d epsilon for
# exactly this reason, and verify_structure.R S1.5 asserts it. So each repeat of a
# timestamp is nudged FORWARD, and both halves then read the step the recording meant.
#
# The nudge is capped at `max_share` of the gap to the next distinct timestamp, so a
# de-tied group can never reach it. Non-collision alone is too weak a cap: readings one
# second apart are 1.16e-5 d, and a nudge of half that gap smears the step across half a
# sampling interval, which on a 1 s profile put the growth 9.7% off the step the CSV
# means. Holding the whole group inside a thousandth of the gap takes that to 0.019%.
# On any profile sampled coarser than about 10 s the absolute epsilon binds instead and
# nothing changes -- an hourly gap is 0.0417 d, whose thousandth is 4.2e-5, above the
# epsilon -- so this leaves the shipped profiles and the append_profile_segment() parity
# exactly as they were. Dividing by `repeats` keeps the guarantee for a group of any size.
#
# Sorting first is load-bearing rather than tidiness. Duplicates must be adjacent for
# the run detection to find them, and stage_growth_integral() already sorts while
# build_env_conditions() does not -- so an out-of-order CSV was its own divergence
# between the same two halves.
#
# A tie carrying one temperature on both rows is harmless, because the collapsed and
# the step readings coincide; resize_profile() makes one when it extends a stage.
# Nudging it is free: the extra segment is flat at that same temperature.
#
# ACCEPTED GAP, no practical implication. Replacing a zero-length step with a short ramp
# is asymmetric: a hot-to-cold tie reads high, because the small post-step growth does not
# mask the ramp, while cold-to-hot reads low by far less. Worst case is a 25 C -> 0 C tie
# on an hourly-or-sparser profile, where the absolute epsilon binds: 7.9e-6 log10. Even
# 40 C -> 0 C, beyond any real record, is 1.8e-5. Against that, over 5000 container-days
# the closest any container came to the 6 log10 spoilage threshold was 2.1e-4 log10 and
# the median was 2.12, so a shift this size flips 0 calls -- about one container-day per
# 80 runs at the observed density near the threshold, and one flip moves a lot's spoiled
# fraction by 0.01 where the nearest lot-day sat 0.07 from the 25% shelf-life boundary.
# No shipped profile carries a tie, so the error is zero unless a user uploads one.
#
# Shrinking the nudge would remove it and costs the solver nothing -- checked, the ODE is
# indifferent from 1e-5 down to 1e-15, same rows and same runtime. Left alone because the
# quantity is below what the model resolves, and because the binding constraint in the
# worst case is the shared 1e-5 d epsilon that S1.5 and append_profile_segment() establish
# repo-wide, not max_share. Raised as a P2 on PR #22.
normalise_profile <- function(profile, epsilon = 1e-5, max_share = 1e-3) {
  p <- profile[order(profile$time_days), , drop = FALSE]
  rownames(p) <- NULL
  if (nrow(p) < 2 || !anyDuplicated(p$time_days)) return(p)

  runs <- rle(p$time_days)
  ends <- cumsum(runs$lengths)

  for (r in which(runs$lengths > 1L)) {
    repeats <- runs$lengths[r] - 1L
    gap <- if (r < length(runs$values)) runs$values[r + 1L] - runs$values[r] else Inf
    step <- min(epsilon, gap * max_share / repeats)
    p$time_days[(ends[r] - repeats + 1L):ends[r]] <-
      runs$values[r] + step * seq_len(repeats)
  }

  p
}

# Load baseline temperature profiles from CSV files
# Reads paths from temperature_stages config; only loads stages with mode = "dynamic"
# Returns a named list of data frames with columns: time_days, temperature
load_baseline_profiles <- function(temperature_stages) {
  profiles <- list()
  for (stage in names(temperature_stages)) {
    stage_cfg <- temperature_stages[[stage]]
    if (stage_cfg$mode == "dynamic" && !is.null(stage_cfg$path) && file.exists(stage_cfg$path)) {
      raw <- read.csv(stage_cfg$path, stringsAsFactors = FALSE)
      time_days <- parse_time_to_days(raw$time)
      time_days <- time_days - min(time_days, na.rm = TRUE)
      profiles[[stage]] <- normalise_profile(data.frame(
        time_days = time_days,
        temperature = as.numeric(raw$temperature)
      ))
    } else if (stage_cfg$mode == "dynamic" && (is.null(stage_cfg$path) || !file.exists(stage_cfg$path))) {
      warning(paste0("Stage '", stage, "': mode is 'dynamic' but CSV not found — falling back to static"))
    }
  }
  profiles
}

# The growth a profile implies, as a running total: the integral of (T - T0)^2
# from the start of the stage to `u` days into it. Returns that integral as a
# function of u, vectorised.
#
# This is the whole thermal history the Buchanan model needs. muAtNewTemp() is
# exactly quadratic in (T - T0) (utils/growth_models.R:307-313) and the Buchanan
# model without lag is exactly linear in mu, so a container's growth over a stage
# is its own constant times this integral. Feeding the pathway the integral rather
# than one temperature per stage is therefore an evaluation change, not a model
# change: the same equations, fed the real series the ODE pathways already
# integrate. See docs/adr/007-buchanan-integrated-exactly.md.
#
# What it replaces, and why nothing weaker will do. A single scalar per stage
# cannot carry a shape. The scalar that reproduced the stage's growth TOTAL was
# lossless for that total and destroyed the trajectory inside the stage -- and the
# trajectory is the product, since the model reports at days 7/14/21/28/35 and
# derives shelf life from threshold crossings. Measured over random profiles: the
# day-40 endpoint agreed to 0.0000 log10 while a reported day was out by 4.98, and
# 7.1% of spoilage calls flipped, in both directions. Worst is cold-then-hot, where
# one scalar spreads the late heat evenly and growth appears from day 0 that has
# not happened yet. Guarded by verification/test_buchanan_trajectory.R.
#
# The segment integral is exact for the linear interpolation approxfun() applies
# between profile points: the mean of (T - T0)^2 across a segment from offset a to
# offset b is (a^2 + ab + b^2)/3. So this agrees with the ODE pathways by
# construction rather than by discretisation.
#
# Past the recorded span the last temperature is held, which is what
# approxfun(rule = 2) does for the solver. The final stage needs that: it is
# stretched to cover the simulation horizon, and over the stretch the ODE pathways
# hold the profile's final value. The mirror case needs nothing -- a stage running
# PAST the horizon is never evaluated beyond it, because the caller only ever asks
# for the time actually spent in the stage.
#
# Read T0 off muAtNewTemp rather than restating -3.62 here. The two must agree, and
# a silent disagreement would show up only as slightly wrong growth.
stage_growth_integral <- function(profile) {
  p <- profile[order(profile$time_days), , drop = FALSE]
  T0 <- eval(formals(muAtNewTemp)$T0)
  off <- p$temperature - T0

  # A profile with no extent carries one temperature, so its integral is linear.
  if (nrow(p) < 2 || max(p$time_days) - min(p$time_days) <= 0) {
    flat <- mean(off)^2
    return(function(u) flat * pmax(u, 0))
  }

  t <- p$time_days - min(p$time_days)
  dt <- diff(t)
  span <- max(t)
  a <- head(off, -1)
  b <- tail(off, -1)
  # Running integral at each profile point, so a lookup anywhere in the profile
  # costs a search rather than a rebuild.
  cum <- c(0, cumsum((a^2 + a * b + b^2) / 3 * dt))
  held_sq <- off[length(off)]^2

  function(u) {
    u <- pmax(u, 0)
    within <- pmin(u, span)
    i <- pmin(pmax(findInterval(within, t), 1L), length(dt))
    part <- within - t[i]
    # Temperature where the lookup falls, on the same linear interpolation.
    off_u <- off[i] + ifelse(dt[i] > 0, (off[i + 1] - off[i]) * part / dt[i], 0)
    cum[i] + part * (off[i]^2 + off[i] * off_u + off_u^2) / 3 +
      held_sq * pmax(u - span, 0)
  }
}

# The duration a stage actually runs for. A dynamic stage's span comes from its
# profile; a static stage's from config. This is the single source of truth --
# reporting that sums config$temperature_stages[[s]]$duration directly will drift
# from the simulation the moment a profile says something different.
effective_stage_duration <- function(stage, temp_profiles, config) {
  stage_cfg <- config$temperature_stages[[stage]]

  if (stage_cfg$mode == "dynamic" && !is.null(temp_profiles[[stage]])) {
    max(temp_profiles[[stage]]$time_days)
  } else {
    stage_cfg$duration
  }
}

# Append a flat segment to a profile, as temp_spike and delay do.
#
# The segment must start a hair AFTER the profile's last point, never at exactly
# that timestamp. approxfun() defaults to ties = mean, so two rows sharing one
# timestamp collapse to their average and the intended step becomes a linear ramp.
# Measured on a synthesised static-stage profile (0.04 d at 8.5 C, then 2 d at
# 20 C): the ODE saw 14.25 C at the boundary and ramped to 20 C across the whole
# segment, integrating a mean of 17.01 C against the 19.77 C requested. R warns
# "collapsing to unique 'x' values", but from inside future_map workers, so it never
# surfaces.
#
# build_env_conditions() already offsets stage boundaries by an epsilon for this
# reason (see its `start_time` handling); this applies the same idiom to appended
# segments. A tie is harmless when both rows carry the same temperature, which is
# why resize_profile()'s extension was unaffected.
#
# The duration must be positive, and the check lives here rather than at each call
# site because delay and temp_spike are the same operation differing only in key
# name -- duration_delta against duration (#36). A negative one landed the closing
# row BEFORE the opening row, and nothing sorts afterwards, so the two integrators
# read the same stored rows differently: stage_growth_integral() sorts, which moves
# the appended temperature to the FRONT of the stage, while build_env_conditions()
# splices in stored order and takes the span from max(time_days) alone.
#
# Measured on transportation_retail_to_home with duration_delta = -0.5, the rows the
# append stored are (0, 0.04, 0.04001, -0.46). Sorted, the stage spans 0.50001 d and
# opens at 20 C. In stored order it spans 0.04001 d and opens at 8.5 C. Those spans
# are the defect, and they are what this guard prevents.
#
# NO end-to-end figure is quoted for the divergence, deliberately. An earlier draft
# gave "157.84 against 21.39, 7.4x apart", which review correctly rejected: both
# numbers come from stage_growth_integral() on the isolated sorted profile, so they
# are two hypothetical calls to ONE reader rather than a disagreement between the
# two production readers. The real paths differ again -- effective_stage_duration()
# hands the Buchanan side max(time) = 0.04001, while the ODE side receives the
# globally spliced series with the neighbouring stages present. Issue #52 reports
# 26.8x by a method it does not show, and it is not reproduced here.
#
# Left unmeasured on purpose. The guard makes the state unreachable, so a faithful
# end-to-end figure would mean bypassing the fix to characterise a defect that can no
# longer occur. The guard rests on the DIRECTION of the finding -- the two readers
# disagree, and a user reaches that state by mistake -- never on its size. See PR #55.
#
# It is the same PAIR that ADR 007 is about, with the opposite signature, so do not
# call it the ADR 007 class. There the stage TOTAL is preserved while the trajectory
# inside it is destroyed, which is what makes a total-comparing check blind. Here
# the totals themselves diverge, so Seam 3 would see it -- Seam 3 simply never sends
# a negative delta. That is the gap S2.15 closes, and it is why the check belongs in
# verify_structure.R rather than as another row of the Seam 3 matrix.
#
# This is NOT the #51 guard in another place. That one guards the resulting stage
# DURATION; the trigger here is the SIGN of the appended segment, so it fires on a
# stage whose duration never goes near zero -- consumer holds its full 27.9583 d
# under a delta of -1e-9 and the profile still comes back out of order. Either
# guard can fire alone.
#
# Erroring rather than normalising, because normalise_profile() would not rescue
# it: sorting relocates the appended temperature into the MIDDLE of the stage,
# inventing a thermal excursion nobody requested, and a plausible-looking profile
# is worse than an out-of-order one. Erroring rather than reading a negative delay
# as a shortening, because a "delay" that shortens is nonsense and the two
# disruption types share this function.
#
# Zero is refused on the same argument as #51's stage duration: the segment would
# carry no extent, so the requested temperature is stored and never integrated, and
# a disruption that silently does nothing is the failure #51 describes.
#
# A side effect on the wrong-key case (#36), recorded but NOT fixed here. A delay
# sent `duration` reaches this line with a NULL and now dies on `NULL <= 0` --
# "argument is of length zero", obscure but loud, where before it ran SILENTLY:
# `stage_cfg$duration + NULL` wrote numeric(0) as the stage's duration and the
# append produced a zero-extent duplicate row. The mirror case is untouched and
# still silent, because R's `$` partial-matches: a temp_spike sent `duration_delta`
# resolves `disruption$duration` to that value and applies the spike as though the
# right key had been used (measured: retail runs on to 5.9583 d, no error). Guarding
# the name here would catch one direction and hide the other, so #36 owns it.
append_profile_segment <- function(profile, temperature, duration, stage, epsilon = 1e-5) {
  if (duration <= 0) {
    # signif(), not round() as #51's guard uses: the smallest trigger here is -1e-9,
    # and round(-1e-9, 6) prints "0", so a message about a negative value would read
    # as a complaint about zero.
    stop(paste0("The segment appended to stage '", stage, "' has a duration of ",
                signif(duration, 6), " days. It must be positive."))
  }
  # The offset must never reach the segment's own end, or a POSITIVE duration
  # recreates the out-of-order profile the check above exists to prevent: at
  # duration = 1e-6 the opening row landed at start + 1e-5 and the closing row at
  # start + 1e-6, so the closing row came first. Halving keeps the opening row
  # strictly inside the segment for every duration.
  #
  # It changes nothing a user can reach. The bound binds only below 2e-5 d, which is
  # 1.7 seconds, so every shipped profile and every plausible request keeps the flat
  # 1e-5 d epsilon that S1.5 and normalise_profile() establish repo-wide.
  #
  # No spoilage consequence either way, and the fix is here for the contract rather
  # than for the prediction: the two rows the sub-epsilon case swapped carry the SAME
  # temperature by construction, so both readers saw a 0.04001 d stage and their
  # growth integrals agreed to 0.000e+00. Raised as a P2 on PR #55.
  epsilon <- min(epsilon, duration / 2)
  start <- max(profile$time_days)
  opening <- start + epsilon
  closing <- start + duration

  # Halving is not on its own enough, because the addition can absorb the result.
  # Measured against the shipped start of 0.04: at duration 1e-17 the two additions
  # land on the SAME double, and at 1e-18 or below both collapse back onto start --
  # so the function would emit the duplicate timestamps approxfun() averages, which
  # is the tie S1.5 and normalise_profile() exist to prevent. The smallest subnormal
  # also underflows duration / 2 to zero outright.
  #
  # So this tests the timestamps that were actually computed rather than reasoning
  # about the magnitude that produced them. It is the only form that stays correct
  # whatever `start` is: the absorbing duration scales with the profile's own
  # position, and a stage late in a long run starts at a larger value than 0.04.
  #
  # Unreachable in practice -- 1e-17 d is under a picosecond -- and it moves no
  # prediction. It is here so the guard's own claim holds, which is the same reason
  # the halving above is. Raised as a P2 on PR #55.
  if (!(start < opening && opening < closing)) {
    stop(paste0("The segment appended to stage '", stage, "' has a duration of ",
                signif(duration, 6), " days, which is too small to place its two ",
                "rows at distinct timestamps after the stage's last point (",
                signif(start, 15), "). It must be large enough to advance both."))
  }

  bind_rows(profile, data.frame(
    time_days = c(opening, closing),
    temperature = c(temperature, temperature)
  ))
}

# A stage must keep a positive duration. Its two callers each measure the stage a
# different way, so the check takes an already-computed value rather than a delta:
# apply_stage_temp_overrides() (scenarios/interventions.R) passes the CONFIGURED
# duration before writing it, and resize_profile() below passes the PROFILE SPAN.
# Those two quantities can differ -- effective_stage_duration() treats the span as
# the source of truth -- so the guards are not redundant and either may fire alone.
#
# A static stage has no profile and so only reaches the first, which is why the
# check cannot live in the resizer alone: transportation_retail_to_home (0.04 d, no
# measured profile) took duration_delta = -0.04 to a duration of 0 and ran on. See
# #51.
stop_if_nonpositive_duration <- function(new_duration, stage) {
  if (new_duration <= 0) {
    stop(paste0("duration_delta on stage '", stage, "' would leave a duration of ",
                round(new_duration, 4), " days. It must stay positive."))
  }
}

# Extend or shorten a dynamic stage's profile by delta_days, so that a duration
# change reaches the simulation instead of only the reported shelf life.
#
# Extending holds the final temperature, matching how temp_spike and delay append
# a flat segment (scenarios/disruptions.R:35-59). Shortening truncates and pins a
# closing point at the new end, so the stage's span is exactly as asked.
resize_profile <- function(profile, delta_days, stage) {
  if (delta_days == 0) return(profile)

  profile <- profile[order(profile$time_days), , drop = FALSE]
  end <- max(profile$time_days)
  new_end <- end + delta_days

  stop_if_nonpositive_duration(new_end, stage)

  final_temp <- profile$temperature[nrow(profile)]

  if (delta_days > 0) {
    bind_rows(profile, data.frame(
      time_days = c(end, new_end),
      temperature = c(final_temp, final_temp)
    ))
  } else {
    kept <- profile[profile$time_days < new_end, , drop = FALSE]
    # Interpolate the closing temperature from the ORIGINAL profile. Carrying the
    # last retained sample forward instead makes the stage end at whatever was
    # measured before the cut, which is only harmless when samples are dense.
    # Invisible on the shipped hourly profiles -- the retained sample and the
    # interpolated value agree to 0.0000 C. It bites a user who supplies sparse
    # measurements: daily readings cut mid-day closed 1.00 C off and moved the
    # stage's growth by 1.81%, and a two-point 0->10 C ramp cut at its midpoint
    # closed at 0 C where it should read 5 C.
    closing_temp <- suppressWarnings(
      approx(profile$time_days, profile$temperature, xout = new_end, rule = 2)$y)
    bind_rows(kept, data.frame(time_days = new_end, temperature = closing_temp))
  }
}

# Guarantee a stage has a profile, so a scenario segment has somewhere to live.
#
# A static stage has none, so temp_spike and delay had nowhere to append and their
# temperature was dropped -- scenarios/disruptions.R:33-34 and :50-51 wrote it to a
# config key nothing reads, leaving only the duration extension. A 25 C spike and a
# 0 C spike produced bit-identical output, on every pathway.
#
# Synthesises a flat profile from the stage's configured mean and duration, then
# promotes the stage to dynamic so every consumer reads the profile rather than the
# container's own column. Returns config and profiles together, since promoting the
# stage changes both.
#
# TRADEOFF. A profile is shared by every container, so promoting the stage drops the
# per-container T_T2/t_T2 variation run_model.R:119-136 samples from sd and
# duration_sd. What it buys is the real shape of the excursion: the ODE pathways
# integrate a genuine two-segment step rather than one averaged constant, and growth
# is nonlinear in temperature, so averaging a hot segment understates it.
#
# Measured on the default stage (0.04 d at 8.5 +/- 1.0 C), holding the RNG stream
# fixed: zeroing that variability changes every reported median, P5/P95 band and
# shelf-life figure by exactly 0.0000 pp. One hour of +/-1 C against a 40-day run
# with a threshold-counted output contributes nothing.
#
# That equivalence depends on the stage being short. If a static stage is ever
# configured with a materially longer duration, preserve the variability instead by
# giving build_env_conditions() a per-container two-segment step for the stage,
# rather than promoting it here.
#
# `duration` is the span the synthesised profile should cover. Pass the stage's
# ORIGINAL duration explicitly: a caller that has already extended
# config$temperature_stages[[stage]]$duration would otherwise synthesise a profile
# covering the extension and then append it a second time, so the stage would be
# simulated for duration + 2 * delta while the config reported duration + delta.
ensure_stage_profile <- function(stage, temp_profiles, config, duration = NULL) {
  if (!is.null(temp_profiles[[stage]])) {
    return(list(config = config, temp_profiles = temp_profiles))
  }

  stage_cfg <- config$temperature_stages[[stage]]
  span <- if (is.null(duration)) stage_cfg$duration else duration

  # A temp_max intervention on a static stage is enforced on the container columns
  # (run_model.R), which promotion then stops anything from reading. Apply it to the
  # synthesised profile instead, matching how a dynamic stage is clamped in
  # scenarios/interventions.R before any segment is appended. The appended segment
  # itself stays as specified: a disruption overriding an intervention is a declared
  # conflict, and resolve.R already warns about it.
  base_temp <- stage_cfg$mean
  if (!is.null(stage_cfg$temp_max)) {
    base_temp <- min(base_temp, stage_cfg$temp_max)
  }

  temp_profiles[[stage]] <- data.frame(
    time_days = c(0, span),
    temperature = c(base_temp, base_temp)
  )
  config$temperature_stages[[stage]]$mode <- "dynamic"

  list(config = config, temp_profiles = temp_profiles)
}

# Copy static-stage conditions from the synthetic containers onto pool-derived rows.
#
# A static stage has no profile, so apply_effective_stage_durations() cannot supply
# it and the scenario layer has nowhere to write except cfg$temperature_stages. Those
# values reach the simulation only through the synthetic container frame, which
# run_model.R:119-136 samples from cfg after the scenario pipeline has run and then
# clamps with temp_max.
#
# Pool-derived rows carry the source container's own T_T2/t_T2 instead, so without
# this copy a scenario aimed at the static stage reaches the PPC pathway and no
# other -- both non-PPC pathways ignore it. transportation_retail_to_home is the
# delivery leg, so a delay or a temperature shift there is an obvious thing to ask
# about, and 100% of non-PPC containers were deaf to it.
#
# Note this covers high-growth as well as medium-growth: build_env_conditions()
# reads the row's own column at its static branch, so the ODE pathway is affected
# too.
apply_static_stage_conditions <- function(model_data, containers, temp_profiles, config) {
  if (nrow(model_data) == 0) return(model_data)

  idx <- match(paste(model_data$lot_id, model_data$unit_id),
               paste(containers$lot_id, containers$unit_id))

  for (stage in config$stage_order) {
    stage_cfg <- config$temperature_stages[[stage]]
    if (stage_cfg$mode == "dynamic" && !is.null(temp_profiles[[stage]])) next

    cols <- config$stage_to_cols[[stage]]
    if (!is.null(containers[[cols$temp]])) {
      model_data[[cols$temp]] <- containers[[cols$temp]][idx]
    }
    if (!is.null(containers[[cols$time]])) {
      model_data[[cols$time]] <- containers[[cols$time]][idx]
    }
  }

  model_data
}

# Resolve each stage's duration into a container frame's t_* columns, and place the
# stage boundaries the Buchanan model splits its history at. The medium-growth
# pathway needs those boundaries explicitly, where build_env_conditions() carries
# them implicitly in one spliced series.
#
# Mirrors build_env_conditions() branch for branch, so a container sees the same
# thermal history whichever pathway simulates it:
#   dynamic stage -> the profile's span, and the profile itself supplies the
#                    temperature at every instant (stage_growth_integral)
#   static stage  -> the container's own columns, which is what the static branch
#                    of build_env_conditions() reads
#
# Source: PPI_Digital-Interface/model/run_model.R:150-164 writes profile mean and
# duration into updated_data_bclc, and :253-258 writes scenario overrides into it.
# The port had dropped both, leaving the medium pathway on its pool row's own
# thermal history and deaf to every temperature scenario.
apply_effective_stage_durations <- function(model_data, temp_profiles, config) {
  if (nrow(model_data) == 0) return(model_data)

  for (stage in config$stage_order) {
    cols <- config$stage_to_cols[[stage]]
    stage_cfg <- config$temperature_stages[[stage]]

    if (stage_cfg$mode == "dynamic" && !is.null(temp_profiles[[stage]])) {
      model_data[[cols$time]] <- effective_stage_duration(stage, temp_profiles, config)
    }
  }

  # Extend the final stage to the simulation horizon.
  #
  # simulate_growth_row() caps time within each stage, so a container stops growing
  # at the last stage boundary. The default profiles cover 36.21 days of a 40-day
  # run, which would hold the final 3.79 days artificially flat and so delay or
  # erase a shelf-life crossing late in the run -- exactly where a strong
  # intervention pushes it. The ODE pathways have no such boundary: they hold the
  # final profile temperature and keep integrating to the horizon. This makes the
  # Buchanan pathway agree with them.
  #
  # The stretch carries the temperature the ODE holds over it, the profile's FINAL
  # value, because stage_growth_integral() holds that value past the recorded span
  # exactly as approxfun(rule = 2) does. A static stage holds the container's own
  # scalar over the stretch, which is what build_env_conditions() feeds the solver.
  #
  # The shortfall is per row, because the static stage keeps each container's own
  # t_T2 and so shifts where every later stage sits against the horizon.
  #
  # A stage running PAST the horizon needs nothing here: the run stops accumulating
  # at sim_duration (simulate_growth_row()'s pmin(t, end)), and because the pathway
  # now integrates the profile over the time actually spent in the stage, the
  # unreachable tail is never evaluated.
  time_cols <- vapply(config$stage_order,
                      function(s) config$stage_to_cols[[s]]$time,
                      character(1))
  durs <- as.matrix(model_data[, time_cols, drop = FALSE])
  shortfall <- pmax(config$sim_duration - rowSums(durs), 0)

  final_time <- config$stage_to_cols[[config$stage_order[length(config$stage_order)]]]$time
  model_data[[final_time]] <- model_data[[final_time]] + shortfall

  model_data
}

# Build env_conditions tibble for a single container
# Handles both static (2-point step function) and dynamic (hourly profile) stages
# Reads mode from config$temperature_stages to decide per stage
build_env_conditions <- function(i, model_data, temp_profiles, config) {
  time_vec <- numeric(0)
  temp_vec <- numeric(0)
  cumulative_time <- 0
  epsilon <- 1e-5

  for (idx in seq_along(config$stage_order)) {
    stage <- config$stage_order[idx]
    cols <- config$stage_to_cols[[stage]]
    stage_cfg <- config$temperature_stages[[stage]]

    if (stage_cfg$mode == "dynamic" && !is.null(temp_profiles[[stage]])) {
      # Dynamic: splice in hourly profile, shifted to absolute time
      profile <- temp_profiles[[stage]]
      start_time <- if (idx > 1) cumulative_time + epsilon else cumulative_time
      shifted_times <- profile$time_days + start_time
      time_vec <- c(time_vec, shifted_times)
      temp_vec <- c(temp_vec, profile$temperature)
      stage_duration <- max(profile$time_days)
    } else {
      # Static: 2-point step function from container T/t columns
      stage_temp <- model_data[[cols$temp]][i]
      stage_dur <- model_data[[cols$time]][i]
      start_time <- if (idx > 1) cumulative_time + epsilon else cumulative_time
      time_vec <- c(time_vec, start_time, start_time + stage_dur)
      temp_vec <- c(temp_vec, stage_temp, stage_temp)
      stage_duration <- stage_dur
    }

    # Advance past the epsilon too, not only the stage duration. Without this the
    # stage's last point lands at cumulative + epsilon, which is exactly where the
    # next stage's first point is placed -- so every dynamic boundary carried a
    # duplicate timestamp. approxfun() defaults to ties = mean, so each boundary
    # collapsed to the average of the two stages' temperatures and the solver then
    # interpolated linearly away from it.
    #
    # Invisible with the dense baseline profiles: a collapsed boundary only
    # distorts the interval to the next point, about an hour. It becomes severe on a
    # sparse profile -- a promoted static stage has four points, so the collapse at
    # its far edge dragged the whole 2-day stage from 20 C down toward 13.25 C, the
    # mean of 20 and the consumer stage's 6.5.
    cumulative_time <- cumulative_time + stage_duration +
      (if (idx > 1) epsilon else 0)
  }

  tibble(time = time_vec, temperature = temp_vec)
}
