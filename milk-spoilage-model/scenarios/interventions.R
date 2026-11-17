# Intervention System
# Modifies config, temperature profiles, and pool data to model improvements.

library(dplyr)

# =============================================================================
# Category A: Spore Reduction
# =============================================================================

# Log reductions of spores achieved by each physical removal technique. Every
# value is published; see docs/reference/spore-removal-log-reductions.md for the
# full citations.
#
#   microfiltration      2.2  Doll et al. 2017, Front. Microbiol. 8:135
#   microfiltration_low  0.6  Doll et al. 2017 -- a low-efficiency installation
#   bactofugation_single 1.4  Gesan-Guiziou 2010, Improv. Saf. Qual. Milk 1:349-372
#   bactofugation_double 2.0  Griep 2018, PhD thesis, Cornell
#
# These are estimates. Achieved reduction varies with equipment, membrane or
# bowl condition, flow rate, and temperature, so a processor's own measured
# figure always outranks the preset.
spore_reduction_presets <- list(
  microfiltration = 2.2,
  microfiltration_low = 0.6,
  bactofugation_single = 1.4,
  bactofugation_double = 2.0,
  none = 0
)

# Accepts a preset name or a bare log reduction. A processor who has measured
# their own removal outranks any published estimate, so the measured figure has
# to be expressible -- otherwise the presets read as the only permitted answers.
#
# The numeric branch is also a guard. `spore_reduction_presets[[2.2]]` indexes
# the list by POSITION, so a number used to return bactofugation_single silently.
get_spore_log_reduction <- function(method) {
  if (is.null(method)) return(0)

  if (is.numeric(method)) {
    if (length(method) != 1 || is.na(method)) {
      stop("A numeric spore reduction must be a single non-missing value.")
    }
    if (method < 0) {
      stop("A spore reduction cannot be negative; interventions are ",
           "improvements only (ADR 003). Got ", method, ".")
    }
    return(as.numeric(method))
  }

  if (method == "none") return(0)
  val <- spore_reduction_presets[[method]]
  if (is.null(val)) stop(paste0("Unknown spore reduction method: '", method,
    "'. Options: ", paste(names(spore_reduction_presets), collapse = ", "),
    ", or a number giving your own measured log reduction."))
  val
}

# Microfiltration and bactofugation remove SPORES. They do nothing to a vegetative
# cell, so the reduction applies only to the spore-forming genera named in
# config$spore_forming_genera.
#
# Applying it to every row understates spoilage, and since the container-assembly
# fix a container inherits every genus row it carries -- so more non-sporeformers
# reach this function than before. 94.7% of the medium pool and 28.7% of the high
# pool are non-sporeformers. See docs/research/2026-08-06-port-audit.md, D12.
#
# spore_genera is required rather than defaulted. A silently wrong reduction on a
# food-safety intervention is worse than a caller having to say what it means, and
# the Genus column is likewise required so a future pool without one fails loudly
# instead of reducing everything.
apply_spore_reduction <- function(pool_data, reduction_log, spore_genera) {
  if (reduction_log == 0 || nrow(pool_data) == 0) return(pool_data)

  # A user_config predating the genus gate carries no spore_forming_genera, so this
  # arrives NULL and `Genus %in% NULL` marks every row FALSE. The run would then
  # report microfiltration as applied while reducing nothing at all -- the same
  # silent-wrong-answer failure the required argument was meant to prevent, just
  # from the other direction.
  if (is.null(spore_genera) || length(spore_genera) == 0) {
    stop("apply_spore_reduction() needs a non-empty spore_genera. Supply ",
         "config$spore_forming_genera; a user_config from before that parameter ",
         "existed will not have it, and the reduction would be reported as applied ",
         "while reducing nothing.")
  }

  if (!"Genus" %in% names(pool_data)) {
    stop("apply_spore_reduction() needs a 'Genus' column to know which rows form ",
         "spores. Without it the reduction would be applied to every genus, which ",
         "understates spoilage.")
  }

  hit <- pool_data$Genus %in% spore_genera
  pool_data$log10N0[hit] <- pool_data$log10N0[hit] - reduction_log
  pool_data$N0[hit] <- 10^pool_data$log10N0[hit]
  pool_data
}

# =============================================================================
# Category B: PPC-Specific Controls
# =============================================================================

apply_ppc_interventions <- function(cfg, ppc_ST_freq, interventions) {
  if (!is.null(interventions$ppc_frequency_factor)) {
    cfg$P_ppc_min <- cfg$P_ppc_min * interventions$ppc_frequency_factor
    cfg$P_ppc_max <- cfg$P_ppc_max * interventions$ppc_frequency_factor
  }
  if (!is.null(interventions$ppc_initial_reduction_log)) {
    cfg$mean_ppc_N0 <- cfg$mean_ppc_N0 - interventions$ppc_initial_reduction_log
  }
  if (!is.null(interventions$ppc_remove_st)) {
    ppc_ST_freq <- ppc_ST_freq %>%
      filter(!ClosestST %in% interventions$ppc_remove_st)
  }
  list(config = cfg, ppc_ST_freq = ppc_ST_freq)
}

# =============================================================================
# Category C: Per-Stage Temperature Overrides
# =============================================================================

apply_stage_temp_overrides <- function(cfg, temp_profiles, stage_overrides) {
  if (length(stage_overrides) == 0) {
    return(list(config = cfg, temp_profiles = temp_profiles))
  }
  valid_stages <- names(cfg$temperature_stages)
  for (stage in names(stage_overrides)) {
    if (!stage %in% valid_stages) {
      stop(paste0("Unknown stage: '", stage, "'. Valid: ",
                  paste(valid_stages, collapse = ", ")))
    }
    overrides <- stage_overrides[[stage]]
    stage_cfg <- cfg$temperature_stages[[stage]]

    # temp_delta: shift mean (static) and shift every profile point (dynamic)
    if (!is.null(overrides$temp_delta)) {
      cfg$temperature_stages[[stage]]$mean <- stage_cfg$mean + overrides$temp_delta
      if (!is.null(temp_profiles[[stage]])) {
        temp_profiles[[stage]]$temperature <-
          temp_profiles[[stage]]$temperature + overrides$temp_delta
      }
    }
    # temp_mean / temp_sd: replace mean/sd (static), flatten profile (dynamic)
    if (!is.null(overrides$temp_mean)) {
      cfg$temperature_stages[[stage]]$mean <- overrides$temp_mean
      if (!is.null(overrides$temp_sd)) {
        cfg$temperature_stages[[stage]]$sd <- overrides$temp_sd
      }
      if (!is.null(temp_profiles[[stage]])) {
        temp_profiles[[stage]]$temperature <-
          rep(overrides$temp_mean, nrow(temp_profiles[[stage]]))
      }
    }
    # temp_max: clamp profile (dynamic), store for post-container clamping (static)
    if (!is.null(overrides$temp_max)) {
      cfg$temperature_stages[[stage]]$temp_max <- overrides$temp_max
      if (!is.null(temp_profiles[[stage]])) {
        temp_profiles[[stage]]$temperature <-
          pmin(temp_profiles[[stage]]$temperature, overrides$temp_max)
      }
    }
    # duration_delta: extend or shorten stage duration (resize profile if dynamic)
    # Writing cfg alone moved the reported shelf life without changing any
    # simulated concentration, because a dynamic stage's span comes from its
    # profile. temp_spike and delay already resize the profile
    # (scenarios/disruptions.R:35-59); this follows them.
    # The guard runs before the write, so it covers both stage modes. Inside
    # resize_profile() it only ever saw a dynamic stage.
    if (!is.null(overrides$duration_delta)) {
      new_duration <- stage_cfg$duration + overrides$duration_delta
      stop_if_nonpositive_duration(new_duration, stage)
      cfg$temperature_stages[[stage]]$duration <- new_duration
      if (!is.null(temp_profiles[[stage]])) {
        temp_profiles[[stage]] <- resize_profile(
          temp_profiles[[stage]], overrides$duration_delta, stage)
      }
    }
  }
  list(config = cfg, temp_profiles = temp_profiles)
}

# =============================================================================
# Category D: Raw Milk Bulk-Tank APC Override
# =============================================================================

# Draws one new bulk-tank APC value per lot (truncated normal, upper bound 5
# log10 CFU/mL) and rescales that lot's post-pasteurization counts
# proportionally, then re-draws each container's Poisson count from the
# rescaled expectation -- mirroring how the pool CSVs' own N0/log10N0 were
# originally derived from CFUlotini. The same per-lot draw must be reused
# across every pool-derived data frame for a lot (nogrowth/medium/high), since
# bulk-tank APC is a property of the lot's raw milk, not of which growth
# pathway a container's genus rows happened to land in -- see
# sample_lot_apc()/apply_raw_milk_apc() call sites in run_model.R.
sample_lot_apc <- function(lot_ids, apc_mean, apc_sd) {
  vals <- truncnorm::rtruncnorm(length(lot_ids), mean = apc_mean, sd = apc_sd, b = 5)
  stats::setNames(vals, lot_ids)
}

apply_raw_milk_apc <- function(pool_data, log10_apc_by_lot, mpn_conversion) {
  if (nrow(pool_data) == 0) return(pool_data)

  for (lot in unique(pool_data$lot_id)) {
    lot_mask <- pool_data$lot_id == lot
    original_cfu <- pool_data$CFUlotini[lot_mask][1]
    cfu_new <- 10^log10_apc_by_lot[[as.character(lot)]]
    scale_factor <- cfu_new / original_cfu

    pool_data$CFUlotini[lot_mask] <- cfu_new
    pool_data$postpastCFU[lot_mask] <- pool_data$postpastCFU[lot_mask] * scale_factor
    pool_data$exp_postpastcontainer[lot_mask] <- mpn_conversion * pool_data$postpastCFU[lot_mask]

    n <- sum(lot_mask)
    pool_data$postpastcontainer[lot_mask] <- rpois(n, pool_data$exp_postpastcontainer[lot_mask])
    pool_data$N0[lot_mask] <- pool_data$postpastcontainer[lot_mask] / mpn_conversion
    pool_data$log10N0[lot_mask] <- ifelse(pool_data$postpastcontainer[lot_mask] > 0,
                                           log10(pool_data$N0[lot_mask]), -Inf)
  }
  pool_data
}

# =============================================================================
# Unified entry point
# =============================================================================

apply_interventions <- function(cfg, temp_profiles, ppc_ST_freq, interventions) {
  if (length(interventions) == 0) {
    return(list(config = cfg, temp_profiles = temp_profiles,
                ppc_ST_freq = ppc_ST_freq, spore_log_reduction = 0,
                raw_milk_apc = NULL, applied = list()))
  }
  applied <- list()

  # Category A
  spore_log_reduction <- 0
  if (!is.null(interventions$spore_reduction)) {
    spore_log_reduction <- get_spore_log_reduction(interventions$spore_reduction)
    applied$spore_reduction <- interventions$spore_reduction
  }

  # Category B
  ppc_params <- interventions[intersect(names(interventions),
    c("ppc_frequency_factor", "ppc_initial_reduction_log", "ppc_remove_st"))]
  ppc_result <- apply_ppc_interventions(cfg, ppc_ST_freq, ppc_params)
  cfg <- ppc_result$config
  ppc_ST_freq <- ppc_result$ppc_ST_freq
  applied <- c(applied, ppc_params)

  # Category C
  if (!is.null(interventions$stage_temp_overrides)) {
    temp_result <- apply_stage_temp_overrides(
      cfg, temp_profiles, interventions$stage_temp_overrides)
    cfg <- temp_result$config
    temp_profiles <- temp_result$temp_profiles
    applied$stage_temp_overrides <- interventions$stage_temp_overrides
  }

  # Category D
  raw_milk_apc <- NULL
  if (!is.null(interventions$apc_mean) && !is.null(interventions$apc_sd)) {
    raw_milk_apc <- list(mean = interventions$apc_mean, sd = interventions$apc_sd)
    applied$apc_mean <- interventions$apc_mean
    applied$apc_sd <- interventions$apc_sd
  }

  list(config = cfg, temp_profiles = temp_profiles,
       ppc_ST_freq = ppc_ST_freq, spore_log_reduction = spore_log_reduction,
       raw_milk_apc = raw_milk_apc, applied = applied)
}
