# The Buchanan pathway must integrate its own growth rate over the real thermal
# history, at every reported day -- not only over a whole stage.
#
# Why this suite exists separately from the other two:
#
#   compare_distributions.R runs each pathway under ONE CONSTANT temperature per
#   stage, where a collapsed stage and an exact integral agree identically. It
#   cannot see this by construction.
#
#   verify_structure.R's Seam 3 compares the growth a scenario implies as a stage
#   TOTAL. The retired evaluation collapsed a stage to the one temperature that
#   reproduced that total, so the total was lossless by derivation and the shape
#   inside the stage was lost. Seam 3 agreed to 0.05% throughout.
#
# The trajectory is the product: the model reports at days 7/14/21/28/35 and derives
# shelf life from threshold crossings. So this asserts the whole curve.
#
# Oracle: the spliced time/temperature series the ODE pathways integrate, quadratured
# on a dense grid. Independent of the pathway's own segment arithmetic -- it shares
# only approxfun() and muAtNewTemp(), which is the agreement being claimed.
#
# Measured against the collapsed evaluation this replaced, over 7 shapes x 4 seeds x
# 3 containers: 0.0000 log10 at the day-40 endpoint, 4.98 at a reported day, 5.69 at
# the worst day of any kind, and 30 of 420 spoilage calls flipped. The two figures
# differ because the reported days are 7/14/21/28/35 and the worst day need not be
# one of them. See issue #19 and docs/adr/007-buchanan-integrated-exactly.md.

set.seed(42)

args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grep("--file=", args)])
if (length(script_path) > 0) {
  script_dir <- dirname(normalizePath(script_path))
} else {
  script_dir <- getwd()
}

setwd(file.path(script_dir, "..", "milk-spoilage-model"))
cat("Working directory:", getwd(), "\n")

source("run_model.R")

# 0.01 log10, against a measured floor of 0.0001. That floor is the quadrature error
# plus the 1e-5 d epsilon build_env_conditions() puts at each stage boundary, which
# the Buchanan stage boundaries do not carry. Compared against max error over ALL
# days, so the defect it guards is the 5.69 log10 figure, not the 4.98 one.
TOL <- 0.01

# =============================================================================
# Profile shapes
# =============================================================================
# Each shape is drawn over the consumer stage, which is the long one (27.96 d) and
# so the one where a collapse does the most damage. The other dynamic stages carry
# their own randomised ramp, so no case runs isothermal outside the shape.
#
# The last three set the consumer span deliberately:
#   short_warm_tail    ends at day 15, so 25 d of the run are the held final
#                      temperature -- the stretch to the horizon.
#   past_horizon_*     runs to day 48, so the run ends partway through the stage and
#                      the unreachable tail must not drive growth. Both signs, warm
#                      and cold, because a one-sided fix passes whichever is chosen.
shape_temp <- function(shape, u, lo, hi, pos) {
  switch(shape,
    constant       = rep(lo, length(u)),
    ramp_up        = lo + (hi - lo) * u,
    ramp_down      = hi - (hi - lo) * u,
    step_early     = ifelse(u < pos, hi, lo),
    step_late      = ifelse(u < pos, lo, hi),
    spike_mid      = ifelse(u > pos & u < pos + 0.1, hi, lo),
    sawtooth       = lo + (hi - lo) * abs(((u * 4) %% 1) - 0.5) * 2,
    short_warm_tail   = ifelse(u < 0.85, lo, hi),
    past_horizon_warm = ifelse(u < pos, lo, hi),
    past_horizon_cold = ifelse(u < pos, hi, lo)
  )
}

shape_span <- function(shape) {
  switch(shape,
    short_warm_tail   = 7,
    past_horizon_warm = 40,
    past_horizon_cold = 40,
    27.9583
  )
}

shapes <- c("constant", "ramp_up", "ramp_down", "step_early", "step_late",
            "spike_mid", "sawtooth", "short_warm_tail",
            "past_horizon_warm", "past_horizon_cold")
n_seeds <- 8
n_rows <- 3

make_profile <- function(shape, span, lo, hi, pos, n) {
  t <- seq(0, span, length.out = n)
  data.frame(time_days = t, temperature = shape_temp(shape, t / span, lo, hi, pos))
}

# =============================================================================
# Oracle: quadrature of mu(T(s)) over the spliced series
# =============================================================================
# muAtNewTemp() is linear in the container's growthrate, so one integral at
# growthrate = 1 serves every container sharing the series.
STEP <- 1e-4

cumulative_growth <- function(row, temp_profiles, cfg) {
  env <- build_env_conditions(1, row, temp_profiles, cfg)
  f <- suppressWarnings(approxfun(env$time, env$temperature, rule = 2))
  grid <- seq(0, cfg$sim_duration, by = STEP)
  mu <- muAtNewTemp(f(grid), 1)
  c(0, cumsum((head(mu, -1) + tail(mu, -1)) / 2 * STEP))
}

# =============================================================================
# Cases
# =============================================================================
pool <- read.csv("input_data/medium_growth_containers.csv") %>%
  filter(Growth_category != "A" & postpastcontainer >= 1)

# One case: draw containers, run the pathway on the given config and profiles, and
# compare every day against the oracle.
run_case <- function(label, cfg, profiles, seed) {
  set.seed(seed)

  # One synthetic container, so every pool row shares the static stage's drawn
  # temperature and duration -- and therefore one spliced series.
  container <- data.frame(lot_id = seq_len(n_rows), unit_id = 1L)
  for (s in cfg$stage_order) {
    sc <- cfg$temperature_stages[[s]]
    cols <- cfg$stage_to_cols[[s]]
    container[[cols$temp]] <- sc$mean
    container[[cols$time]] <- sc$duration
  }

  rows <- pool[sample(nrow(pool), n_rows), ]
  rows$lot_id <- seq_len(n_rows)
  rows$unit_id <- 1L

  rows <- apply_static_stage_conditions(rows, container, profiles, cfg)
  rows <- apply_effective_stage_durations(rows, profiles, cfg)
  got <- run_medium_growth_pathway(rows, cfg, profiles)

  cum1 <- cumulative_growth(rows, profiles, cfg)

  bind_rows(lapply(seq_len(n_rows), function(i) {
    traj <- got[got$lot_id == i, ]
    traj <- traj[order(traj$day), ]
    want <- pmin(rows$log10N0[i] + rows$growthrate[i] * cum1[round(traj$day / STEP) + 1],
                 rows$log10Nmax[i])
    err <- abs(traj$log10_concentration - want)
    reported <- traj$day %in% cfg$output_days

    data.frame(
      case = label, seed = seed, row = i,
      worst_day = traj$day[which.max(err)],
      max_err = max(err),
      reported_err = max(err[reported]),
      end_err = err[length(err)],
      disagreements = sum((traj$log10_concentration > cfg$spoilage_threshold) !=
                          (want > cfg$spoilage_threshold) & reported)
    )
  }))
}

results <- list()

for (shape in shapes) {
  for (seed in seq_len(n_seeds)) {
    set.seed(1000 * match(shape, shapes) + seed)

    cfg <- config
    profiles <- load_baseline_profiles(cfg$temperature_stages)

    lo <- runif(1, 0, 8)
    hi <- lo + runif(1, 5, 20)
    pos <- runif(1, 0.3, 0.9)
    span <- shape_span(shape)
    profiles$consumer <- make_profile(shape, span, lo, hi, pos, sample(49:241, 1))
    cfg$temperature_stages$consumer$duration <- span

    for (s in c("processing_facility", "transportation_facility_to_retail", "retail")) {
      profiles[[s]] <- make_profile("ramp_up", max(profiles[[s]]$time_days),
                                    runif(1, 0, 6), runif(1, 6, 12), 0.5, 49)
    }

    results[[length(results) + 1]] <- run_case(shape, cfg, profiles, seed)
  }
}

# =============================================================================
# Scenario cases: the same assertion, reached through resolve_scenario()
# =============================================================================
# The shapes above install profiles directly. These reach the pathway the way a
# user does, so they assert that a disruption arrives as the pathway integrates it.
#
# `temp_spike past horizon` is here because Seam 3 used to carry it and can no
# longer: a scenario pushing a stage past the day-40 horizon leaves the two sides
# of that matrix averaging over windows of different lengths. Per reported day it
# is a fair comparison, and a stricter one.
scenario_csv <- tempfile(fileext = ".csv")
scv_t <- seq(0, 12, length.out = 289)
write.csv(data.frame(time_days = scv_t, temperature = ifelse(scv_t < 9, 3, 18)),
          scenario_csv, row.names = FALSE)

# Two CSVs carrying DUPLICATE timestamps, which is how a real recording writes a
# step change. approxfun() defaults to ties = mean, so the oracle below collapses
# the tied rows and ramps through their average, while stage_growth_integral()
# reads the same rows as a step -- the two halves of the model disagree about what
# the user recorded. Sparse deliberately: the divergence scales with the length of
# the segments either side of the tie. Issue #21.
#
# The tail case is the worse of the two. apply_effective_stage_durations() stretches
# the final stage to the day-40 horizon, so whichever temperature is held past the
# recorded span is held for the whole stretch.
tied_mid_csv <- tempfile(fileext = ".csv")
write.csv(data.frame(time_days = c(0, 9, 9, 12), temperature = c(3, 3, 22, 22)),
          tied_mid_csv, row.names = FALSE)

tied_tail_csv <- tempfile(fileext = ".csv")
write.csv(data.frame(time_days = c(0, 6, 12, 12), temperature = c(4, 9, 15, 26)),
          tied_tail_csv, row.names = FALSE)

scenarios <- list(
  `temp_spike past horizon` = list(
    consumer = list(type = "temp_spike", temp = 25, duration = 8)),
  `temp_spike after last reported day` = list(
    consumer = list(type = "temp_spike", temp = 25, duration = 2)),
  `delay on the static stage` = list(
    transportation_retail_to_home = list(type = "delay", temp = 20, duration_delta = 2)),
  `profile_csv consumer warm tail` = list(
    consumer = list(type = "profile_csv", path = scenario_csv)),
  `profile_csv tied timestamp mid` = list(
    consumer = list(type = "profile_csv", path = tied_mid_csv)),
  `profile_csv tied timestamp at end` = list(
    consumer = list(type = "profile_csv", path = tied_tail_csv))
)

for (label in names(scenarios)) {
  sc <- resolve_scenario(config, load_baseline_profiles(config$temperature_stages),
                         read.csv("input_data/ppc_st_frequency.csv"),
                         list(), scenarios[[label]])
  results[[length(results) + 1]] <- run_case(label, sc$config, sc$temp_profiles, 7)
}

results <- bind_rows(results)

# =============================================================================
# Report
# =============================================================================
cat("\n========== BUCHANAN TRAJECTORY ==========\n\n")
cat(sprintf("%d trajectories: %d shapes x %d seeds plus %d scenarios, x %d containers.\n",
            nrow(results), length(shapes), n_seeds, length(scenarios), n_rows))
cat(sprintf("Tolerance %.3f log10, on the worst error at ANY day.\n\n", TOL))

cat(sprintf("%-36s %-8s %-12s %-12s %-12s %s\n",
            "CASE", "RESULT", "WORST", "AT REPORTED", "AT DAY 40", "CALLS FLIPPED"))
cat(paste(rep("-", 104), collapse = ""), "\n")

by_case <- results %>%
  group_by(case) %>%
  summarise(max_err = max(max_err), reported_err = max(reported_err),
            end_err = max(end_err), disagreements = sum(disagreements),
            .groups = "drop")

for (i in seq_len(nrow(by_case))) {
  cat(sprintf("%-36s %-8s %-12.4f %-12.4f %-12.4f %d\n",
              by_case$case[i],
              if (by_case$max_err[i] < TOL) "PASS" else "FAIL",
              by_case$max_err[i], by_case$reported_err[i],
              by_case$end_err[i], by_case$disagreements[i]))
}
cat(paste(rep("-", 104), collapse = ""), "\n")

worst <- results[which.max(results$max_err), ]
cat(sprintf("\nworst: %.4f log10 at day %d (%s, seed %d)\n",
            worst$max_err, worst$worst_day, worst$case, worst$seed))
cat(sprintf("spoilage calls flipped: %d of %d reported days\n",
            sum(results$disagreements), nrow(results) * length(config$output_days)))

plan(sequential)

n_fail <- sum(by_case$max_err >= TOL)
if (n_fail > 0) {
  cat(sprintf("\n%d of %d cases FAILED.\n", n_fail, nrow(by_case)))
  quit(status = 1)
}
cat("\nBuchanan trajectory verification passed.\n")
