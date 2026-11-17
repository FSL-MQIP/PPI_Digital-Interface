# PPC Pathway — Gram-negative post-pasteurization contamination
# Source: Digital-dairy-platform/server.R lines 508-698 (PPC portions only)
# Preserved original code logic for model validity

run_ppc_pathway <- function(ppc_containers, config, growth_parameter, ppc_ST_freq, temp_profiles) {

  n_ppc <- nrow(ppc_containers)
  if (n_ppc == 0) {
    return(data.frame(lot_id = integer(0), unit_id = integer(0),
                      day = integer(0), log10_concentration = numeric(0),
                      pathway = character(0)))
  }

  model_data_ppc <- ppc_containers

  # Assign ST types — vectorized (original: server.R lines 528-537)
  valid_st <- ppc_ST_freq$ClosestST[ppc_ST_freq$ClosestST != "9_23"]
  model_data_ppc$STorAT <- paste0("ST_", sample(valid_st, n_ppc, replace = TRUE))

  # Sample initial contamination levels — vectorized (server.R lines 545-561)
  model_data_ppc$N0 <- rnorm(n_ppc, mean = config$mean_ppc_N0, sd = config$sd_ppc_N0)

  # Filter partial cells via Poisson sampling
  model_data_ppc$N0_MPN_ppc <- 10^model_data_ppc$N0 * config$mpn_conversion
  model_data_ppc_filtered <- subset(model_data_ppc, N0_MPN_ppc < 1)
  model_data_ppc_filtered$new_column <- runif(nrow(model_data_ppc_filtered))
  model_data_ppc_filtered$N0_MPN_ppc_assigned <- ifelse(
    model_data_ppc_filtered$N0_MPN_ppc > model_data_ppc_filtered$new_column, 1,
    ifelse(model_data_ppc_filtered$N0_MPN_ppc < model_data_ppc_filtered$new_column, 0, NA))
  model_data_ppc_filtered <- model_data_ppc_filtered[,
    !(names(model_data_ppc_filtered) %in% c("N0_MPN_ppc", "new_column"))]
  names(model_data_ppc_filtered)[names(model_data_ppc_filtered) == "N0_MPN_ppc_assigned"] <- "N0_MPN_ppc"
  filtered_rows <- anti_join(model_data_ppc, model_data_ppc_filtered, by = c("lot_id", "unit_id"))
  model_data_ppc <- rbind(filtered_rows, model_data_ppc_filtered)
  model_data_ppc$N0 <- model_data_ppc$N0_MPN_ppc / config$mpn_conversion
  model_data_ppc <- subset(model_data_ppc, select = -N0_MPN_ppc)
  model_data_ppc <- as.data.frame(model_data_ppc)
  n_ppc <- nrow(model_data_ppc)

  # Generate allele index and assign growth parameters (server.R lines 586-627)
  model_data_ppc$allele_index <- match(model_data_ppc$STorAT, growth_parameter$STorAT)

  model_data_ppc$Mean_h0 <- growth_parameter$Mean_h0[model_data_ppc$allele_index]
  model_data_ppc$StdDev_h0 <- growth_parameter$StdDev_h0[model_data_ppc$allele_index]
  model_data_ppc$Mean_b <- growth_parameter$Mean_b[model_data_ppc$allele_index]
  model_data_ppc$StdDev_b <- growth_parameter$StdDev_b[model_data_ppc$allele_index]
  model_data_ppc$Mean_Nmax <- growth_parameter$Mean_LOG10Nmax[model_data_ppc$allele_index]
  model_data_ppc$StdDev_Nmax <- growth_parameter$StdDev_LOG10Nmax[model_data_ppc$allele_index]
  model_data_ppc$Topt <- growth_parameter$Topt[model_data_ppc$allele_index]

  model_data_ppc$h0 <- truncnorm::rtruncnorm(n_ppc, a = 0,
    mean = model_data_ppc$Mean_h0, sd = model_data_ppc$StdDev_h0)

  model_data_ppc$Q0 <- 1 / (exp(model_data_ppc$h0) - 1)

  model_data_ppc$b <- truncnorm::rtruncnorm(n_ppc, a = 0,
    mean = model_data_ppc$Mean_b, sd = model_data_ppc$StdDev_b)

  model_data_ppc$Nmax <- rnorm(n_ppc, mean = model_data_ppc$Mean_Nmax,
    sd = model_data_ppc$StdDev_Nmax)
  model_data_ppc$Nmax <- 10^(model_data_ppc$Nmax)

  model_data_ppc$Tmin <- config$Tmin_PPC
  model_data_ppc$mu_opt <- (model_data_ppc$b * (model_data_ppc$Topt - model_data_ppc$Tmin))^2

  model_data_ppc <- as.data.frame(model_data_ppc)

  # Run simulation — parallelized (server.R lines 656-670)
  n_ppc <- nrow(model_data_ppc)
  my_times <- seq(0, config$sim_duration)
  num_iterations <- n_ppc

  run_ppc_simulation <- function(i) {
    my_primary <- list(
      mu_opt = model_data_ppc$mu_opt[i],
      Nmax = model_data_ppc$Nmax[i],
      N0 = model_data_ppc$N0[i],
      Q0 = model_data_ppc$Q0[i]
    )
    sec_temperature <- list(
      model = "reducedRatkowsky",
      xmin = model_data_ppc$Tmin[i],
      b = model_data_ppc$b[i],
      xopt = model_data_ppc$Topt[i]
    )
    my_secondary <- list(temperature = sec_temperature)
    growth <- predict_dynamic_growth(
      times = my_times,
      env_conditions = build_env_conditions(
        i, model_data_ppc, temp_profiles, config
      ),
      my_primary,
      my_secondary
    )
    growth$simulation
  }

  all_simulations <- future_map(1:num_iterations, run_ppc_simulation)

  # Normalise every simulation to exactly n_days rows before combining.
  # predict_dynamic_growth can terminate early at high temperature; the bare rbind
  # then disagrees with the row expansion below and data.frame() fails on a length
  # mismatch rather than reporting the real problem. A +5 C consumer temp_shift is
  # enough to trigger it.
  #
  # Mirrors high_growth_pathway.R:56-87. Both steps are no-ops when the solver
  # returned a full series, so PPC output is unchanged in the normal case. The
  # legacy source has the same gap (Digital-dairy-platform/server.R:673-679), so
  # there is no upstream behaviour to match here.
  n_days <- config$sim_duration + 1

  # Record which solves came up short, and how far growth had got when they
  # stopped, BEFORE repairing them. Padding is not free: fix_simulation() holds
  # the last valid concentration flat, which understates growth if the solver
  # stopped mid-exponential. run_model() surfaces these counts so the repair is
  # never silent, and verify_structure.R asserts that every padded solve had
  # already passed the spoilage threshold -- above it, a flat tail cannot change
  # the container's spoiled/not-spoiled status.
  short <- vapply(all_simulations, function(sim) nrow(sim) < n_days, logical(1))

  all_simulations <- map(all_simulations, ~ fix_simulation(.x, n_days))
  all_simulations <- map(all_simulations, function(sim) {
    if (nrow(sim) > n_days) {
      sim <- sim[1:n_days, ]
    } else if (nrow(sim) < n_days) {
      last_row <- sim[nrow(sim), ]
      while (nrow(sim) < n_days) {
        new_row <- last_row
        new_row$time <- nrow(sim)
        sim <- bind_rows(sim, new_row)
      }
    }
    sim
  })

  # Measure the tail from the NORMALISED series, which is what reaches
  # aggregation. fix_simulation() discards the raw final row and pads from the one
  # before it, so reading the raw series can report a higher concentration than the
  # padded tail actually holds, and make the repair look safer than it is. Measure
  # the value used, not the value solved.
  short_tail_log10 <- vapply(all_simulations[short], function(sim) {
    valid <- sim$logN[!is.na(sim$logN)]
    if (length(valid) > 0) valid[[length(valid)]] else NA_real_
  }, numeric(1))

  final_conc <- do.call(rbind, all_simulations)

  expected_rows <- n_ppc * n_days
  if (nrow(final_conc) != expected_rows) {
    stop(paste("PPC row count mismatch: expected", expected_rows,
               "got", nrow(final_conc)))
  }

  # Generate output (server.R lines 677-681)
  model_data_expanded <- model_data_ppc[rep(1:nrow(model_data_ppc), each = n_days), ]
  result <- data.frame(
    lot_id = model_data_expanded$lot_id,
    unit_id = model_data_expanded$unit_id,
    day = final_conc$time,
    log10_concentration = final_conc$logN,
    pathway = "PPC"
  )
  result$log10_concentration[result$log10_concentration == -Inf] <- -2

  # Carried as attributes so the standardised pathway return stays a data frame
  attr(result, "n_solves_repaired") <- sum(short)
  attr(result, "repaired_tail_log10") <- short_tail_log10

  return(result)
}
