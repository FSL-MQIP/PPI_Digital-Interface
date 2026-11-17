# Structural verification of container assembly and pathway routing
#
# Asserts the invariants that `compare_distributions.R` cannot see. That script
# runs each pathway in isolation and compares quantiles, so it cannot test
# container assembly, pathway routing, aggregation or lot structure -- which is
# where the material divergences from the legacy model live.
#
# Every expected value below comes from the legacy source or from the design
# spec, never from re-deriving what the port does. Sources are cited per check.
#
# Findings inventory: docs/research/2026-08-06-port-audit.md
#
# The failures are the inventory made executable. Exit code is non-zero while any
# check is red. The container-assembly defects this script was written against are
# fixed, so it is now expected to pass; a red check is a regression.

set.seed(42)

# Determine script directory (same pattern as compare_distributions.R)
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

# run_model.R sources config, utils, pathways and scenarios itself
source("run_model.R")

# =============================================================================
# Check recorder
# =============================================================================
checks <- list()

record <- function(id, defect, seam, claim, source_ref, passed, observed, expected) {
  checks[[length(checks) + 1]] <<- list(
    id = id, defect = defect, seam = seam, claim = claim,
    source_ref = source_ref, passed = passed,
    observed = observed, expected = expected
  )
  cat(sprintf("  [%s] %-4s %s\n", if (passed) "PASS" else "FAIL", id, claim))
  cat(sprintf("         expected: %s\n", expected))
  cat(sprintf("         observed: %s\n", observed))
  cat(sprintf("         source:   %s\n\n", source_ref))
}

container_key <- function(df) unique(paste(df$lot_id, df$unit_id))

# =============================================================================
# SEAM 1: the shipped pool CSVs, at load time
# =============================================================================
cat("\n========== SEAM 1: POOL CSVs AT LOAD ==========\n\n")

pool_bclc <- read.csv("input_data/medium_growth_containers.csv")
pool_d <- read.csv("input_data/high_growth_containers.csv")

# The model sums a container's load across every genus row it carries, so it
# depends on the pools encoding communities rather than single organisms. These
# assert that structure is present: if a future data swap flattens the pools to
# one row per container, additivity silently becomes a no-op and these fail.
for (p in list(list(n = "S1.1", pool = pool_bclc, label = "medium"),
               list(n = "S1.2", pool = pool_d, label = "high"))) {
  n_rows <- nrow(p$pool)
  n_containers <- length(container_key(p$pool))
  record(
    id = p$n, defect = "D2", seam = "pool CSV",
    claim = sprintf("%s pool carries multi-genus communities", p$label),
    source_ref = "PPI_Digital-Interface/model/Model.R:216-222 pivots wide by Genus and sums across genus rows",
    passed = n_rows > n_containers,
    observed = sprintf("%d rows over %d distinct containers (%.2f genera each)",
                       n_rows, n_containers, n_rows / n_containers),
    expected = "rows > distinct containers"
  )
}

# Additivity across pools is the point: a container's genera are split across
# both files, so the pools must overlap by container key.
km <- container_key(pool_bclc)
kh <- container_key(pool_d)
n_both <- length(intersect(km, kh))
n_union <- length(union(km, kh))
record(
  id = "S1.3", defect = "D1", seam = "pool CSV",
  claim = "containers span both pools",
  source_ref = "PPI_Digital-Interface/model/Model.R:209-222 row-binds all pools before the pivot, so one container spans pools",
  passed = n_both > 0,
  observed = sprintf("%d of %d distinct containers appear in BOTH pools (%.1f%%)",
                     n_both, n_union, 100 * n_both / n_union),
  expected = "> 0 containers in both pools"
)

# The no-growth pool is empty, and that is faithful: the shipped pools carry no
# row meeting its criteria, and neither do PPI's originals. That pathway populates
# only when a user supplies APC data, which triggers a Poisson re-draw of
# per-container cell counts (PPI run_model.R:92-116, its ADR-003). This port
# exposes no APC input, so the branch is unreachable by construction.
#
# So this pins the precondition rather than demanding the pool fill. If a future
# data drop ships category-A rows or zero-cell containers, the third pathway goes
# live and this fires -- which is the moment the paper's two-pathway claim would
# go stale.
pool_nogrowth <- pool_bclc %>%
  filter(Growth_category == "A" | postpastcontainer < 1)
record(
  id = "S1.4", defect = "D5", seam = "pool CSV",
  claim = "the no-growth pool is empty, so two pathways carry the model",
  source_ref = "PPI_Digital-Interface/model/run_model.R:92 guards the rpois re-draw behind user APC input, which this port does not expose",
  passed = nrow(pool_nogrowth) == 0,
  observed = sprintf("%d rows match (Growth_category == 'A' | postpastcontainer < 1); min(postpastcontainer) = %s, category-A rows = %d",
                     nrow(pool_nogrowth), format(min(pool_bclc$postpastcontainer)),
                     sum(pool_bclc$Growth_category == "A")),
  expected = "0 rows -- if this fires, the paper's two-pathway claim needs revisiting"
)

# An appended disruption segment must reach the ODE as a step, not a ramp.
# approxfun() defaults to ties = mean, so a segment starting at exactly the
# profile's last timestamp collapses to the average of the two temperatures and the
# step becomes a linear ramp. The medium pathway integrates the uncollapsed rows
# directly (stage_growth_integral), so the two halves of the model then disagree
# about what the scenario was. Checked on the helper directly: it is a pure
# function, and an end-to-end figure here would be brittle.
seg_base_t <- 8.5; seg_base_d <- 0.04
seg_temp <- 20; seg_dur <- 2

seg_profile <- append_profile_segment(
  data.frame(time_days = c(0, seg_base_d),
             temperature = c(seg_base_t, seg_base_t)),
  seg_temp, seg_dur, "transportation_retail_to_home")

seg_f <- approxfun(seg_profile$time_days, seg_profile$temperature, rule = 2)
seg_grid <- seq(0, max(seg_profile$time_days), length.out = 20001)
seg_integrated <- mean(seg_f(seg_grid))
seg_requested <- (seg_base_t * seg_base_d + seg_temp * seg_dur) / (seg_base_d + seg_dur)

record(
  id = "S1.5", defect = "tie-collapse", seam = "profile construction",
  claim = "an appended segment reaches the solver as a step, not a ramp",
  source_ref = "approxfun() defaults to ties = mean; build_env_conditions() already offsets stage boundaries by an epsilon for the same reason",
  passed = abs(seg_integrated - seg_requested) < 0.05,
  observed = sprintf("solver integrates %.4f C against %.4f C requested (%.4f C apart)",
                     seg_integrated, seg_requested, abs(seg_integrated - seg_requested)),
  expected = "agree to within 0.05 C"
)

# A profile the USER supplies with duplicate timestamps must reach the solver as a
# step too. S1.5 covers the segment the repo appends itself, which already uses the
# 1e-5 d epsilon idiom. This covers the tie that arrives through a CSV -- a
# configured baseline path or a profile_csv disruption -- where nothing offsets it.
#
# The two halves then read different series from one file. approxfun() defaults to
# ties = mean, so the ODE pathways collapse the tied rows to their average and ramp
# THROUGH it; stage_growth_integral() keeps both rows and the zero-length segment
# between them contributes nothing, so the Buchanan pathway reads a step. Issue #21.
#
# Compared in growth space, not temperature space, because muAtNewTemp() squares
# (T - T0): two readings can share a mean temperature and imply different growth.
#
# Each check below measures BOTH integrators against the step the ORIGINAL CSV
# means, never against each other. Comparing them against each other is worthless
# here: they both read the profile AFTER normalise_profile() has touched it, so any
# mutation of the normaliser leaves them agreeing on the same wrong series. Mutation
# tested, over both cases below -- dropping the tied row and keeping its first value,
# keeping its last, averaging the two the way approxfun() does, and nudging backward
# instead of forward. All 8 mutants agreed to 0.000% and so survived an agreement
# check; the averaging mutant read 337.1777 against the CSV's 425.3448, out by 20.7%.
# Raised as a P2 on PR #22.
tie_T0 <- eval(formals(muAtNewTemp)$T0)

# Grid sized by `length.out`, never by a fixed step. A sub-second case below spans
# 4.63e-5 d, where a hardcoded 1e-5 d step would put five points on the whole window
# and miss the step entirely.
TIE_N <- 200001L
tie_quadrature <- function(temp_at, upto) {
  grid <- seq(0, upto, length.out = TIE_N)
  y <- (temp_at(grid) - tie_T0)^2
  sum((head(y, -1) + tail(y, -1)) / 2) * (upto / (TIE_N - 1L))
}

tie_ode_integral <- function(profile, upto) {
  f <- suppressWarnings(approxfun(profile$time_days, profile$temperature, rule = 2))
  tie_quadrature(f, upto)
}

# The temperature the CSV means at time u, stated straight from its own rows and
# sharing no code with either integrator or with normalise_profile(). Between
# consecutive DISTINCT timestamps the series holds or ramps; at a repeated one it
# steps instantaneously; past the last row the final value is held, which is what
# the final stage's stretch to the horizon runs on.
#
# findInterval() returns the LAST index of a tied group, so at a tie the segment
# opened has no extent and the post-step temperature applies immediately. That is
# the whole semantics of a duplicate timestamp, in one line.
tie_intended_temp <- function(profile, u) {
  # Sort first, stably, so a tied group keeps its file order and "the last of a tie"
  # still means the row the user wrote last. Ordering is part of what a profile
  # means, and findInterval() requires it; ties are left exactly as written.
  profile <- profile[order(profile$time_days), , drop = FALSE]
  t <- profile$time_days
  temp <- profile$temperature
  i <- pmax(findInterval(u, t), 1L)
  j <- pmin(i + 1L, length(t))
  dt <- t[j] - t[i]
  frac <- pmin(pmax(ifelse(dt > 0, (u - t[i]) / dt, 0), 0), 1)
  temp[i] + (temp[j] - temp[i]) * frac
}

tie_intended_integral <- function(profile, upto) {
  tie_quadrature(function(u) tie_intended_temp(profile, u), upto)
}

tie_load <- function(profile) {
  path <- tempfile(fileext = ".csv")
  write.csv(data.frame(time = profile$time_days, temperature = profile$temperature),
            path, row.names = FALSE)
  on.exit(unlink(path))
  load_baseline_profiles(list(s = list(mode = "dynamic", path = path)))$s
}

# One check: load the raw profile the way a user's CSV arrives, then hold both
# integrators to the step its rows mean.
tie_check <- function(id, claim, source_ref, raw, upto, note = "") {
  got <- tie_load(raw)
  want <- tie_intended_integral(raw, upto)
  buch <- stage_growth_integral(got)(upto)
  ode <- tie_ode_integral(got, upto)
  worst <- max(abs(c(buch, ode) - want)) / want

  record(
    id = id, defect = "tie-collapse", seam = "profile construction",
    claim = claim, source_ref = source_ref,
    passed = worst < 1e-3,
    observed = sprintf("%sCSV means %.4f; Buchanan %.4f, ODE %.4f (worst %.4f%% off the CSV)",
                       note, want, buch, ode, 100 * worst),
    expected = "both integrators within 0.1% of the step the CSV means"
  )
}

# S1.5.tie_mid, mid-profile: 2 C until half a day, then 25 C, written as a duplicate
# timestamp. This is the idiom a real recording produces at a step change.
tie_check(
  "S1.5.tie_mid",
  "a user profile's tied timestamps reach both integrators as the step the CSV means",
  "issue #21; same ties = mean collapse S1.5 guards, arriving through a CSV instead of an appended segment",
  data.frame(time_days = c(0, 0.5, 0.5, 1), temperature = c(2, 2, 25, 25)), 1)

# S1.5.tie_end, tie at the END of the profile. Worse than a mid-profile tie: the
# final stage is stretched to the simulation horizon
# (apply_effective_stage_durations()), so whatever temperature is held past the
# recorded span is held for as long as that stretch runs -- up to 24.75 days of a
# 40-day run. The CSV means 30 C over the stretch; ties = mean held 25 C.
tie_check(
  "S1.5.tie_end",
  "a tie at a profile's end holds the CSV's final temperature past the recorded span",
  "issue #21; the final stage is stretched to sim_duration, so the held value runs for the whole stretch",
  data.frame(time_days = c(0, 2, 2), temperature = c(4, 20, 30)), 5,
  note = "held 3 d past a 2 d span: ")

# S1.5.tie_subsec, the case the nudge cap exists for. Readings one second apart are
# 1.157e-5 d, so the flat 1e-5 d epsilon append_profile_segment() uses is most of a
# sampling interval. Capping the nudge only at "does not collide with the next row"
# is not enough: half a gap smeared the step badly enough to put the growth 9.7% off
# what the CSV means. Codex asked for this case by name on PR #22.
tie_check(
  "S1.5.tie_subsec",
  "the de-tie nudge stays negligible on a profile sampled every second",
  "issue #21; the nudge is capped at max_share of the gap, so a dense profile shrinks it rather than colliding",
  data.frame(time_days = c(0, 1, 1, 2, 3, 4) * 1.157407e-5,
             temperature = c(2, 2, 25, 25, 25, 25)), 4.63e-5,
  note = "1 s sampling: ")

# S1.5.tie_unsorted, ordering. stage_growth_integral() sorts and
# build_env_conditions() does not, so an out-of-order CSV was its own divergence
# between the same two halves, by the same mechanism as a tie.
tie_check(
  "S1.5.tie_unsorted",
  "an out-of-order CSV reaches both integrators in the order its timestamps mean",
  "issue #21; stage_growth_integral() sorts while build_env_conditions() does not",
  data.frame(time_days = c(0.5, 1, 0, 0.5), temperature = c(25, 25, 2, 2)), 1,
  note = "rows shuffled: ")

# S1.5.tie_flat, the tie that must stay harmless. resize_profile() duplicates the
# final timestamp when it extends a stage, and both rows carry the same temperature,
# so the step reading and the collapsed reading coincide. Any de-tying fix must
# leave this alone rather than trade one divergence for another. Measured on
# resize_profile()'s own output, not on a hand-written stand-in.
tie_resize <- resize_profile(data.frame(time_days = c(0, 1), temperature = c(4, 8)),
                             2, "retail")
tie_resize_want <- tie_intended_integral(tie_resize, 3)
tie_resize_buch <- stage_growth_integral(normalise_profile(tie_resize))(3)
tie_resize_ode <- tie_ode_integral(normalise_profile(tie_resize), 3)

record(
  id = "S1.5.tie_flat", defect = "tie-collapse", seam = "profile construction",
  claim = "resize_profile()'s same-temperature tie stays harmless",
  source_ref = "utils/temperature.R appends at exactly the old end; a tie is harmless when both rows carry one temperature",
  passed = max(abs(c(tie_resize_buch, tie_resize_ode) - tie_resize_want)) /
    tie_resize_want < 1e-3,
  observed = sprintf("extension means %.4f; Buchanan %.4f, ODE %.4f (worst %.4f%% off)",
                     tie_resize_want, tie_resize_buch, tie_resize_ode,
                     100 * max(abs(c(tie_resize_buch, tie_resize_ode) - tie_resize_want)) /
                       tie_resize_want),
  expected = "both integrators within 0.1% of the extension's own temperature"
)

# Profile timestamps must survive parsing at full resolution. parse_time_to_days()
# keeps whichever format parses the MOST values, so one unparseable row demotes the
# whole column to a coarser format. The consumer profile lost a single
# daylight-saving gap timestamp and collapsed from 672 distinct times to 29 days.
for (s in config$stage_order) {
  path <- config$temperature_stages[[s]]$path
  if (is.null(path) || !file.exists(path)) next
  raw <- read.csv(path, stringsAsFactors = FALSE)
  n_distinct_times <- length(unique(parse_time_to_days(raw$time)))
  record(
    id = sprintf("S1.6.%s", s), defect = "time-parse", seam = "profile CSV",
    claim = sprintf("'%s' profile keeps its timestamp resolution", s),
    source_ref = "parse_time_to_days() picks the format parsing the most values, so one bad row demotes the column",
    passed = n_distinct_times == nrow(raw),
    observed = sprintf("%d rows, %d distinct timestamps", nrow(raw), n_distinct_times),
    expected = sprintf("%d distinct timestamps", nrow(raw))
  )
}

# A user-supplied profile must reach the solver as a SERIES, not as its average.
#
# Seam 3 cannot see this one. Before the fix, profile_csv on a static stage left the
# stage in static mode, so the Buchanan half and the ODE half both read the same
# scalar and agreed perfectly -- while both ignored the series. An invariant that
# says "the two halves agree" is blind to a defect that makes them equally wrong.
# This compares against the user's INPUT instead.
#
# The fixture's arithmetic mean is deliberately set to the stage's own configured
# mean. A code path that keeps only the summary therefore moves nothing at all, so
# a pass cannot come from the duration change alone.
csv_stage <- Filter(
  function(s) config$temperature_stages[[s]]$mode != "dynamic", config$stage_order)[[1]]
csv_fixture <- tempfile(fileext = ".csv")
csv_t <- seq(0, 0.5, length.out = 51)
csv_temp <- ifelse(csv_t > 0.2 & csv_t < 0.3, 25.5, 6.5)
csv_temp <- csv_temp + (config$temperature_stages[[csv_stage]]$mean - mean(csv_temp))
write.csv(data.frame(time_days = csv_t, temperature = csv_temp), csv_fixture,
          row.names = FALSE)

csv_sc <- resolve_scenario(
  config, load_baseline_profiles(config$temperature_stages),
  read.csv("input_data/ppc_st_frequency.csv"), list(),
  setNames(list(list(type = "profile_csv", path = csv_fixture)), csv_stage))

csv_row <- data.frame(lot_id = 1L, unit_id = 1L)
for (s in csv_sc$config$stage_order) {
  csv_row[[csv_sc$config$stage_to_cols[[s]]$temp]] <- csv_sc$config$temperature_stages[[s]]$mean
  csv_row[[csv_sc$config$stage_to_cols[[s]]$time]] <- csv_sc$config$temperature_stages[[s]]$duration
}
csv_env <- build_env_conditions(1, csv_row, csv_sc$temp_profiles, csv_sc$config)
csv_f <- suppressWarnings(approxfun(csv_env$time, csv_env$temperature, rule = 2))
csv_start <- sum(sapply(
  config$stage_order[seq_len(match(csv_stage, config$stage_order) - 1)],
  function(s) csv_sc$config$temperature_stages[[s]]$duration))
csv_seen <- max(csv_f(seq(csv_start + 1e-4, csv_start + max(csv_t) - 1e-4,
                         length.out = 5001)))

record(
  id = "S1.7", defect = "profile_csv-reach", seam = "scenario resolution",
  claim = "a user-supplied profile reaches the solver as a series, not as its mean",
  source_ref = "build_env_conditions() and apply_effective_stage_durations() both gate on mode == 'dynamic'; scenarios/disruptions.R must promote the stage when it installs a CSV",
  passed = csv_seen > max(csv_temp) - 0.5,
  observed = sprintf("solver peaks at %.2f C over '%s'; the supplied series peaks at %.2f C (its mean, %.2f C, is the stage's own)",
                     csv_seen, csv_stage, max(csv_temp), mean(csv_temp)),
  expected = sprintf("solver sees the series' %.2f C peak", max(csv_temp))
)

# Shortening a stage must close it at the temperature the profile actually had
# there, not at whatever was last measured before the cut.
#
# Harmless on the shipped hourly profiles -- samples are close enough that the two
# agree to 0.0000 C -- so this is checked on the sparse data a user in situation B
# may well supply. Daily fridge readings are far more common than hourly ones.
rz_sparse <- data.frame(time_days = 0:5, temperature = c(4, 4.5, 6, 9, 7, 5))
rz_cut <- resize_profile(rz_sparse, -1.5, "verification")
rz_got <- rz_cut$temperature[nrow(rz_cut)]
rz_want <- approxfun(rz_sparse$time_days, rz_sparse$temperature)(3.5)
record(
  id = "S1.8", defect = "resize-cutoff", seam = "profile construction",
  claim = "shortening closes a profile at its interpolated temperature",
  source_ref = "resize_profile() truncates at new_end; the closing point must come from the ORIGINAL profile, not from the last retained sample",
  passed = abs(rz_got - rz_want) < 1e-9,
  observed = sprintf("daily readings cut to day 3.5 close at %.4f C", rz_got),
  expected = sprintf("%.4f C", rz_want)
)

# A spore_reduction intervention must reduce spore-forming genera only.
#
# Microfiltration and bactofugation act on spores, never on a vegetative cell.
# Reducing every row understates spoilage, and since the container-assembly fix a
# container inherits every genus row it carries, so more non-sporeformers reach the
# function than before. Checked on the shipped pools, which is where the share
# lives: 94.7% of the medium pool is non-Bacillus.
for (sr in list(list(nm = "medium", pool = pool_bclc), list(nm = "high", pool = pool_d))) {
  reduced <- apply_spore_reduction(sr$pool, 2.2, config$spore_forming_genera)
  nonspore <- !(sr$pool$Genus %in% config$spore_forming_genera)
  n_moved <- sum(abs(reduced$log10N0[nonspore] - sr$pool$log10N0[nonspore]) > 1e-9)
  record(
    id = sprintf("S1.9.%s", sr$nm), defect = "D12", seam = "pool CSV",
    claim = sprintf("spore_reduction leaves the %s pool's non-sporeformers alone", sr$nm),
    source_ref = "interventions.R:10-15 presets are microfiltration and bactofugation, which remove spores; docs/research/2026-08-06-port-audit.md D12",
    passed = n_moved == 0,
    observed = sprintf("%d of %d non-sporeformer rows reduced (%.1f%% of the pool)",
                       n_moved, sum(nonspore), 100 * sum(nonspore) / nrow(sr$pool)),
    expected = "0 non-sporeformer rows reduced"
  )
}

# =============================================================================
# SEAM 2: run_model() output
# =============================================================================
cat("\n========== SEAM 2: run_model() OUTPUT ==========\n\n")

cat("Running run_model() at default config...\n\n")
set.seed(42)
res <- run_model()
cr <- res$container_results

# container_results carries one row per pathway contribution per container-day
# (run_model.R:359-363 joins all_results to the container total), so additivity
# is visible as a row count.
non_ppc <- cr %>% filter(pathway != "PPC")
rows_per_container_day <- non_ppc %>%
  count(lot_id, unit_id, day, name = "n_contributions")
max_contrib <- if (nrow(rows_per_container_day) > 0) max(rows_per_container_day$n_contributions) else 0
mean_contrib <- if (nrow(rows_per_container_day) > 0) mean(rows_per_container_day$n_contributions) else 0

record(
  id = "S2.1", defect = "D1", seam = "run_model()",
  claim = "non-PPC containers carry more than one growth contribution",
  source_ref = "PPI_Digital-Interface/model/Model.R:216-222 -- mean 2.53 genera per container in the shipped pools",
  passed = max_contrib > 1,
  observed = sprintf("max %d contribution(s) per container-day, mean %.2f", max_contrib, mean_contrib),
  expected = "max > 1 (legacy mean is 2.53)"
)

# Beyond "more than one": the realised community size must match what the pools
# encode. A synthetic container inherits every row of its assigned source
# container, so the expected mean is the pooled rows-per-container, computed from
# the CSVs and independent of anything the model does.
contrib_per_source <- table(c(paste(pool_bclc$lot_id, pool_bclc$unit_id),
                              paste(pool_d$lot_id, pool_d$unit_id)))
expected_mean <- mean(contrib_per_source)
# 3 standard errors, for sampling n containers with replacement
se <- sd(contrib_per_source) / sqrt(nrow(rows_per_container_day) / length(unique(non_ppc$day)))
tol <- max(3 * se, 0.05)

record(
  id = "S2.3", defect = "D1", seam = "run_model()",
  claim = "realised community size matches the pools",
  source_ref = "derived from the shipped pool CSVs: total genus rows / distinct containers",
  passed = abs(mean_contrib - expected_mean) <= tol,
  observed = sprintf("%.3f contributions per container-day", mean_contrib),
  expected = sprintf("%.3f +/- %.3f", expected_mean, tol)
)

# Pathway is a property of a container's genera, not of its position in the
# frame. It must therefore not correlate with lot_id.
lots_per_pathway <- cr %>%
  group_by(pathway) %>%
  summarise(n_lots = n_distinct(lot_id), .groups = "drop")

for (i in seq_len(nrow(lots_per_pathway))) {
  pw <- lots_per_pathway$pathway[i]
  nl <- lots_per_pathway$n_lots[i]
  record(
    id = sprintf("S2.2.%d", i), defect = "D3", seam = "run_model()",
    claim = sprintf("pathway '%s' appears in every lot", pw),
    source_ref = "PPI_Digital-Interface/model/run_model.R -- legacy does not route containers to pathways at all",
    passed = nl == config$n_lots,
    observed = sprintf("%d of %d lots", nl, config$n_lots),
    expected = sprintf("%d of %d lots", config$n_lots, config$n_lots)
  )
}

cat("Pathway by lot:\n")
print(table(cr$lot_id, cr$pathway))
cat("\n")

# A scenario the API already exposes must not kill the run. At +5 C the ODE
# solver terminates early for some PPC containers; high_growth_pathway.R:61-87
# normalises every simulation to sim_duration+1 rows and then guards the count,
# so a shortfall is repaired or reported. The PPC pathway does neither.
cat("Re-running with a +5 C consumer temp_shift (D11 reproducer)...\n\n")
set.seed(42)
res_hot <- tryCatch(
  run_model(disruptions = list(consumer = list(type = "temp_shift", temp_delta = 5))),
  error = function(e) e
)

d11_source <- paste("high_growth_pathway.R:61-87 normalises each simulation to",
                    "sim_duration+1 rows and guards the count; ppc_pathway.R:100",
                    "rbinds them unchecked")
expected_days <- config$sim_duration + 1

if (inherits(res_hot, "error")) {
  record(
    id = "S2.5", defect = "D11", seam = "run_model()",
    claim = "run_model() survives a +5 C consumer temp_shift",
    source_ref = d11_source, passed = FALSE,
    observed = sprintf("error: %s", conditionMessage(res_hot)),
    expected = sprintf("completes, every container-pathway series %d days long", expected_days)
  )
} else {
  series <- res_hot$container_results %>%
    group_by(lot_id, unit_id, pathway) %>%
    summarise(n_days = n_distinct(day), .groups = "drop")
  n_bad <- sum(series$n_days != expected_days)
  record(
    id = "S2.5", defect = "D11", seam = "run_model()",
    claim = "run_model() survives a +5 C consumer temp_shift",
    source_ref = d11_source, passed = n_bad == 0,
    observed = sprintf("completed; %d of %d container-pathway series are not %d days",
                       n_bad, nrow(series), expected_days),
    expected = sprintf("completes, every container-pathway series %d days long", expected_days)
  )

  # Repairing a failed solve pads it flat at the last valid concentration. That is
  # only harmless above the spoilage threshold, where a flat tail cannot change
  # whether the container counts as spoiled. Below it, growth is understated and
  # the padded value is a fabrication that moves a reported number. Assert the
  # safe condition rather than assume it.
  n_repaired <- res_hot$diagnostics$ppc_solves_repaired
  tails <- res_hot$diagnostics$ppc_repaired_tail_log10
  worst <- if (length(tails) > 0) min(tails, na.rm = TRUE) else NA_real_

  record(
    id = "S2.8", defect = "D11", seam = "run_model()",
    claim = "early-terminated solves are padded only above the spoilage threshold",
    source_ref = "fix_simulation() (utils/growth_models.R:458) holds the last valid N flat; above the threshold that cannot change a spoilage decision",
    passed = n_repaired == 0 || all(tails > config$spoilage_threshold, na.rm = TRUE),
    observed = if (n_repaired == 0) {
      "0 solves repaired"
    } else {
      sprintf("%d solves repaired, lowest tail %.2f log10 against threshold %.2f",
              n_repaired, worst, config$spoilage_threshold)
    },
    expected = sprintf("every repaired solve above %.2f log10", config$spoilage_threshold)
  )
}

# Every pathway must respond to a temperature scenario. Asserting the aggregate
# median is not enough: it moves whenever PPC moves, which masks a pathway that
# ignores the scenario entirely. `consumer` is one of the four dynamic stages.
# +3 C, not +5: at +5 the PPC pathway dies on a row-count mismatch (D11 -- it
# lacks the padding and the guard that high_growth_pathway.R:61-87 has).
# Reproducer: run_model(disruptions = list(consumer = list(type = "temp_shift",
# temp_delta = 5))) at seed 42.
cat("Re-running with a +3 C consumer temp_shift to measure per-pathway reach...\n\n")
set.seed(42)
res_warm <- run_model(disruptions = list(consumer = list(type = "temp_shift", temp_delta = 3)))

pathway_median <- function(container_results, target_day) {
  container_results %>%
    filter(day == target_day) %>%
    group_by(pathway) %>%
    summarise(med = median(log10_concentration, na.rm = TRUE), .groups = "drop")
}

reach <- pathway_median(cr, 14) %>%
  inner_join(pathway_median(res_warm$container_results, 14),
             by = "pathway", suffix = c("_base", "_warm"))

for (i in seq_len(nrow(reach))) {
  # Signed: warming must RAISE concentration. A magnitude check would pass a sign
  # error, and for this tool a scenario reporting that heat reduces spoilage is the
  # one result that must never go green.
  moved <- reach$med_warm[i] - reach$med_base[i]
  record(
    id = sprintf("S2.4.%d", i), defect = "D6", seam = "run_model()",
    claim = sprintf("a consumer temp_shift reaches pathway '%s'", reach$pathway[i]),
    source_ref = "PPI_Digital-Interface/model/run_model.R:150-164 and :253-258 -- legacy writes stage overrides into the BCLc data, not only the D data",
    passed = moved > 0.01,
    observed = sprintf("day-14 median %.4f -> %.4f (moved %.4f log)",
                       reach$med_base[i], reach$med_warm[i], moved),
    expected = "day-14 median moves by > 0.01 log"
  )
}

# =============================================================================
# SUMMARY
# =============================================================================
# The reported pre-consumer window must be the one the simulation actually ran.
# Reporting sums cfg$temperature_stages[[s]]$duration (run_model.R:332-336) while
# the simulation derives each dynamic stage's span from its profile
# (utils/temperature.R), and nothing reconciles the two.
#
# The expected value is read straight from the profile CSVs' own timestamps, NOT by
# re-deriving effective_stage_duration(). An earlier version copied that function's
# logic, which made the check tautological AND unable to fail: once config.R's
# facility duration was corrected, the cfg sum and the profile sum agreed to
# 1.7e-5 d against a 0.05 d tolerance, so reverting the reporting fix left this
# green. Reading the CSVs is an independent source, and it stays independent if the
# config and the profiles diverge again.
harness_profiles <- load_baseline_profiles(config$temperature_stages)
simulated_pre_consumer <- sum(sapply(
  setdiff(config$stage_order, "consumer"),
  function(s) {
    path <- config$temperature_stages[[s]]$path
    if (!is.null(path) && file.exists(path)) {
      td <- parse_time_to_days(read.csv(path, stringsAsFactors = FALSE)$time)
      max(td) - min(td)
    } else {
      config$temperature_stages[[s]]$duration
    }
  }
))
reported_pre_consumer <- res$shelf_life$pre_consumer_days

record(
  id = "S2.6", defect = "D7", seam = "run_model()",
  claim = "reported pre-consumer window matches the simulated one",
  source_ref = "utils/temperature.R derives a dynamic stage's span from its profile; run_model.R:332-336 sums cfg durations instead",
  passed = abs(reported_pre_consumer - simulated_pre_consumer) < 0.05,
  observed = sprintf("reported %.4f d, simulated %.4f d (differ by %.4f)",
                     reported_pre_consumer, simulated_pre_consumer,
                     abs(reported_pre_consumer - simulated_pre_consumer)),
  expected = "agree to within 0.05 d"
)

# duration_delta must change the simulation, not only the reported shelf life.
#
# The stage has to be one whose neighbour runs at a different temperature, or the
# test is blind by construction: retail and consumer are both 6.50 C at baseline,
# so moving days between them changes no growth rate. processing_facility is
# 1.70 C against 4.55 C for the transport that follows, and holding milk longer in
# the cold facility is an improvement, so it is valid under ADR-003.
cat("\nRe-running with processing_facility duration_delta = +2 (D9 reproducer)...\n\n")
set.seed(42)
res_short <- run_model(
  interventions = list(stage_temp_overrides = list(
    processing_facility = list(duration_delta = 2))))

base_med14 <- median(cr$total_log10_N[cr$day == 14], na.rm = TRUE)
colder_med14 <- median(res_short$container_results$total_log10_N[
  res_short$container_results$day == 14], na.rm = TRUE)

# Signed: the 2 extra days are spent at the 1.70 C facility instead of at the
# 6.50 C consumer stage the run would otherwise have extended, so growth must
# FALL. A magnitude check accepts a regression that shortens the facility profile,
# extends the wrong stage, or otherwise makes a cold-chain improvement read as more
# spoilage -- the direction that must never pass quietly here.
moved <- base_med14 - colder_med14

record(
  id = "S2.7", defect = "D9", seam = "run_model()",
  claim = "duration_delta changes the simulation, not just the report",
  source_ref = "scenarios/interventions.R:96-99 writes only cfg duration; scenarios/disruptions.R:35-59 shows the idiom, extending the profile as well",
  passed = moved > 0.01,
  observed = sprintf("day-14 median total %.4f -> %.4f (fell %.4f log); reported pre_consumer %.3f -> %.3f d",
                     base_med14, colder_med14, moved,
                     reported_pre_consumer, res_short$shelf_life$pre_consumer_days),
  expected = "day-14 median total FALLS by > 0.01 log"
)

# The other direction of the same key: a duration_delta that takes a stage to zero
# or below must be refused, on a static stage as well as a dynamic one.
#
# The guard used to live inside resize_profile(), which apply_stage_temp_overrides()
# calls only when the stage has a profile, so a static stage walked past it and wrote
# the non-positive duration. transportation_retail_to_home is the shipped stage with
# no measured profile and the shortest duration (0.0400 d), so -0.04 wrote exactly 0.
# pre_consumer_days sums the four pre-consumer durations and took that value straight
# through, reporting a supply-chain window shorter than the stages composing it, while
# container durations are clamped elsewhere -- so the simulated growth and the reported
# window stopped describing the same supply chain. No error and no warning (#51).
#
# Checked through run_model() rather than the scenario function, because that is the
# path the API drives and the only one this file can see.
guard_static <- try(run_model(interventions = list(stage_temp_overrides = list(
  transportation_retail_to_home = list(duration_delta = -0.04)))), silent = TRUE)
guard_dynamic <- try(run_model(interventions = list(stage_temp_overrides = list(
  consumer = list(duration_delta = -100)))), silent = TRUE)
guard_ok <- try(run_model(interventions = list(stage_temp_overrides = list(
  consumer = list(duration_delta = -1)))), silent = TRUE)

record(
  id = "S2.14", defect = "#51", seam = "run_model()",
  claim = "a duration_delta to a non-positive duration is refused in both stage modes",
  source_ref = "utils/temperature.R stop_if_nonpositive_duration(), called by scenarios/interventions.R before the write and by resize_profile() on the profile span",
  passed = inherits(guard_static, "try-error") && inherits(guard_dynamic, "try-error") &&
           !inherits(guard_ok, "try-error"),
  observed = sprintf("static -0.04: %s; dynamic -100: %s; valid -1: %s",
                     if (inherits(guard_static, "try-error")) "refused" else
                       sprintf("ACCEPTED, pre_consumer %.4f d", guard_static$shelf_life$pre_consumer_days),
                     if (inherits(guard_dynamic, "try-error")) "refused" else "ACCEPTED",
                     if (inherits(guard_ok, "try-error")) "REFUSED" else "ran"),
  expected = "both non-positive deltas refused; a shortening that stays positive still runs"
)

# The same sign error one layer down, on the disruption side, where the trigger is
# the SIGN of the appended segment rather than the resulting stage duration.
#
# append_profile_segment() computed the segment's end as start + duration without
# checking the sign, so a negative one landed the closing row BEFORE the opening row
# and nothing sorted afterwards. The two integrators then read the same stored rows
# differently -- stage_growth_integral() sorts, so the appended temperature moved to
# the FRONT of the stage, while build_env_conditions() splices in stored order and
# takes the span from max(time_days) alone. Measured on transportation_retail_to_home
# with duration_delta = -0.5: sorted, the stage spans 0.50001 d and opens at 20 C; in
# stored order, 0.04001 d opening at 8.5 C. No error and no warning (#52). No
# end-to-end divergence figure is quoted, deliberately -- see append_profile_segment()
# for why the obvious one measures a single reader twice.
#
# Not the ADR 007 class, despite being the same two integrators: there the stage TOTAL
# survives and the trajectory inside it does not, which is what blinds a total-comparing
# check. Here the totals diverge, so Seam 3 would catch it -- Seam 3 just never sends a
# negative delta. Hence a check here rather than another row of that matrix.
#
# S2.14 does not cover this and this does not cover S2.14. That guard fires on the
# resulting DURATION, so the -1e-9 case below walks straight past it: consumer holds its
# full 27.9583 d and the profile still came back out of order. Both are checked for that
# reason, and the temp_spike case is on a DYNAMIC stage to pin that the defect is not
# about synthesised static-stage profiles.
#
# Zero is checked too, so the boundary the guard draws is asserted where the gate can
# see it rather than only in test_disruptions.R, which this suite does not run.
#
# A sub-epsilon POSITIVE duration is checked as well, because rejecting the sign is
# not on its own enough to keep the rows in order. The offset placing the opening row
# used to be a flat 1e-5 d, so 0 < duration < 1e-5 put the closing row first and
# rebuilt the same malformed profile from a value the guard accepts. It moves no
# prediction -- the swapped rows carry the same temperature, so both readers saw one
# 0.04001 d stage and agreed to 0.000e+00 -- so this asserts the ORDER directly rather
# than looking for a divergence there is none of. Raised as a P2 on PR #55.
guard_subeps <- try(run_model(disruptions = list(
  transportation_retail_to_home = list(
    type = "delay", temp = 20, duration_delta = 1e-6))), silent = TRUE)
subeps_ordered <- NA
if (!inherits(guard_subeps, "try-error")) {
  subeps_profile <- append_profile_segment(
    data.frame(time_days = c(0, 0.04), temperature = c(8.5, 8.5)),
    20, 1e-6, "transportation_retail_to_home")
  # strictly = TRUE: the plain form reports a TIE as sorted, and a tie is the other
  # half of this defect -- the duplicate timestamp approxfun() averages. Halving the
  # offset does not survive the addition for a small enough duration, so the guard
  # refuses those outright and this asserts it.
  subeps_ordered <- !is.unsorted(subeps_profile$time_days, strictly = TRUE)
}
guard_absorbed <- try(run_model(disruptions = list(
  transportation_retail_to_home = list(
    type = "delay", temp = 20, duration_delta = 1e-17))), silent = TRUE)

guard_delay <- try(run_model(disruptions = list(
  transportation_retail_to_home = list(
    type = "delay", temp = 20, duration_delta = -0.5))), silent = TRUE)
guard_tiny <- try(run_model(disruptions = list(
  consumer = list(type = "delay", temp = 20, duration_delta = -1e-9))), silent = TRUE)
guard_spike <- try(run_model(disruptions = list(
  retail = list(type = "temp_spike", temp = 25, duration = -0.5))), silent = TRUE)
guard_zero <- try(run_model(disruptions = list(
  consumer = list(type = "delay", temp = 20, duration_delta = 0))), silent = TRUE)
guard_pos <- try(run_model(disruptions = list(
  transportation_retail_to_home = list(
    type = "delay", temp = 20, duration_delta = 0.5))), silent = TRUE)

record(
  id = "S2.15", defect = "#52", seam = "run_model()",
  claim = "an appended segment is refused when non-positive, and stays in timestamp order when positive",
  source_ref = "utils/temperature.R append_profile_segment() guards the sign once and bounds the opening offset by the segment's own duration, because delay and temp_spike are the same operation differing only in key name (#36)",
  passed = inherits(guard_delay, "try-error") && inherits(guard_tiny, "try-error") &&
           inherits(guard_spike, "try-error") && inherits(guard_zero, "try-error") &&
           !inherits(guard_pos, "try-error") &&
           !inherits(guard_subeps, "try-error") && isTRUE(subeps_ordered) &&
           inherits(guard_absorbed, "try-error"),
  observed = sprintf("delay -0.5 (static): %s; delay -1e-9 (dynamic, duration stays positive): %s; temp_spike -0.5 (dynamic): %s; delay 0: %s; delay +0.5: %s; delay +1e-6 (sub-epsilon): %s, rows strictly ordered: %s; delay +1e-17 (absorbed by the addition): %s",
                     if (inherits(guard_delay, "try-error")) "refused" else "ACCEPTED",
                     if (inherits(guard_tiny, "try-error")) "refused" else "ACCEPTED",
                     if (inherits(guard_spike, "try-error")) "refused" else "ACCEPTED",
                     if (inherits(guard_zero, "try-error")) "refused" else "ACCEPTED",
                     if (inherits(guard_pos, "try-error")) "REFUSED" else "ran",
                     if (inherits(guard_subeps, "try-error")) "REFUSED" else "ran",
                     if (isTRUE(subeps_ordered)) "yes" else "NO",
                     if (inherits(guard_absorbed, "try-error")) "refused" else "ACCEPTED"),
  expected = "non-positive and absorbed durations refused; both usable positive delays run, and the sub-epsilon one keeps its rows strictly ordered"
)

# Growth must continue to the end of the run. The Buchanan model stops at its last
# stage boundary, while the ODE pathways continue at the final profile temperature,
# so if the stages do not cover sim_duration a medium-growth container sits
# artificially flat for the final days. That delays or erases a shelf-life crossing
# late in the run -- exactly where a strong intervention pushes it.
# Compare the final window against the one before it. A flat absolute figure is not
# enough: growth naturally varies, and the static stage's per-container t_T2 leaves
# a little growth past the boundary either way. The ratio is what exposes a cap.
end_h <- config$sim_duration
win <- function(pw, a, b) {
  ma <- median(cr$log10_concentration[cr$pathway == pw & cr$day == a], na.rm = TRUE)
  mb <- median(cr$log10_concentration[cr$pathway == pw & cr$day == b], na.rm = TRUE)
  mb - ma
}

# Buchanan pathway only. The ODE pathways have no stage boundary to stop at -- they
# hold the final profile temperature and keep integrating -- so their late
# deceleration is Nmax saturation, not a cap. Measured: high_growth's ratio is 0.368
# where medium_growth's cap gives 0.066, an order of magnitude apart.
for (pw in intersect(unique(cr$pathway), "medium_growth")) {
  before <- win(pw, end_h - 8, end_h - 4)
  after <- win(pw, end_h - 4, end_h)
  ratio <- if (before > 0) after / before else NA_real_
  record(
    id = sprintf("S2.9.%s", pw), defect = "P1-horizon", seam = "run_model()",
    claim = sprintf("pathway '%s' keeps growing to the simulation horizon", pw),
    source_ref = "stage durations must cover cfg$sim_duration; simulate_growth_row() caps time in each stage, so growth stops at the last stage boundary",
    passed = !is.na(ratio) && ratio >= 0.5,
    observed = sprintf("grew %.4f log over days %d-%d, then %.4f over %d-%d (ratio %.3f)",
                       before, end_h - 8, end_h - 4, after, end_h - 4, end_h, ratio),
    expected = "final window at least half the preceding window"
  )
}

# A temp_spike appends only two profile points for the whole added interval. An
# arithmetic row mean therefore gives a multi-day hot segment the weight of two
# samples, so the medium-growth pathway barely responds while the ODE pathways
# integrate the segment in full. The medium pathway now integrates the segment too
# (stage_growth_integral), which is what makes the two halves feel the same heat.
# Weighting by elapsed time alone still lost 47% of this spike's growth, because
# muAtNewTemp() squares (T - T0); S3 is what asserts that half.
cat("\nRe-running with a 25 C / 0.5 d facility temp_spike (weighting reproducer)...\n\n")
set.seed(42)
res_spike <- run_model(
  disruptions = list(processing_facility = list(
    type = "temp_spike", temp = 25, duration = 0.5)))

spike_med <- pathway_median(res_spike$container_results, 14) %>%
  inner_join(pathway_median(cr, 14), by = "pathway", suffix = c("_spike", "_base"))

for (i in seq_len(nrow(spike_med))) {
  pw <- spike_med$pathway[i]
  # Signed, not absolute. Under a row mean the spike barely raises the temperature
  # but still lengthens the stage, so a heat excursion comes back as LESS spoilage.
  # A magnitude-only check accepts that, which for a food-safety tool is the one
  # direction that must never pass quietly.
  moved <- spike_med$med_spike[i] - spike_med$med_base[i]
  record(
    id = sprintf("S2.10.%s", pw), defect = "P1-weighting", seam = "run_model()",
    claim = sprintf("a 25 C facility temp_spike raises pathway '%s'", pw),
    source_ref = "scenarios/disruptions.R:35-43 appends 2 points for the whole spike; a row mean weights it ~150x too lightly against a time-weighted mean",
    passed = moved > 0.05,
    observed = sprintf("day-14 median %.4f -> %.4f (%+.4f log)",
                       spike_med$med_base[i], spike_med$med_spike[i], moved),
    expected = "day-14 median RISES by > 0.05 log"
  )
}

# Scenarios targeting the STATIC stage must reach every pathway too. That stage has
# no profile, so its conditions live on the synthetic container frame sampled from
# config. Pool-derived rows keep their own T_T2/t_T2 unless those columns are copied
# across, which leaves both non-PPC pathways deaf to any static-stage scenario --
# and transportation_retail_to_home is the delivery leg, so a delay there is an
# obvious thing for a user to ask about.
static_stage <- Filter(
  function(s) {
    sc <- config$temperature_stages[[s]]
    sc$mode != "dynamic" || is.null(harness_profiles[[s]])
  },
  config$stage_order)[[1]]

cat(sprintf("\nRe-running with a 2-day delay on the static stage '%s'...\n\n", static_stage))
# temp = 20, deliberately NOT the stage's configured 8.5 C. A delay held at the
# stage's own mean tests only the duration, which is how the dropped delay
# temperature (D10) survived an earlier check.
delay_spec <- list(list(type = "delay", temp = 20, duration_delta = 2))
names(delay_spec) <- static_stage
set.seed(42)
res_delay <- run_model(disruptions = delay_spec)

delay_med <- pathway_median(res_delay$container_results, 14) %>%
  inner_join(pathway_median(cr, 14), by = "pathway", suffix = c("_delay", "_base"))

for (i in seq_len(nrow(delay_med))) {
  pw <- delay_med$pathway[i]
  moved <- delay_med$med_delay[i] - delay_med$med_base[i]
  # (the reach checks below; the span check follows the loop)
  record(
    id = sprintf("S2.11.%s", pw), defect = "D8", seam = "run_model()",
    claim = sprintf("a 20 C static-stage delay raises pathway '%s'", pw),
    source_ref = "the static stage has no profile, so its conditions live on the synthetic container frame (run_model.R:119-136), not on the pool row",
    # Signed: a 20 C delay on an 8.5 C stage must raise concentration
    passed = moved > 0.01,
    observed = sprintf("day-14 median %.4f -> %.4f (%+.4f log)",
                       delay_med$med_base[i], delay_med$med_delay[i], moved),
    expected = "day-14 median moves by > 0.01 log"
  )
}

# A disruption must be applied once. Synthesising a profile for a static stage after
# its config duration has already been extended covers the extension and then appends
# it again, so the stage is simulated for duration + 2 * delta while the config
# reports duration + delta. The reach checks above cannot see that -- growth moves
# either way, just too much.
delay_days <- 2
expected_pre_consumer <- reported_pre_consumer + delay_days
record(
  id = "S2.11.span", defect = "D10-regression", seam = "run_model()",
  claim = "a static-stage delay extends the window once, not twice",
  source_ref = "ensure_stage_profile() must synthesise from the stage's ORIGINAL duration; scenarios/disruptions.R extends cfg duration before calling it",
  passed = abs(res_delay$shelf_life$pre_consumer_days - expected_pre_consumer) < 0.01,
  observed = sprintf("pre-consumer %.4f d, baseline %.4f + %d d delay",
                     res_delay$shelf_life$pre_consumer_days, reported_pre_consumer, delay_days),
  expected = sprintf("%.4f d", expected_pre_consumer)
)

# A temp_spike on the STATIC stage must apply its heat, not only its duration.
# disruptions.R:33-34 stores the spike temperature in a config key nothing reads,
# so the stage lengthens at its original temperature and the heat is dropped.
#
# Differential test: two spikes of identical duration, one hot and one cold. If the
# temperature reaches the simulation, hot must produce more growth than cold. If it
# is dropped, the two runs are identical -- which a single-run check comparing
# against baseline could not distinguish from the duration effect alone.
cat(sprintf("\nRe-running static-stage temp_spike, 25 C vs 0 C, on '%s'...\n\n", static_stage))
spike_hot <- list(list(type = "temp_spike", temp = 25, duration = 0.5))
spike_cold <- list(list(type = "temp_spike", temp = 0, duration = 0.5))
names(spike_hot) <- static_stage
names(spike_cold) <- static_stage

set.seed(42)
res_static_hot <- run_model(disruptions = spike_hot)
set.seed(42)
res_static_cold <- run_model(disruptions = spike_cold)

static_spike <- pathway_median(res_static_hot$container_results, 14) %>%
  inner_join(pathway_median(res_static_cold$container_results, 14),
             by = "pathway", suffix = c("_hot", "_cold"))

for (i in seq_len(nrow(static_spike))) {
  pw <- static_spike$pathway[i]
  gap <- static_spike$med_hot[i] - static_spike$med_cold[i]
  record(
    id = sprintf("S2.12.%s", pw), defect = "D10", seam = "run_model()",
    claim = sprintf("a static-stage temp_spike applies its heat to pathway '%s'", pw),
    source_ref = "scenarios/disruptions.R:33-34 writes a $spike key nothing reads when the stage has no profile, so only the duration extension survives",
    passed = gap > 0.01,
    observed = sprintf("day-14 median, 25 C %.4f vs 0 C %.4f (gap %+.4f log)",
                       static_spike$med_hot[i], static_spike$med_cold[i], gap),
    expected = "hot spike exceeds cold spike by > 0.01 log"
  )
}

# Heat that arrives after the last reported day must not move a reported figure --
# and must still land where it was applied.
#
# A temp_spike is appended to the END of its stage. The consumer stage runs from day
# 8.25 to day 36.21, so a spike there begins after day 35, the last reported day.
# Under one growth-equivalent temperature per stage that heat was spread evenly
# across all 27.96 days, and the model reported up to 10.5 pp of day-28 and day-35
# spoilage that had not happened. That figure is quoted in ADR 007 and carried into
# the paper's Limitations, so it needs a check rather than a one-off measurement.
#
# Both halves are load-bearing. The first alone would pass a model that dropped the
# spike entirely; the second alone would pass the defect this replaced.
cat("\nRe-running with a 25 C / 2 d consumer temp_spike (post-horizon reproducer)...\n\n")
set.seed(42)
res_late <- run_model(disruptions = list(consumer = list(
  type = "temp_spike", temp = 25, duration = 2)))

late_start <- sum(sapply(config$stage_order, function(s)
  effective_stage_duration(s, load_baseline_profiles(config$temperature_stages), config)))
late_reported <- inner_join(
  res$daily_median_spoilage %>% filter(day %in% config$output_days),
  res_late$daily_median_spoilage %>% filter(day %in% config$output_days),
  by = "day", suffix = c("_base", "_late"))
late_moved <- max(abs(late_reported$median_pct_late - late_reported$median_pct_base))

late_end <- pathway_median(res_late$container_results, config$sim_duration) %>%
  inner_join(pathway_median(cr, config$sim_duration), by = "pathway",
             suffix = c("_late", "_base"))
late_gap <- late_end$med_late[late_end$pathway == "medium_growth"] -
  late_end$med_base[late_end$pathway == "medium_growth"]

record(
  id = "S2.13", defect = "P1-trajectory", seam = "run_model()",
  claim = "heat after the last reported day moves no reported figure, and still lands",
  source_ref = "docs/adr/007-buchanan-integrated-exactly.md; a temp_spike appends to the end of its stage, and the consumer stage ends at day 36.21",
  passed = late_start > max(config$output_days) && late_moved < 0.01 && late_gap > 0.01,
  observed = sprintf("spike starts day %.2f; worst reported median moved %.4f pp; day-%d medium_growth median %+.4f log",
                     late_start, late_moved, config$sim_duration, late_gap),
  expected = sprintf("spike starts after day %d, no reported median moves, day-%d median rises",
                     max(config$output_days), config$sim_duration)
)

# =============================================================================
# SEAM 3: the two halves of the model must agree on what a scenario was
# =============================================================================
#
# The Buchanan pathway reads per-stage scalars off the container row; the ODE
# pathways integrate a spliced time/temperature series. Every scenario-reach defect
# found in this work was one violation of that agreement -- D6 (medium never saw
# config), D8 (neither non-PPC pathway saw the static stage), D10 (nobody saw the
# spike temperature), the appended-segment tie collapse, and the stage-boundary tie
# collapse underneath them all.
#
# Checking each control individually is how those were found one at a time, each
# fix leaving the neighbouring case standing. This checks the invariant across the
# whole control x stage-mode matrix instead. It needs no simulation, so it is fast.
#
# Compared in GROWTH space, not temperature space. Agreeing on mean temperature is
# the weaker claim and it is blind to the defect that matters: muAtNewTemp() squares
# (T - T0), so two thermal histories can share a mean temperature and imply
# different growth. This matrix agreed to 0.0001 C on every row while the Buchanan
# pathway was losing 47% of the growth in a 25 C spike. The two halves of the model
# must agree on what a scenario DID, and growth is what they compute. The Buchanan
# pathway holds no per-stage temperature at all any more, so there is no longer a
# temperature figure to report here.
#
# What this matrix compares is a stage TOTAL, which is blind to the trajectory
# inside a stage by construction -- see verification/test_buchanan_trajectory.R,
# which asserts the whole curve. Extend that suite for anything shape-dependent;
# extend this one for anything about a scenario reaching both halves.
#
# A scenario that runs PAST the horizon does not belong in this matrix: the two
# sides would then average growth over windows of different lengths. The span
# assertion below is what catches that. The trajectory suite covers those cases.
cat("\n========== SEAM 3: PATHWAY AGREEMENT MATRIX ==========\n\n")

agree_static <- "transportation_retail_to_home"
agree_dyn <- "processing_facility"

agree_container <- function(cfg) {
  d <- data.frame(lot_id = 1L, unit_id = 1L)
  for (s in cfg$stage_order) {
    sc <- cfg$temperature_stages[[s]]; cols <- cfg$stage_to_cols[[s]]
    d[[cols$temp]] <- sc$mean
    d[[cols$time]] <- sc$duration
  }
  for (s in cfg$stage_order) {
    sc <- cfg$temperature_stages[[s]]
    if (!is.null(sc$temp_max)) {
      d[[cfg$stage_to_cols[[s]]$temp]] <- pmin(d[[cfg$stage_to_cols[[s]]$temp]], sc$temp_max)
    }
  }
  d
}

agree_check <- function(label, interventions = list(), disruptions = list()) {
  sc <- resolve_scenario(config, load_baseline_profiles(config$temperature_stages),
                         read.csv("input_data/ppc_st_frequency.csv"),
                         interventions, disruptions)
  cfg <- sc$config; profiles <- sc$temp_profiles

  row <- agree_container(cfg)
  row <- apply_static_stage_conditions(row, row, profiles, cfg)

  # ODE view: integrate the spliced series over the full horizon. approxfun uses
  # rule = 2, so it holds the final temperature past the last stage boundary --
  # which is why apply_effective_stage_durations extends Buchanan's final stage to
  # match. Both views must therefore cover 0..sim_duration.
  env <- build_env_conditions(1, row, profiles, cfg)
  f <- suppressWarnings(approxfun(env$time, env$temperature, rule = 2))
  grid <- seq(0, cfg$sim_duration, length.out = 40001)
  # oldMu = 1, so muAtNewTemp returns the growth-rate multiplier itself. It is
  # linear in oldMu, so the comparison holds for any container's growthrate.
  ode_growth <- mean(muAtNewTemp(f(grid), 1))

  # Buchanan view: the same quantity as the pathway accumulates it -- a dynamic
  # stage's profile integrated over the stage, a static stage's single temperature
  # times its duration. Independent of the ODE view above: analytic segment
  # arithmetic against numeric quadrature of the spliced series.
  buch <- apply_effective_stage_durations(row, profiles, cfg)
  temps <- sapply(cfg$stage_order, function(s) buch[[cfg$stage_to_cols[[s]]$temp]][1])
  durs <- sapply(cfg$stage_order, function(s) buch[[cfg$stage_to_cols[[s]]$time]][1])
  mu_coef <- 1 / (eval(formals(muAtNewTemp)$oldTemp) - eval(formals(muAtNewTemp)$T0))^2
  buch_stage <- sapply(seq_along(cfg$stage_order), function(j) {
    s <- cfg$stage_order[j]
    sc <- cfg$temperature_stages[[s]]
    if (sc$mode == "dynamic" && !is.null(profiles[[s]])) {
      mu_coef * stage_growth_integral(profiles[[s]])(durs[j])
    } else {
      muAtNewTemp(temps[j], 1) * durs[j]
    }
  })
  buch_growth <- sum(buch_stage) / sum(durs)

  # 0.05% relative. The 40001-point grid puts the discretisation floor below
  # 0.005%; the weighting defect this replaced showed 0.11% on its mildest row
  # (a static-stage delay) and 7.62% on its worst.
  rel <- abs(buch_growth - ode_growth) / ode_growth

  record(
    id = sprintf("S3.%s", gsub("[^A-Za-z0-9]", "", label)), defect = "agreement",
    seam = "scenario resolution",
    claim = sprintf("pathways agree on the growth implied by '%s'", label),
    source_ref = "Buchanan reads per-stage scalars; the ODE integrates the spliced series -- a scenario must reach both identically",
    passed = rel < 0.0005 && abs(sum(durs) - cfg$sim_duration) < 0.05,
    observed = sprintf("Buchanan mu x%.4f over %.2f d, ODE mu x%.4f (apart by %.3f%%)",
                       buch_growth, sum(durs), ode_growth, 100 * rel),
    expected = "mean growth rate within 0.05%, both covering the full horizon"
  )
}

# profile_csv fixtures. Short, so the final stage still has a horizon to cover --
# a long one would leave no shortfall and quietly skip the case that matters.
agree_csv_short <- tempfile(fileext = ".csv")
acs_t <- seq(0, 0.5, length.out = 51)
write.csv(data.frame(time_days = acs_t,
                     temperature = ifelse(acs_t > 0.2 & acs_t < 0.3, 22, 5)),
          agree_csv_short, row.names = FALSE)

# A recording that ends warm, and one that runs past the day-40 horizon, used to be
# checked here. Both were about a single per-stage scalar being taken from the wrong
# span -- the stretch to the horizon holding the recorded span's average instead of
# the ODE's final temperature (61% apart on implied growth), and an unreachable tail
# driving growth the run never gets to (111% too high warm, 17% too low cold). There
# is no such scalar now, and a stage total cannot see where inside a stage the heat
# fell anyway. verification/test_buchanan_trajectory.R carries both cases as the
# short_warm_tail and past_horizon_warm/cold shapes, per reported day.

agree_check("baseline")
for (stg in c(agree_dyn, agree_static)) {
  tag <- if (stg == agree_dyn) "dynamic" else "static"
  agree_check(sprintf("profile_csv %s", tag),
              disruptions = setNames(list(list(type = "profile_csv", path = agree_csv_short)), stg))
  agree_check(sprintf("temp_shift %s", tag),
              disruptions = setNames(list(list(type = "temp_shift", temp_delta = 5)), stg))
  agree_check(sprintf("temp_spike %s", tag),
              disruptions = setNames(list(list(type = "temp_spike", temp = 25, duration = 0.5)), stg))
  agree_check(sprintf("delay %s", tag),
              disruptions = setNames(list(list(type = "delay", temp = 20, duration_delta = 2)), stg))
  agree_check(sprintf("temp_delta %s", tag),
              interventions = list(stage_temp_overrides = setNames(list(list(temp_delta = -2)), stg)))
  agree_check(sprintf("duration_delta %s", tag),
              interventions = list(stage_temp_overrides = setNames(list(list(duration_delta = 1)), stg)))
  agree_check(sprintf("temp_max %s", tag),
              interventions = list(stage_temp_overrides = setNames(list(list(temp_max = 6)), stg)))
}

cat("\n========== SUMMARY ==========\n\n")

n_pass <- sum(vapply(checks, function(c) isTRUE(c$passed), logical(1)))
n_fail <- length(checks) - n_pass

cat(sprintf("%-8s %-6s %-10s %s\n", "CHECK", "DEFECT", "RESULT", "CLAIM"))
cat(paste(rep("-", 88), collapse = ""), "\n")
for (c in checks) {
  cat(sprintf("%-8s %-6s %-10s %s\n", c$id, c$defect,
              if (isTRUE(c$passed)) "PASS" else "FAIL", c$claim))
}
cat(paste(rep("-", 88), collapse = ""), "\n")
cat(sprintf("%d passed, %d failed, %d total\n\n", n_pass, n_fail, length(checks)))

# ---------------------------------------------------------------------------
# Not yet asserted -- see docs/research/2026-08-06-port-audit.md
#   D12 spore_reduction applied to every pool row regardless of genus
#   D13, D14 -- see KANBAN.md
# D6, D7 and D9 are now asserted by S2.4, S2.6 and S2.7 respectively.
#
# Still missing, and the largest gap: a container-level comparison against the
# legacy PPI log10sumN output. Everything here compares the port against the pools
# and against itself. See issue #17.
# ---------------------------------------------------------------------------

plan(sequential)

if (n_fail > 0) {
  cat("Structural verification FAILED.\n")
  quit(status = 1)
}
cat("Structural verification passed.\n")
