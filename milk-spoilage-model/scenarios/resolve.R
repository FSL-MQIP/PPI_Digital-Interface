# Scenario Resolution
# Orchestrates the intervention -> disruption pipeline and checks for conflicts.

# =============================================================================
# Conflict Detection
# =============================================================================

conflict_check <- function(interventions, disruptions, cfg) {
  warnings_vec <- character()

  # 1. Same-stage conflict: intervention temp override + disruption on same stage
  intervention_stages <- character()
  if (!is.null(interventions$stage_temp_overrides)) {
    intervention_stages <- names(interventions$stage_temp_overrides)
  }
  disruption_stages <- names(disruptions)

  # The caller repeats this text to the processor, so it has to name what the run
  # actually did with the two layers. Interventions run first (step 1 below), and
  # only a replacing disruption discards that work -- every disruption preset
  # expands to one (dairy-api/r_bridge/run_simulation.R). The rest compose: a
  # temp_shift ADDS its offset to the already-shifted profile, and temp_spike and
  # delay append a segment after it. disruption_replaces_profile() holds which is
  # which, beside the cascade that implements it. Saying "overrides" for all four
  # told a processor their intervention had been discarded when it was still in
  # effect.
  overlap <- intersect(intervention_stages, disruption_stages)
  for (stage in overlap) {
    warnings_vec <- c(warnings_vec,
      if (disruption_replaces_profile(disruptions[[stage]]$type)) {
        paste0("Disruption on ", stage,
               " replaces the temperature series set by the intervention")
      } else {
        paste0("Disruption on ", stage,
               " composes with the temperature intervention: the intervention is",
               " applied first, then the disruption on top of it")
      })
  }

  # 2. Duration overflow: total supply chain duration exceeds sim_duration
  total_duration <- 0
  for (stage in cfg$stage_order) {
    total_duration <- total_duration + cfg$temperature_stages[[stage]]$duration
  }
  if (total_duration > cfg$sim_duration) {
    warnings_vec <- c(warnings_vec,
      sprintf("Total supply chain duration (%.1fd) exceeds sim_duration (%dd)",
              total_duration, cfg$sim_duration))
  }

  warnings_vec
}

# =============================================================================
# Pipeline Orchestrator
# =============================================================================

resolve_scenario <- function(cfg, temp_profiles, ppc_ST_freq,
                              interventions = list(), disruptions = list()) {
  # Step 1: apply interventions
  int_result <- apply_interventions(cfg, temp_profiles, ppc_ST_freq, interventions)
  cfg <- int_result$config
  temp_profiles <- int_result$temp_profiles
  ppc_ST_freq <- int_result$ppc_ST_freq

  # Step 2: apply disruptions
  dis_result <- apply_disruptions(cfg, temp_profiles, disruptions)
  cfg <- dis_result$config
  temp_profiles <- dis_result$temp_profiles

  # Step 3: conflict check (uses original inputs + final config)
  warnings_vec <- conflict_check(interventions, disruptions, cfg)

  list(
    config = cfg,
    temp_profiles = temp_profiles,
    ppc_ST_freq = ppc_ST_freq,
    spore_log_reduction = int_result$spore_log_reduction,
    raw_milk_apc = int_result$raw_milk_apc,
    interventions_applied = int_result$applied,
    disruptions_applied = dis_result$applied,
    warnings = warnings_vec
  )
}
