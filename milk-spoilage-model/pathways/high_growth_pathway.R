# High-Growth Pathway (D) — Baranyi ODE with reduced Ratkowsky
# Source: PPI_Digital-Interface/model/run_model.R lines 370-505
# Preserved original code logic for model validity

run_high_growth_pathway <- function(d_data, config, temp_profiles) {
  # d_data: data frame sampled from high_growth_containers.csv pool
  #   Must have columns: lot_id, unit_id, mu_opt, Nmax, N0, Q0, Tmin, b, Topt,
  #   T_F, t_F, T_T, t_T, T_S, t_S, T_T2, t_T2, T_H, t_H

  if (nrow(d_data) == 0) {
    return(data.frame(lot_id = integer(0), unit_id = integer(0),
                      day = integer(0), log10_concentration = numeric(0),
                      N = numeric(0), pathway = character(0)))
  }

  sim_duration <- config$sim_duration
  ModelData_D <- d_data

  # Set up simulation parameters (run_model.R lines 410-411)
  my_times <- seq(0, sim_duration)
  num_iterations <- nrow(ModelData_D)

  # Function to simulate growth for one container (run_model.R lines 414-442)
  run_simulation <- function(i) {
    my_primary <- list(
      mu_opt = ModelData_D$mu_opt[i],
      Nmax = ModelData_D$Nmax[i],
      N0 = ModelData_D$N0[i],
      Q0 = ModelData_D$Q0[i]
    )

    sec_temperature <- list(
      model = "reducedRatkowsky",
      xmin = ModelData_D$Tmin[i],
      b = ModelData_D$b[i],
      xopt = ModelData_D$Topt[i]
    )

    my_secondary <- list(temperature = sec_temperature)

    growth <- predict_dynamic_growth(
      times = my_times,
      env_conditions = build_env_conditions(
        i, ModelData_D, temp_profiles, config
      ),
      my_primary,
      my_secondary
    )

    growth$simulation
  }

  # Run simulations in parallel (run_model.R line 449)
  all_simulations <- future_map(1:num_iterations, run_simulation)

  # Fix simulation results (run_model.R lines 452-475)
  row_run <- sim_duration + 1
  all_simulations_fixed <- map(all_simulations, ~ fix_simulation(.x, row_run))

  # Ensure each simulation has exactly row_run rows
  all_simulations_fixed <- map(all_simulations_fixed, function(sim) {
    if (nrow(sim) != row_run) {
      if (nrow(sim) > row_run) {
        sim <- sim[1:row_run, ]
      } else {
        last_row <- sim[nrow(sim), ]
        while (nrow(sim) < row_run) {
          new_row <- last_row
          new_row$time <- nrow(sim)
          sim <- bind_rows(sim, new_row)
        }
        sim <- sim[1:row_run, ]
      }
    }
    sim
  })

  # Combine all simulation results (run_model.R lines 478-505)
  final_conc <- do.call(rbind, all_simulations_fixed)
  count_result <- final_conc %>% dplyr::select(all_of(c("time", "N", "logN")))

  original_nrows <- nrow(ModelData_D)
  expected_rows <- original_nrows * row_run

  if (nrow(count_result) != expected_rows) {
    stop(paste("Row count mismatch: expected", expected_rows, "got", nrow(count_result)))
  }

  Day <- rep(0:sim_duration, times = original_nrows)
  ModelData_D_expanded <- ModelData_D[rep(1:original_nrows, each = row_run), ]

  # Format output
  result <- data.frame(
    lot_id = ModelData_D_expanded$lot_id,
    unit_id = ModelData_D_expanded$unit_id,
    day = Day,
    log10_concentration = count_result$logN,
    N = count_result$N,
    pathway = "high_growth"
  )

  return(result)
}
