# Milk Spoilage Model — Orchestrator
# Combines PPC pathway (Digital-dairy-platform) with A/BCLc/D pathways (PPI)

# =============================================================================
# 1. LOAD DEPENDENCIES
# =============================================================================
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

# Set up parallel processing
plan(multisession, workers = 4)

# =============================================================================
# 2. SOURCE MODULES
# =============================================================================
source("config.R")
source("utils/growth_models.R")
source("utils/temperature.R")
source("pathways/ppc_pathway.R")
source("pathways/nogrowth_pathway.R")
source("pathways/medium_growth_pathway.R")
source("pathways/high_growth_pathway.R")
source("scenarios/interventions.R")
source("scenarios/disruptions.R")
source("scenarios/resolve.R")

# =============================================================================
# run_model() — main simulation function
# =============================================================================
run_model <- function(user_config = NULL, interventions = list(), disruptions = list()) {

  cfg <- if (!is.null(user_config)) user_config else config
  warnings_vec <- character()

  # ===========================================================================
  # 3. LOAD AND PREPARE INPUT DATA
  # ===========================================================================

  # --- PPC growth parameter lookup table ---
  data_ppc <- read.csv("input_data/ppc_growth_params.csv")
  data_ppc$mumax <- cfg$ppc_mumax_correction * data_ppc$mumax

  ppc_ST_freq <- read.csv("input_data/ppc_st_frequency.csv")

  # Calculate PPC growth parameters (h0, b, Nmax, Topt)
  data_ppc$h0 <- data_ppc$lag * data_ppc$mumax
  data_ppc$b <- sqrt(data_ppc$mumax / log(10) * 24) / (cfg$T_ref_PPC - cfg$Tmin_PPC)

  growth_parameter_ppc <- data_ppc %>%
    group_by(isolate) %>%
    reframe(
      Mean_h0 = mean(h0),
      StdDev_h0 = sd(h0),
      Mean_b = mean(b),
      StdDev_b = sd(b),
      Mean_LOG10Nmax = mean(LOG10Nmax),
      StdDev_LOG10Nmax = sd(LOG10Nmax),
      Topt = Topt
    ) %>%
    distinct()
  growth_parameter_ppc <- as.data.frame(growth_parameter_ppc)
  growth_parameter_ppc$STorAT <- paste0("ST_", unique(data_ppc$STorAT))

  # --- Load pre-generated container pools ---
  pool_bclc <- read.csv("input_data/medium_growth_containers.csv")
  pool_d <- read.csv("input_data/high_growth_containers.csv")

  # The category-A genus rows, recovered from the upstream run's
  # CombinedData_wide.csv by scripts/extract_nogrowth_pool.R. The two growth
  # pools never carried them, so without this file every container lost its
  # non-growing load and the 61 containers holding nothing else could not be
  # drawn at all (upstream Model.Rmd chunk 11 keeps them in ModelData_nogrowth).
  pool_nogrowth_upstream <- read.csv("input_data/nogrowth_containers.csv")

  # The no-growth file ships without postpastCFU and exp_postpastcontainer,
  # which apply_raw_milk_apc() rescales and uses as the Poisson lambda. Derive
  # them the way the growth pools' own columns were built (both identities hold
  # exactly in medium_growth_containers.csv): the genus's post-pasteurization
  # CFU/mL, and its expected cell count per container.
  pool_nogrowth_upstream <- pool_nogrowth_upstream %>%
    mutate(
      postpastCFU = CFUlotini * Rel_ab * 10^(-Log_Reduction),
      exp_postpastcontainer = cfg$mpn_conversion * postpastCFU
    )

  # --- Split the medium pool's genus rows by growth category ---
  # Growth_category is a property of a (container, genus) pair, not a container
  # class: legacy tests only `!= "A"`, to keep non-growers out of the Buchanan
  # loop while still counting them in the container sum
  # (PPI_Digital-Interface/model/run_model.R:307, :330). The medium pool has no
  # such rows today; the filter stays so a future data drop that ships them is
  # still routed correctly.
  pool_nogrowth <- bind_rows(
    pool_nogrowth_upstream,
    pool_bclc %>% filter(Growth_category == "A" | postpastcontainer < 1)
  )
  pool_bclc_active <- pool_bclc %>%
    filter(Growth_category != "A" & postpastcontainer >= 1)

  # --- Load baseline temperature profiles ---
  temp_profiles <- load_baseline_profiles(cfg$temperature_stages)

  # ===========================================================================
  # 3b. APPLY SCENARIO PIPELINE
  # ===========================================================================
  scenario_result <- resolve_scenario(
    cfg, temp_profiles, ppc_ST_freq, interventions, disruptions
  )
  cfg <- scenario_result$config
  temp_profiles <- scenario_result$temp_profiles
  ppc_ST_freq <- scenario_result$ppc_ST_freq
  spore_log_reduction <- scenario_result$spore_log_reduction
  raw_milk_apc <- scenario_result$raw_milk_apc
  warnings_vec <- scenario_result$warnings

  # ===========================================================================
  # 4. GENERATE CONTAINERS AND ASSIGN PATHWAYS
  # ===========================================================================
  n_sim <- cfg$n_lots
  n_unit <- cfg$n_units

  # Create base container data frame
  lot_id <- rep(seq(1, n_sim), each = n_unit)
  unit_id <- rep(seq(1, n_unit), times = n_sim)
  containers <- data.frame(lot_id, unit_id)

  # Sample temperature and duration for each container from temperature_stages config
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

  # Assign PPC frequency per lot and determine PPC vs non-PPC
  containers <- containers %>%
    group_by(lot_id) %>%
    mutate(P_ppc = runif(1, cfg$P_ppc_min, cfg$P_ppc_max)) %>%
    ungroup()

  # Assign container type
  result_list <- list()
  for (i in 1:n_sim) {
    lot_data <- containers %>% filter(lot_id == i)
    num_ppc <- round(unique(lot_data$P_ppc) * n_unit)
    num_non_ppc <- n_unit - num_ppc
    types <- sample(c(rep("PPC", num_ppc), rep("non_PPC", num_non_ppc)), n_unit)
    lot_data$container_type <- types
    result_list[[i]] <- lot_data
  }
  containers <- bind_rows(result_list)

  # Post-container temp_max clamping (from interventions Category C)
  for (stage in cfg$stage_order) {
    stage_cfg <- cfg$temperature_stages[[stage]]
    if (!is.null(stage_cfg$temp_max)) {
      cols <- cfg$stage_to_cols[[stage]]
      containers[[cols$temp]] <- pmin(containers[[cols$temp]], stage_cfg$temp_max)
    }
  }

  # ===========================================================================
  # 5. RUN PPC PATHWAY
  # ===========================================================================
  ppc_containers <- containers %>% filter(container_type == "PPC")
  ppc_results <- run_ppc_pathway(ppc_containers, cfg, growth_parameter_ppc,
                                  ppc_ST_freq, temp_profiles)

  # An early-terminated ODE solve is held flat at its last valid concentration.
  # Report it rather than absorb it: above the spoilage threshold a flat tail
  # cannot change the container's status, but below it growth is understated.
  ppc_repaired <- attr(ppc_results, "n_solves_repaired")
  ppc_repaired_tails <- attr(ppc_results, "repaired_tail_log10")
  if (is.null(ppc_repaired)) ppc_repaired <- 0L
  if (is.null(ppc_repaired_tails)) ppc_repaired_tails <- numeric(0)

  if (ppc_repaired > 0) {
    warnings_vec <- c(warnings_vec, sprintf(
      paste("PPC: %d of %d ODE solves terminated early and were held flat at",
            "their last valid concentration (lowest %.2f log10; spoilage",
            "threshold %.2f)."),
      ppc_repaired, nrow(ppc_containers),
      min(ppc_repaired_tails, na.rm = TRUE), cfg$spoilage_threshold))

    n_below <- sum(ppc_repaired_tails <= cfg$spoilage_threshold, na.rm = TRUE)
    if (n_below > 0) {
      warnings_vec <- c(warnings_vec, sprintf(
        paste("PPC: %d of those stopped at or below the spoilage threshold, so",
              "spoilage is likely understated. Treat these results as suspect."),
        n_below))
    }
  }

  # ===========================================================================
  # 6. RUN NON-PPC PATHWAYS (A + BCLc + D)
  # ===========================================================================
  non_ppc_containers <- containers %>% filter(container_type == "non_PPC")

  if (nrow(non_ppc_containers) > 0) {
    # Each synthetic non-PPC container is assigned one *source container* from the
    # pools and inherits that container's whole bacterial community -- every genus
    # row it carries, across both pools.
    #
    # Legacy sums a container's load over all of its genus rows
    # (PPI_Digital-Interface/model/Model.R:216-222 pivots wide by Genus and
    # rowSums). 67.9% of source containers carry rows in both pools and they hold
    # 2.53 genera on average, so drawing one row from one pool both under-states
    # load and makes the pathway an artefact of the draw rather than a property of
    # the container.
    #
    # Sampling a whole real container, rather than drawing k genera
    # independently, preserves the empirical co-occurrence the pool CSVs encode.
    # The legacy model never generates containers -- it simulates the real ones --
    # so this is the port's own rule, chosen to add no parameter that is not
    # already in the data.
    #
    # The no-growth pool is part of the source population, not an add-on: 61 of
    # the 2,000 upstream containers carry only non-growing genera, and leaving
    # them out overstates spoilage.
    source_keys <- Reduce(union, list(
      paste(pool_nogrowth$lot_id, pool_nogrowth$unit_id),
      paste(pool_bclc$lot_id, pool_bclc$unit_id),
      paste(pool_d$lot_id, pool_d$unit_id)
    ))

    assignment <- data.frame(
      lot_id = non_ppc_containers$lot_id,
      unit_id = non_ppc_containers$unit_id,
      src_key = sample(source_keys, nrow(non_ppc_containers), replace = TRUE),
      stringsAsFactors = FALSE
    )

    # Pull every row of the assigned source container, rewriting container
    # identity to the synthetic one. A container absent from a given pool simply
    # contributes no rows to that pathway. The pool's own T_*/t_* columns pass
    # through unchanged.
    draw_community <- function(pool_rows) {
      if (nrow(pool_rows) == 0) return(data.frame())
      pool_rows$src_key <- paste(pool_rows$lot_id, pool_rows$unit_id)
      assignment %>%
        inner_join(
          pool_rows %>% dplyr::select(-lot_id, -unit_id),
          by = "src_key",
          relationship = "many-to-many"
        ) %>%
        dplyr::select(-src_key)
    }

    sampled_nogrowth <- draw_community(pool_nogrowth)
    sampled_bclc <- draw_community(pool_bclc_active)
    sampled_d <- draw_community(pool_d)

    # Apply user-supplied raw milk (bulk tank) APC override, if any. One APC
    # draw per lot, shared across all three non-PPC pool data frames -- see
    # sample_lot_apc()/apply_raw_milk_apc() in scenarios/interventions.R. Runs
    # before spore reduction: spore removal is a post-pasteurization step and
    # should act on the counts the raw-milk override implies, not the other
    # way around.
    if (!is.null(raw_milk_apc)) {
      log10_apc_by_lot <- sample_lot_apc(unique(non_ppc_containers$lot_id),
                                          raw_milk_apc$mean, raw_milk_apc$sd)
      sampled_nogrowth <- apply_raw_milk_apc(sampled_nogrowth, log10_apc_by_lot, cfg$mpn_conversion)
      sampled_bclc <- apply_raw_milk_apc(sampled_bclc, log10_apc_by_lot, cfg$mpn_conversion)
      sampled_d <- apply_raw_milk_apc(sampled_d, log10_apc_by_lot, cfg$mpn_conversion)
    }

    # Apply spore reduction to non-PPC pool data. Spores removed before filling
    # are gone whether or not the genus would later grow, so the no-growth rows
    # are reduced too.
    if (spore_log_reduction > 0) {
      if (nrow(sampled_nogrowth) > 0) {
        sampled_nogrowth <- apply_spore_reduction(sampled_nogrowth, spore_log_reduction,
                                                  cfg$spore_forming_genera)
      }
      if (nrow(sampled_bclc) > 0) {
        sampled_bclc <- apply_spore_reduction(sampled_bclc, spore_log_reduction,
                                              cfg$spore_forming_genera)
      }
      if (nrow(sampled_d) > 0) {
        sampled_d <- apply_spore_reduction(sampled_d, spore_log_reduction,
                                           cfg$spore_forming_genera)
      }
    }

    # Run no-growth pathway
    nogrowth_results <- run_nogrowth_pathway(sampled_nogrowth, cfg$sim_duration)

    # Static-stage conditions live on the synthetic container, not in a profile, so
    # copy them onto the pool-derived rows first. Both non-PPC pathways need this:
    # the Buchanan model reads the row directly, and build_env_conditions() reads
    # the row at its static branch.
    sampled_bclc <- apply_static_stage_conditions(sampled_bclc, non_ppc_containers,
                                                  temp_profiles, cfg)
    sampled_d <- apply_static_stage_conditions(sampled_d, non_ppc_containers,
                                               temp_profiles, cfg)

    # Run medium-growth pathway
    # The Buchanan model reads t_* off the row for its stage boundaries, so the
    # effective stage conditions have to be written in first -- otherwise the
    # pathway runs on its pool row's own thermal history and ignores every
    # temperature scenario. It reads the profiles for the temperature at every
    # instant within a dynamic stage; the high-growth and PPC pathways get the same
    # series from build_env_conditions() at simulation time.
    sampled_bclc <- apply_effective_stage_durations(sampled_bclc, temp_profiles, cfg)
    medium_results <- run_medium_growth_pathway(sampled_bclc, cfg, temp_profiles)

    # Run high-growth pathway
    high_results <- run_high_growth_pathway(sampled_d, cfg, temp_profiles)

  } else {
    nogrowth_results <- data.frame(lot_id = integer(0), unit_id = integer(0),
                                    day = integer(0), log10_concentration = numeric(0),
                                    N = numeric(0), pathway = character(0))
    medium_results <- nogrowth_results
    high_results <- nogrowth_results
  }

  # ===========================================================================
  # 7. AGGREGATE RESULTS
  # ===========================================================================

  # Combine all pathway results
  # PPC results don't have N column — add it
  ppc_results$N <- 10^ppc_results$log10_concentration

  all_results <- bind_rows(ppc_results, nogrowth_results, medium_results, high_results)

  container_daily <- all_results %>%
    group_by(lot_id, unit_id, day) %>%
    summarise(
      total_N = sum(N, na.rm = TRUE),
      pathway = paste(unique(pathway), collapse = "+"),
      .groups = "drop"
    ) %>%
    mutate(total_log10_N = ifelse(total_N > 0, log10(total_N), -2))

  # Determine spoilage
  container_daily <- container_daily %>%
    mutate(spoiled = total_log10_N > cfg$spoilage_threshold)

  # ===========================================================================
  # 8. CALCULATE SUMMARY STATISTICS
  # ===========================================================================
  summary_list <- list()
  for (target_day in cfg$output_days) {
    day_data <- container_daily %>% filter(day == target_day)

    if (nrow(day_data) == 0) next

    lot_spoilage <- day_data %>%
      group_by(lot_id) %>%
      summarise(
        n_spoiled = sum(spoiled, na.rm = TRUE),
        n_total = n(),
        pct_spoiled = 100 * n_spoiled / n_total,
        .groups = "drop"
      )

    stats <- lot_spoilage %>%
      summarise(
        day = target_day,
        median_pct_spoiled = median(pct_spoiled),
        mean_pct_spoiled = mean(pct_spoiled),
        sd = sd(pct_spoiled),
        P5 = quantile(pct_spoiled, 0.05),
        P25 = quantile(pct_spoiled, 0.25),
        P75 = quantile(pct_spoiled, 0.75),
        P95 = quantile(pct_spoiled, 0.95)
      )

    # Microbial concentration across all simulated containers on this day,
    # pooled over lots (log10 CFU/mL; containers with no cells sit at the -2
    # floor set in section 7).
    conc_stats <- day_data %>%
      summarise(
        conc_median_log10 = median(total_log10_N),
        conc_P5_log10 = quantile(total_log10_N, 0.05),
        conc_P25_log10 = quantile(total_log10_N, 0.25),
        conc_P75_log10 = quantile(total_log10_N, 0.75),
        conc_P95_log10 = quantile(total_log10_N, 0.95)
      )
    stats <- bind_cols(stats, conc_stats)

    summary_list[[length(summary_list) + 1]] <- stats
  }

  spoilage_summary <- bind_rows(summary_list)

  # ===========================================================================
  # 9. CALCULATE SHELF LIFE METRICS
  # ===========================================================================

  # Compute lot-level spoilage for ALL days (not just output_days)
  daily_lot_spoilage <- container_daily %>%
    group_by(lot_id, day) %>%
    summarise(
      pct_spoiled = 100 * sum(spoiled, na.rm = TRUE) / n(),
      .groups = "drop"
    )

  daily_median_spoilage <- daily_lot_spoilage %>%
    group_by(day) %>%
    summarise(
      median_pct = median(pct_spoiled),
      P25 = quantile(pct_spoiled, 0.25),
      P75 = quantile(pct_spoiled, 0.75),
      .groups = "drop"
    )

  # Pre-consumer duration: sum of all stage durations before consumer.
  # Uses the duration each stage actually ran for, so the reported window cannot
  # drift from the simulated one -- a dynamic stage's span comes from its profile,
  # not from cfg.
  pre_consumer_stages <- setdiff(cfg$stage_order, "consumer")
  pre_consumer_days <- sum(sapply(pre_consumer_stages, function(s) {
    effective_stage_duration(s, temp_profiles, cfg)
  }))

  # Total shelf life: first day (from production) where median lot > 25% spoiled
  shelf_life_pct <- 25
  exceeded <- daily_median_spoilage$day[daily_median_spoilage$median_pct > shelf_life_pct]
  total_shelf_life <- if (length(exceeded) > 0) min(exceeded) else Inf

  # Consumer shelf life: days of consumer storage until 25% lot spoilage
  consumer_shelf_life <- if (is.finite(total_shelf_life)) {
    max(total_shelf_life - pre_consumer_days, 0)
  } else {
    Inf
  }

  # Pre-consumer spoilage: % of containers spoiled at retail exit
  pre_consumer_day <- floor(pre_consumer_days)
  if (pre_consumer_day <= cfg$sim_duration && pre_consumer_day >= 0) {
    retail_exit_data <- daily_lot_spoilage %>% filter(day == pre_consumer_day)
    pct_spoiled_at_retail <- if (nrow(retail_exit_data) > 0) {
      median(retail_exit_data$pct_spoiled)
    } else {
      0
    }
  } else {
    pct_spoiled_at_retail <- 0
  }

  shelf_life <- list(
    total_days = total_shelf_life,
    consumer_days = consumer_shelf_life,
    pre_consumer_days = pre_consumer_days,
    threshold_pct = shelf_life_pct,
    pct_spoiled_at_retail = pct_spoiled_at_retail
  )

  # ===========================================================================
  # 10. BUILD CONTAINER OUTPUT
  # ===========================================================================
  container_output <- all_results %>%
    left_join(
      container_daily %>% dplyr::select(lot_id, unit_id, day, total_log10_N),
      by = c("lot_id", "unit_id", "day")
    )

  # ===========================================================================
  # 11. RETURN RESULTS
  # ===========================================================================
  list(
    spoilage_summary = spoilage_summary,
    shelf_life = shelf_life,
    daily_median_spoilage = daily_median_spoilage,
    container_results = container_output,
    warnings = warnings_vec,
    diagnostics = list(
      ppc_solves_repaired = ppc_repaired,
      ppc_repaired_tail_log10 = ppc_repaired_tails
    ),
    scenario = list(
      config = cfg,
      interventions_applied = scenario_result$interventions_applied,
      disruptions_applied = scenario_result$disruptions_applied
    )
  )
}

# =============================================================================
# SCRIPT-LEVEL EXECUTION (when run directly)
# =============================================================================
if (sys.nframe() == 0) {
  cat("Modules loaded successfully.\n")
  result <- run_model()

  # Write output files
  write.csv(result$spoilage_summary, "output/spoilage_summary.csv", row.names = FALSE)
  write.csv(result$container_results, "output/container_results.csv", row.names = FALSE)
  cat("Output files written.\n")

  # Print shelf-life estimates
  sl <- result$shelf_life
  cat(sprintf("\nShelf life (median lot > %d%% spoiled):\n", sl$threshold_pct))
  cat(sprintf("  Total (from production): %s\n",
    ifelse(is.finite(sl$total_days), sprintf("%d days", sl$total_days),
           paste0(">", config$sim_duration, " days"))))
  cat(sprintf("  Consumer (from home storage): %s\n",
    ifelse(is.finite(sl$consumer_days), sprintf("%.1f days", sl$consumer_days),
           paste0(">", round(config$sim_duration - sl$pre_consumer_days, 1), " days"))))
  cat(sprintf("  Pre-consumer supply chain: %.1f days\n", sl$pre_consumer_days))

  cat("\nSpoilage summary:\n")
  print(result$spoilage_summary)

  cat("\nModel run complete. Results written to output/\n")

  # Clean up parallel workers
  plan(sequential)
}
