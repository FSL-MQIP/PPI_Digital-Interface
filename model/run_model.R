# Model execution function for Shiny app
# This function runs the spoilage prediction model and returns SpoilStats_all

# Function to simulate growth for a single container
# Uses Buchanan model without lag phase (buchanan_nl_log10)
simulate_growth_row <- function(row_data, t_H_total) {
  # Extract single row values upfront to avoid repeated column indexing
  t_F_val <- row_data$t_F[1]
  t_T_val <- row_data$t_T[1]
  t_S_val <- row_data$t_S[1]
  t_T2_val <- row_data$t_T2[1]
  t_H_val <- row_data$t_H[1]
  dur <- c(t_F_val, t_T_val, t_S_val, t_T2_val, t_H_val) # create vector from stage durations
  
  newGR_F_val <- row_data$newGR_F[1]
  newGR_T_val <- row_data$newGR_T[1]
  newGR_S_val <- row_data$newGR_S[1]
  newGR_T2_val <- row_data$newGR_T2[1]
  newGR_H_val <- row_data$newGR_H[1]
  rate <- c(newGR_F_val, newGR_T_val, newGR_S_val, newGR_T2_val, newGR_H_val) # create vector from growth rates
  
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
    pmax(0, pmin(t, end) - start)      # vector length = number of stages
  }
  
  # Evaluate N(t) for vector t (vectorized with sapply), capped at Nmax
  N_t <- function(t_vec, N0, rate, start, end, Nmax) {
    incr <- sapply(t_vec, function(t) sum(rate * time_in_stage(t, start, end)))
    pmin(N0 + incr, Nmax)
  }
  
  result_df <- data.frame(
    Day = days,
    predConc = N_t(days, N0, rate, start, end, Nmax)
  )
  
  # Add original row data columns (preserve time columns t_F, t_T, t_S, t_T2)
  for (col_name in names(row_data)) {
    if (!col_name %in% c("newGR_F", "newGR_T", "newGR_S", "newGR_T2", "newGR_H")) {
      result_df[[col_name]] <- rep(row_data[[col_name]][1], n_days)
    }
  }
  
  return(result_df)
}

run_spoilage_model <- function(ModelData_BCLc_input, ModelData_D_input, stage_stats = NULL, selected_stages = NULL, t_H = NULL, apc_mean = NULL, apc_sd = NULL, progress_callback = NULL) {
  
  # Set up progress reporting
  if (!is.null(progress_callback)) {
    progress_callback(message = "Initializing model...", value = 0.1)
  }
  
  # Total shelf-life simulation horizon (days from start of supply chain)
  # This is distinct from consumer stage duration — it defines how many days
  # the simulation runs so we can report results at days 7, 14, 21, 28, 35
  if (is.null(t_H)) {
    t_H <- 35
  }
  
  # Convert t_H to integer (round to nearest integer for non-integer values)
  t_H <- as.integer(round(t_H))
  
  # Stage to column mapping
  stage_to_cols <- list(
    processing_facility = list(temp = "T_F", time = "t_F"),
    transportation_facility_to_retail = list(temp = "T_T", time = "t_T"),
    retail = list(temp = "T_S", time = "t_S"),
    transportation_retail_to_home = list(temp = "T_T2", time = "t_T2"),
    consumer = list(temp = "T_H", time = "t_H")
  )
  
  # Create copies of input data for modification
  updated_data_bclc <- ModelData_BCLc_input
  updated_data_d <- ModelData_D_input

  # --- N0 Recalculation from User APC ---
  # If user provided APC data, scale initial concentrations proportionally
  # and re-apply Poisson sampling (see ADR 003)
  if (!is.null(apc_mean) && !is.null(apc_sd)) {
    recalculate_n0 <- function(data) {
      lots <- unique(data$lot_id)

      for (lot in lots) {
        lot_mask <- data$lot_id == lot
        original_cfu <- data$CFUlotini[lot_mask][1]

        # Sample new lot-level APC from truncated normal (upper bound = 5 log10)
        log10cfu_new <- truncnorm::rtruncnorm(1, mean = apc_mean, sd = apc_sd, b = 5)
        cfu_new <- 10^log10cfu_new

        # Proportional scale factor
        scale_factor <- cfu_new / original_cfu

        # Scale post-pasteurization CFU
        data$CFUlotini[lot_mask] <- cfu_new
        data$postpastCFU[lot_mask] <- data$postpastCFU[lot_mask] * scale_factor

        # Re-compute expected per container (1900 mL)
        data$exp_postpastcontainer[lot_mask] <- 1900 * data$postpastCFU[lot_mask]

        # Re-do Poisson sampling per container
        n_containers <- sum(lot_mask)
        data$postpastcontainer[lot_mask] <- rpois(n_containers, data$exp_postpastcontainer[lot_mask])

        # Derive N0 and log10N0
        data$N0[lot_mask] <- data$postpastcontainer[lot_mask] / 1900
        data$log10N0[lot_mask] <- ifelse(
          data$postpastcontainer[lot_mask] > 0,
          log10(data$N0[lot_mask]),
          -Inf
        )
      }

      data
    }

    updated_data_bclc <- recalculate_n0(updated_data_bclc)
    updated_data_d <- recalculate_n0(updated_data_d)
  }

  # Process each stage - only update columns where user submitted data
  all_stages <- c("processing_facility", "transportation_facility_to_retail", "retail", 
                  "transportation_retail_to_home", "consumer")
  
  for (stage in all_stages) {
    # Get column names for this stage
    cols <- stage_to_cols[[stage]]
    temp_col <- cols$temp
    time_col <- cols$time
    
    # Check if user provided data for this stage
    # Only update if: stage is in selected_stages AND has valid stats
    has_user_data <- FALSE
    temp_mean <- NULL
    temp_sd <- NULL
    time_mean <- NULL
    time_sd <- NULL
    
    if (!is.null(selected_stages) && stage %in% selected_stages) {
      if (!is.null(stage_stats) && !is.null(stage_stats[[stage]])) {
        stats <- stage_stats[[stage]]
        if (!is.null(stats$temp_mean) && stats$temp_mean != "N/A") {
          has_user_data <- TRUE
          temp_mean <- as.numeric(stats$temp_mean)
          temp_sd <- as.numeric(stats$temp_sd)
          time_mean <- as.numeric(stats$time_mean)
          time_sd <- as.numeric(stats$time_sd)
        }
      }
    }
    
    # Only update columns if user provided data for this stage
    # Otherwise, keep original values from input data
    if (has_user_data) {
      # Sample from normal distributions if columns exist
      if (temp_col %in% names(updated_data_bclc) && !is.na(temp_mean) && !is.na(temp_sd) && temp_sd > 0) {
        updated_data_bclc[[temp_col]] <- rnorm(nrow(updated_data_bclc), mean = temp_mean, sd = temp_sd)
      } else if (temp_col %in% names(updated_data_bclc) && !is.na(temp_mean)) {
        # If SD is 0 or NA, use mean value for all rows
        updated_data_bclc[[temp_col]] <- rep(temp_mean, nrow(updated_data_bclc))
      }
      
      if (time_col %in% names(updated_data_bclc) && !is.na(time_mean) && !is.na(time_sd) && time_sd > 0) {
        updated_data_bclc[[time_col]] <- rnorm(nrow(updated_data_bclc), mean = time_mean, sd = time_sd)
      } else if (time_col %in% names(updated_data_bclc) && !is.na(time_mean)) {
        # If SD is 0 or NA, use mean value for all rows
        updated_data_bclc[[time_col]] <- rep(time_mean, nrow(updated_data_bclc))
      }
      
      # Apply same updates to ModelData_D
      if (temp_col %in% names(updated_data_d) && !is.na(temp_mean) && !is.na(temp_sd) && temp_sd > 0) {
        updated_data_d[[temp_col]] <- rnorm(nrow(updated_data_d), mean = temp_mean, sd = temp_sd)
      } else if (temp_col %in% names(updated_data_d) && !is.na(temp_mean)) {
        updated_data_d[[temp_col]] <- rep(temp_mean, nrow(updated_data_d))
      }
      
      if (time_col %in% names(updated_data_d) && !is.na(time_mean) && !is.na(time_sd) && time_sd > 0) {
        updated_data_d[[time_col]] <- rnorm(nrow(updated_data_d), mean = time_mean, sd = time_sd)
      } else if (time_col %in% names(updated_data_d) && !is.na(time_mean)) {
        updated_data_d[[time_col]] <- rep(time_mean, nrow(updated_data_d))
      }
    }
    # If has_user_data is FALSE, columns keep their original values from input data
  }
  
  # Calculate n_sim from the data (number of unique lots)
  n_sim <- length(unique(updated_data_bclc$lot_id))
  
  # Create ModelData_nogrowth from sampled data (so it has the sampled T and t values)
  # Filter for Growth_category == "A" or postpastcontainer < 1
  # Since we don't have the full original dataset, we'll create it from what we have
  # For now, we'll create an empty ModelData_nogrowth if no A category exists
  # This is a simplified approach - in production, you'd load the full dataset
  
  # Check if we have Growth_category column in BCLc data
  if ("Growth_category" %in% names(updated_data_bclc)) {
    ModelData_A <- updated_data_bclc %>% filter(Growth_category == "A")
  } else {
    ModelData_A <- data.frame()
  }
  
  # Check for zero cell containers
  if ("postpastcontainer" %in% names(updated_data_bclc)) {
    ModelData_filtered <- updated_data_bclc %>% filter(postpastcontainer < 1)
  } else {
    ModelData_filtered <- data.frame()
  }
  
  # Combine to create ModelData_nogrowth
  if (nrow(ModelData_A) > 0 || nrow(ModelData_filtered) > 0) {
    ModelData_nogrowth <- bind_rows(ModelData_A, ModelData_filtered)
  } else {
    # Create empty ModelData_nogrowth with required structure
    ModelData_nogrowth <- updated_data_bclc[0, ]
  }

  # Remove no-growth containers from BCLc data to avoid simulating them
  if (nrow(ModelData_nogrowth) > 0 && "postpastcontainer" %in% names(updated_data_bclc)) {
    updated_data_bclc <- updated_data_bclc %>%
      filter(postpastcontainer >= 1, Growth_category != "A")
  }

  # Create time series for no-growth data (if any exists)
  if (nrow(ModelData_nogrowth) > 0) {
    Day <- rep(0:t_H, times = nrow(ModelData_nogrowth))
    ModelData_nogrowth <- ModelData_nogrowth[rep(1:nrow(ModelData_nogrowth), each = t_H + 1), ]
    ModelData_nogrowth <- cbind(ModelData_nogrowth, Day)
    ModelData_nogrowth$log10N <- ModelData_nogrowth$log10N0
    ModelData_nogrowth$N <- ModelData_nogrowth$N0
  }
  
  if (!is.null(progress_callback)) {
    progress_callback(message = "Processing growth model for medium-growth bacteria...", value = 0.2)
  }
  
  # Process ModelData_BCLc (use updated data with sampled values)
  ModelData_BCLc <- updated_data_bclc
  
  # Adjust growth rates for each supply chain stage based on stage-specific temperature
  ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_F = muAtNewTemp(T_F, growthrate))
  ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_T = muAtNewTemp(T_T, growthrate))
  ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_S = muAtNewTemp(T_S, growthrate))
  ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_T2 = muAtNewTemp(T_T2, growthrate))
  ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_H = muAtNewTemp(T_H, growthrate))
  
  if (!is.null(progress_callback)) {
    progress_callback(message = "Simulating growth for medium-growth bacteria...", value = 0.3)
  }
  
  # Run growth simulation in parallel for all containers
  results_list <- future_map(1:nrow(ModelData_BCLc), ~ simulate_growth_row(ModelData_BCLc[.x, ], t_H))
  ModelData_BCLc <- bind_rows(results_list)
  
  ModelData_BCLc$N <- 10^(ModelData_BCLc$predConc)
  
  if (!is.null(progress_callback)) {
    progress_callback(message = "Processing growth model for high-growth bacteria...", value = 0.5)
  }
  
  # Process ModelData_D (use updated data with sampled values)
  ModelData_D <- updated_data_d
  
  # Prepare temperature profile matrices for dynamic growth model
  env_cond_time <- matrix(c(rep(0, length(ModelData_D$t_F)),
                            ModelData_D$t_F, 
                            ModelData_D$t_F + 0.00001,
                            ModelData_D$t_F + ModelData_D$t_T,
                            ModelData_D$t_F + ModelData_D$t_T + 0.00001,
                            ModelData_D$t_F + ModelData_D$t_T + ModelData_D$t_S,
                            ModelData_D$t_F + ModelData_D$t_T + ModelData_D$t_S + 0.00001,
                            ModelData_D$t_F + ModelData_D$t_T + ModelData_D$t_S + ModelData_D$t_T2,
                            ModelData_D$t_F + ModelData_D$t_T + ModelData_D$t_S + ModelData_D$t_T2 + 0.00001,
                            ModelData_D$t_F + ModelData_D$t_T + ModelData_D$t_S + ModelData_D$t_T2 + ModelData_D$t_H), ncol = 10)
  
  env_cond_temp <- matrix(c(ModelData_D$T_F, 
                            ModelData_D$T_F,
                            ModelData_D$T_T,
                            ModelData_D$T_T,
                            ModelData_D$T_S,
                            ModelData_D$T_S,
                            ModelData_D$T_T2,
                            ModelData_D$T_T2,
                            ModelData_D$T_H,
                            ModelData_D$T_H), ncol = 10)
  
  # Set up simulation parameters
  my_times <- seq(0, t_H)
  num_iterations <- nrow(ModelData_D)
  
  # Function to simulate growth for one container using dynamic growth model
  run_simulation <- function(i) {
    # Primary growth parameters
    my_primary <- list(
      mu_opt = ModelData_D$mu_opt[i],  # Optimal growth rate
      Nmax = ModelData_D$Nmax[i],      # Maximum population density
      N0 = ModelData_D$N0[i],          # Initial concentration
      Q0 = ModelData_D$Q0[i]            # Initial physiological state
    )
    
    # Secondary model: temperature dependence (reduced Ratkowsky model)
    sec_temperature <- list(
      model = "reducedRatkowsky",
      xmin = ModelData_D$Tmin[i],  # Minimum temperature
      b = ModelData_D$b[i],         # Temperature sensitivity
      xopt = ModelData_D$Topt[i]    # Optimal temperature
    )
    
    my_secondary <- list(temperature = sec_temperature)
    
    # Run dynamic growth simulation
    growth <- predict_dynamic_growth(
      times = my_times,
      env_conditions = tibble(
        time = env_cond_time[i, ],
        temperature = env_cond_temp[i, ]
      ),
      my_primary,
      my_secondary
    )
    
    growth$simulation
  }
  
  if (!is.null(progress_callback)) {
    progress_callback(message = "Running growth simulations for high-growth bacteria...", value = 0.6)
  }
  
  # Run simulations in parallel
  all_simulations <- future_map(1:num_iterations, run_simulation)
  
  # Fix simulation results
  row_run <- t_H + 1  # Number of time points (0 to t_H)

  all_simulations_fixed <- map(all_simulations, ~ fix_simulation(.x, row_run))
  
  # Ensure each simulation has exactly row_run rows
  all_simulations_fixed <- map(all_simulations_fixed, function(sim) {
    if (nrow(sim) != row_run) {
      # If simulation has wrong number of rows, fix it
      if (nrow(sim) > row_run) {
        # Take first row_run rows
        sim <- sim[1:row_run, ]
      } else {
        # Pad with last row if needed
        last_row <- sim[nrow(sim), ]
        while (nrow(sim) < row_run) {
          new_row <- last_row
          new_row$time <- nrow(sim)  # Update time
          sim <- bind_rows(sim, new_row)
        }
        sim <- sim[1:row_run, ]
      }
    }
    sim
  })
  
  # Combine all simulation results
  final_conc <- do.call(rbind, all_simulations_fixed)
  count_result <- final_conc %>% dplyr::select(all_of(c("time", "N", "logN")))
  
  # Store original number of rows before expansion
  original_nrows <- nrow(ModelData_D)
  expected_rows <- original_nrows * row_run
  
  # Verify row counts match before combining
  if (nrow(count_result) != expected_rows) {
    stop(paste("Row count mismatch after fixing simulations: expected", expected_rows, "rows but got", nrow(count_result), "rows. Original ModelData_D had", original_nrows, "rows, each should produce", row_run, "rows."))
  }
  
  # Create Day vector and expand ModelData_D
  Day <- rep(0:t_H, times = original_nrows)
  ModelData_D <- ModelData_D[rep(1:original_nrows, each = row_run), ]
  
  # Final check before cbind - all should have expected_rows
  if (nrow(ModelData_D) != expected_rows) {
    stop(paste("ModelData_D expansion failed: expected", expected_rows, "rows but got", nrow(ModelData_D), "rows"))
  }
  if (length(Day) != expected_rows) {
    stop(paste("Day vector length mismatch: expected", expected_rows, "elements but got", length(Day)))
  }
  if (nrow(count_result) != expected_rows) {
    stop(paste("count_result row mismatch: expected", expected_rows, "rows but got", nrow(count_result), "rows"))
  }
  
  ModelData_D <- cbind(ModelData_D, Day, count_result)
  
  if (!is.null(progress_callback)) {
    progress_callback(message = "Combining results and calculating spoilage...", value = 0.8)
  }
  
  # Combine Results and Calculate Spoilage
  # Select relevant columns from each growth category dataset
  if (nrow(ModelData_nogrowth) > 0) {
    ModelData_nogrowth_selected <- ModelData_nogrowth %>%
      dplyr::select(lot_id, unit_id, CFUlotini, Genus, Rel_ab, Log_Reduction, Day, N, T_F, T_T, T_S, T_T2, T_H, t_F, t_T, t_S, t_T2)
  } else {
    # Create empty dataframe with required columns
    ModelData_nogrowth_selected <- data.frame(
      lot_id = integer(0),
      unit_id = integer(0),
      CFUlotini = numeric(0),
      Genus = character(0),
      Rel_ab = numeric(0),
      Log_Reduction = numeric(0),
      Day = integer(0),
      N = numeric(0),
      T_F = numeric(0),
      T_T = numeric(0),
      T_S = numeric(0),
      T_T2 = numeric(0),
      T_H = numeric(0),
      t_F = numeric(0),
      t_T = numeric(0),
      t_S = numeric(0),
      t_T2 = numeric(0)
    )
  }
  
  ModelData_BCLc_selected <- ModelData_BCLc %>%
    dplyr::select(lot_id, unit_id, CFUlotini, Genus, Rel_ab, Log_Reduction, Day, N, T_F, T_T, T_S, T_T2, T_H, t_F, t_T, t_S, t_T2)
  
  ModelData_D_selected <- ModelData_D %>%
    dplyr::select(lot_id, unit_id, CFUlotini, Genus, Rel_ab, Log_Reduction, Day, N, T_F, T_T, T_S, T_T2, T_H, t_F, t_T, t_S, t_T2)
  
  # Combine all growth categories into one dataset
  CombinedData <- rbind(ModelData_nogrowth_selected, 
                        ModelData_BCLc_selected,
                        ModelData_D_selected)
  
  # Reshape data: create separate columns for each genus
  CombinedData_wide <- CombinedData %>%
    pivot_wider(names_from = Genus, values_from = c(Rel_ab, Log_Reduction, N), names_glue = "{Genus}_{.value}")
  
  # Calculate total bacterial concentration per container
  CombinedData_wide <- CombinedData_wide %>%
    mutate(Total_N = rowSums(dplyr::select(., ends_with("_N")), na.rm = TRUE))
  
  # Convert to log10 scale
  CombinedData_wide$log10sumN <- log10(CombinedData_wide$Total_N)
  
  # Determine spoilage status: spoiled if total concentration > 6 log10 CFU/mL
  CombinedData_wide <- CombinedData_wide %>% 
    rowwise() %>% 
    mutate(spoil = log10sumN > log10(1000000))
  
  # Extract results for specific days
  results_d7 <- subset(CombinedData_wide, Day == 7)
  results_d14 <- subset(CombinedData_wide, Day == 14)
  results_d21 <- subset(CombinedData_wide, Day == 21)
  results_d28 <- subset(CombinedData_wide, Day == 28)
  results_d35 <- subset(CombinedData_wide, Day == 35)
  
  # Function to calculate spoilage summary statistics for a given day
  calculate_spoil_stats <- function(results_day, day_num) {
    if (nrow(results_day) == 0) {
      return(list(
        Summary = data.frame(),
        Stats = data.frame(
          Day = as.character(day_num),
          Median_Proportion = NA,
          Mean_Proportion = NA,
          SD_proportion = NA,
          p05 = NA,
          p25 = NA,
          p75 = NA,
          p95 = NA, 
          Median_Bacterial_Concentration = NA,
          p25_Bacterial_Concentration = NA,
          p75_Bacterial_Concentration = NA
        )
      ))
    }
    
    # Calculate spoilage summary per lot
    SpoilSummary <- results_day %>%
      group_by(lot_id) %>%
      summarise(
        Num_Spoiled_Containers = sum(spoil == TRUE, na.rm = TRUE),
        Total_Units = n_distinct(unit_id),
        Proportion_Spoiled = Num_Spoiled_Containers / Total_Units,
        .groups = 'drop'
      )
    
    # Calculate summary statistics across all lots
    SpoilStats <- SpoilSummary %>%
      summarise(
        Day = as.character(day_num),
        Median_Proportion = median(Proportion_Spoiled, na.rm = TRUE),
        Mean_Proportion = mean(Proportion_Spoiled, na.rm = TRUE),
        SD_proportion = sd(Proportion_Spoiled, na.rm = TRUE),
        p05 = quantile(Proportion_Spoiled, 0.05, na.rm = TRUE),
        p25 = quantile(Proportion_Spoiled, 0.25, na.rm = TRUE),
        p75 = quantile(Proportion_Spoiled, 0.75, na.rm = TRUE),
        p95 = quantile(Proportion_Spoiled, 0.95, na.rm = TRUE)
      )
    
    
    Bacterial_Concentration_Stats <- results_day %>%
      ungroup() %>%
      summarise(
        Median_Bacterial_Concentration = median(log10sumN, na.rm = TRUE),
        p25_Bacterial_Concentration = quantile(log10sumN, 0.25, na.rm = TRUE),
        p75_Bacterial_Concentration = quantile(log10sumN, 0.75, na.rm = TRUE)
      )

    Combined_Stats <- cbind(SpoilStats, Bacterial_Concentration_Stats)
    
    
    
    return(list(Summary = SpoilSummary, Stats = Combined_Stats))
  }
  
  if (!is.null(progress_callback)) {
    progress_callback(message = "Calculating spoilage statistics...", value = 0.9)
  }
  
  # Calculate statistics for all days
  stats_d7 <- calculate_spoil_stats(results_d7, 7)
  stats_d14 <- calculate_spoil_stats(results_d14, 14)
  stats_d21 <- calculate_spoil_stats(results_d21, 21)
  stats_d28 <- calculate_spoil_stats(results_d28, 28)
  stats_d35 <- calculate_spoil_stats(results_d35, 35)

  # Combine all statistics
  SpoilStats_all <- rbind(
    stats_d7$Stats,
    stats_d14$Stats,
    stats_d21$Stats,
    stats_d28$Stats,
    stats_d35$Stats
  )
  
  if (!is.null(progress_callback)) {
    progress_callback(message = "Model complete!", value = 1.0)
  }
  
  return(SpoilStats_all)
}

