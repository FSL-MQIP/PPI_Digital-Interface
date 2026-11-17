# Medium-Growth Pathway (BCLc) — Buchanan model, vectorized
# Source: PPI_Digital-Interface/model/run_model.R lines 6-57, 346-364
# Preserved original code logic for model validity

# Simulate growth for a single container using Buchanan model without lag phase
# Source: PPI run_model.R lines 6-57 (simulate_growth_row)
#
# stage_integrals holds one running growth integral per stage, keyed by the stage's
# time column, or NULL where the stage is static. See run_medium_growth_pathway().
simulate_growth_row <- function(row_data, t_H_total, stage_integrals) {
  # Extract single row values upfront to avoid repeated column indexing
  t_F_val <- row_data$t_F[1]
  t_T_val <- row_data$t_T[1]
  t_S_val <- row_data$t_S[1]
  t_T2_val <- row_data$t_T2[1]
  t_H_val <- row_data$t_H[1]
  dur <- c(t_F_val, t_T_val, t_S_val, t_T2_val, t_H_val)

  newGR_F_val <- row_data$newGR_F[1]
  newGR_T_val <- row_data$newGR_T[1]
  newGR_S_val <- row_data$newGR_S[1]
  newGR_T2_val <- row_data$newGR_T2[1]
  newGR_H_val <- row_data$newGR_H[1]
  rate <- c(newGR_F_val, newGR_T_val, newGR_S_val, newGR_T2_val, newGR_H_val)

  N0 <- row_data$log10N0[1]
  Nmax <- row_data$log10Nmax[1]

  # Create time series: one row per day (0 to t_H_total)
  days <- 0:round(t_H_total)
  n_days <- length(days)

  # Derived: stage boundaries
  start <- c(0, cumsum(dur)[-length(dur)])
  end <- cumsum(dur)

  # Helper: time spent in each stage up to time t
  time_in_stage <- function(t, start, end) {
    pmax(0, pmin(t, end) - start)
  }

  # muAtNewTemp() is exactly quadratic in (T - T0), so this container's growth rate
  # is mu_coef * (T - T0)^2 at any temperature. That is what lets a dynamic stage's
  # whole profile be carried as one integral of (T - T0)^2, shared across every
  # container, and scaled here by the container's own growthrate.
  mu_coef <- row_data$growthrate[1] /
    (eval(formals(muAtNewTemp)$oldTemp) - eval(formals(muAtNewTemp)$T0))^2

  # Growth accrued in each stage after the time spent in it. A static stage holds
  # one temperature, so it keeps the legacy rate * time. A dynamic stage integrates
  # its profile over that time instead of applying one rate across the whole stage:
  # the two agree on the stage TOTAL and disagree on the trajectory inside it, and
  # the trajectory is what is reported. See utils/temperature.R
  # stage_growth_integral() and verification/test_buchanan_trajectory.R.
  #
  # stage_integrals is positional, in the order dur and rate are built above. Its
  # caller checks that alignment; a mismatch here would read as an all-static run,
  # which is a wrong answer rather than an error.
  incr <- matrix(0, nrow = n_days, ncol = length(dur))
  for (j in seq_along(dur)) {
    u <- time_in_stage(days, start[j], end[j])
    incr[, j] <- if (is.null(stage_integrals[[j]])) {
      rate[j] * u
    } else {
      mu_coef * stage_integrals[[j]](u)
    }
  }

  result_df <- data.frame(
    Day = days,
    predConc = pmin(N0 + rowSums(incr), Nmax)
  )

  # Add original row data columns (preserve time columns t_F, t_T, t_S, t_T2)
  for (col_name in names(row_data)) {
    if (!col_name %in% c("newGR_F", "newGR_T", "newGR_S", "newGR_T2", "newGR_H")) {
      result_df[[col_name]] <- rep(row_data[[col_name]][1], n_days)
    }
  }

  return(result_df)
}

# Main medium-growth pathway function
# Source: PPI run_model.R lines 346-364
run_medium_growth_pathway <- function(bclc_data, config, temp_profiles = list()) {
  # bclc_data: data frame sampled from medium_growth_containers.csv pool
  #   Must have columns: lot_id, unit_id, T_F, t_F, T_T, t_T, T_S, t_S,
  #   T_T2, t_T2, T_H, t_H, growthrate, log10N0, log10Nmax, N0
  # temp_profiles: the stage profiles, as build_env_conditions() receives them.
  #   Omit them and every stage runs on the row's own constant temperature, which
  #   is what verification/compare_distributions.R does.

  if (nrow(bclc_data) == 0) {
    return(data.frame(lot_id = integer(0), unit_id = integer(0),
                      day = integer(0), log10_concentration = numeric(0),
                      N = numeric(0), pathway = character(0)))
  }

  sim_duration <- config$sim_duration

  # Adjust growth rates for each supply chain stage (run_model.R lines 350-354)
  ModelData_BCLc <- bclc_data
  ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_F = muAtNewTemp(T_F, growthrate))
  ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_T = muAtNewTemp(T_T, growthrate))
  ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_S = muAtNewTemp(T_S, growthrate))
  ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_T2 = muAtNewTemp(T_T2, growthrate))
  ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_H = muAtNewTemp(T_H, growthrate))

  # One running growth integral per stage, in config$stage_order. A dynamic stage's
  # profile is shared by every container, so its integral is built once here; a
  # static stage gets NULL and its container's own scalar temperature stands. Gated
  # exactly as build_env_conditions() gates, so the two halves of the model see the
  # same thermal history.
  stage_integrals <- lapply(config$stage_order, function(stage) {
    stage_cfg <- config$temperature_stages[[stage]]
    if (stage_cfg$mode == "dynamic" && !is.null(temp_profiles[[stage]])) {
      stage_growth_integral(temp_profiles[[stage]])
    } else {
      NULL
    }
  })

  # simulate_growth_row() reads the five stage columns by name, in this order, and
  # takes the integrals positionally against them. Refuse a config that maps its
  # stages to anything else: the mismatch would otherwise be read as an all-static
  # run, so every dynamic profile would be silently ignored and the pathway would
  # return a plausible wrong answer.
  buchanan_cols <- c("t_F", "t_T", "t_S", "t_T2", "t_H")
  mapped_cols <- vapply(config$stage_order,
                        function(s) config$stage_to_cols[[s]]$time,
                        character(1))
  if (!identical(unname(mapped_cols), buchanan_cols)) {
    stop("The Buchanan pathway reads the stage columns ",
         paste(buchanan_cols, collapse = ", "), " in that order; config maps its ",
         "stages to ", paste(mapped_cols, collapse = ", "), ".")
  }

  # Run growth simulation in parallel (run_model.R lines 361-362)
  results_list <- future_map(1:nrow(ModelData_BCLc),
                             ~ simulate_growth_row(ModelData_BCLc[.x, ], sim_duration,
                                                   stage_integrals))
  ModelData_BCLc <- bind_rows(results_list)

  ModelData_BCLc$N <- 10^(ModelData_BCLc$predConc)

  # Format output
  result <- data.frame(
    lot_id = ModelData_BCLc$lot_id,
    unit_id = ModelData_BCLc$unit_id,
    day = ModelData_BCLc$Day,
    log10_concentration = ModelData_BCLc$predConc,
    N = ModelData_BCLc$N,
    pathway = "medium_growth"
  )

  return(result)
}
