# Model version 2024-10-11
# Converted from R Markdown to R script

# Load required R packages for data manipulation, statistical distributions, and parallel processing
library(tidyverse)      # Data manipulation: filter, mutate, select, group_by, left_join, etc.
library(fitdistrplus)   # Fit probability distributions to data
library(rmutil)         # Laplace distribution functions
library(truncnorm)      # Truncated normal distribution functions
library(EnvStats)       # Environmental statistics: truncated normal and triangular distributions
library(MCMCpack)       # Dirichlet distribution for sampling relative abundances
library(furrr)          # Parallel processing with future_map() and plan()
library(deSolve)        # Ordinary differential equation solver (used by predict_dynamic_growth)

# Load custom utility functions for growth modeling
source("utils/model_helpers.R")

# Configure parallel processing: use 16 workers for faster computation
plan(multisession, workers = 16)

# Load input data files
ModelData_BCLc <- read.csv("input_data/ModelData_BCLc_input.csv")
ModelData_D <- read.csv("input_data/ModelData_D_input.csv")

# Note: ModelData_nogrowth and n_sim may need to be defined if not present in loaded data
# n_sim can be inferred from the data if needed
# ModelData_nogrowth may need to be loaded separately or created if required

# Adjust growth rates for each supply chain stage based on stage-specific temperature
# Growth rate is temperature-dependent and adjusted using muAtNewTemp function
ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_F = muAtNewTemp(T_F, growthrate))
ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_T = muAtNewTemp(T_T, growthrate))
ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_S = muAtNewTemp(T_S, growthrate))
ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_T2 = muAtNewTemp(T_T2, growthrate))
ModelData_BCLc <- ModelData_BCLc %>% mutate(newGR_H = muAtNewTemp(T_H, growthrate))



# Function to simulate growth for a single container over 40 days
# Uses Buchanan model without lag phase (buchanan_nl_log10)
# OPTIMIZED: Vectorized operations replace rowwise() for 2-3x speedup
simulate_growth_row <- function(row_data) {
  # OPTIMIZATION: Extract single row values upfront to avoid repeated column indexing
  t_F_val <- row_data$t_F[1]
  t_T_val <- row_data$t_T[1]
  t_S_val <- row_data$t_S[1]
  t_T2_val <- row_data$t_T2[1]
  dur1 <- c(t_F_val,t_T_val, t_S_val, t_T2_val)
  t_H_val <- 40 - sum(dur1)
  dur <- c(t_F_val,t_T_val, t_S_val, t_T2_val, t_H_val) # create vector from stage durations
  
  newGR_F_val <- row_data$newGR_F[1]
  newGR_T_val <- row_data$newGR_T[1]
  newGR_S_val <- row_data$newGR_S[1]
  newGR_T2_val <- row_data$newGR_T2[1]
  newGR_H_val <- row_data$newGR_H[1]
  rate <- c(newGR_F_val,newGR_T_val, newGR_S_val,newGR_T2_val, newGR_H_val) # create vector from growth rates
  
  N0 <- row_data$log10N0[1]
  Nmax <- row_data$log10Nmax[1]
  
  # Create time series: one row per day (0 to 40)
  days <- 0:40
  n_days <- length(days)
  
  # Derived: stage boundaries
  start <- c(0, cumsum(dur)[-length(dur)])
  end   <- cumsum(dur)

  
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
    Day   = days,
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


# Run growth simulation in parallel for all containers
results_list <- future_map(1:nrow(ModelData_BCLc), ~ simulate_growth_row(ModelData_BCLc[.x, ]))
ModelData_BCLc <- bind_rows(results_list)

ModelData_BCLc$N <- 10^(ModelData_BCLc$predConc)

# Save intermediate output: ModelData_BCLc
# write.csv(ModelData_BCLc, "Output/ModelData_BCLc_optimized_revised_results.csv", row.names = FALSE)
# cat("ModelData_BCLc saved to: Output/ModelData_BCLc_optimized_revised_results.csv\n")

# Prepare temperature profile matrices for dynamic growth model
# Each row represents one container's temperature profile over time
# Matrix columns represent transition points between supply chain stages
env_cond_time <- matrix(c(rep(0,length(ModelData_D$t_F)),
                          ModelData_D$t_F, 
                          ModelData_D$t_F+0.00001,  # Small increment to mark stage transition
                          ModelData_D$t_F + ModelData_D$t_T,
                          ModelData_D$t_F + ModelData_D$t_T+0.00001,
                          ModelData_D$t_F + ModelData_D$t_T + ModelData_D$t_S,
                          ModelData_D$t_F + ModelData_D$t_T + ModelData_D$t_S+0.00001,
                          ModelData_D$t_F + ModelData_D$t_T + ModelData_D$t_S + ModelData_D$t_T2,
                          ModelData_D$t_F + ModelData_D$t_T + ModelData_D$t_S + ModelData_D$t_T2+0.00001,
                          ModelData_D$t_F + ModelData_D$t_T + ModelData_D$t_S + ModelData_D$t_T2 + ModelData_D$t_H), ncol = 10)

# Temperature values at each transition point
env_cond_temp <- matrix(c(ModelData_D$T_F, 
                          ModelData_D$T_F,    # Same temp at transition
                          ModelData_D$T_T,
                          ModelData_D$T_T,
                          ModelData_D$T_S,
                          ModelData_D$T_S,
                          ModelData_D$T_T2,
                          ModelData_D$T_T2,
                          ModelData_D$T_H,
                          ModelData_D$T_H), ncol = 10)

# Set up simulation parameters
my_times <- seq(0, 40)  # Time points for simulation (days 0-40)
num_iterations <- nrow(ModelData_D)
all_simulations <- list()

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

# Run simulations in parallel for all containers
all_simulations <- future_map(1:num_iterations, run_simulation)
# Fix simulation results (handles any numerical issues)
row_run <- 41  # Number of time points (0 to 40)
all_simulations_fixed <- map(all_simulations, fix_simulation)

# Combine all simulation results
final_conc <- do.call(rbind, all_simulations_fixed)
# Select columns using all_of() to avoid tidyselect deprecation warning
count_result <- final_conc %>% dplyr::select(all_of(c("time","N","logN")))
Day <- rep(0:40, times=nrow(ModelData_D))
ModelData_D <- ModelData_D[rep(1:nrow(ModelData_D), each = 41), ]
ModelData_D <- cbind(ModelData_D, Day, count_result)

# Save intermediate output: ModelData_D
# write.csv(ModelData_D, "Output/ModelData_D_optimized_revised_results.csv", row.names = FALSE)
# cat("ModelData_D saved to: Output/ModelData_D_optimized_revised_results.csv\n")

## 15. Combine Results and Calculate Spoilage

# Select relevant columns from each growth category dataset
ModelData_nogrowth_selected <- ModelData_nogrowth %>%
  dplyr::select(lot_id, unit_id, CFUlotini, Genus, Rel_ab, Log_Reduction, Day, N, T_F, T_T, T_S, T_T2, T_H, t_F, t_T, t_S, t_T2)

ModelData_BCLc_selected <- ModelData_BCLc %>%
  dplyr::select(lot_id, unit_id, CFUlotini, Genus, Rel_ab, Log_Reduction, Day, N, T_F, T_T, T_S, T_T2, T_H, t_F, t_T, t_S, t_T2)

#ModelData_Enterococcus_selected <- ModelData_Enterococcus %>%
#  dplyr::select(lot_id, unit_id, CFUlotini, Genus, Rel_ab, Log_Reduction, Day, N, T_F, T_T, T_S, T_T2, T_H, t_F, t_T, t_S, t_T2)

ModelData_D_selected <- ModelData_D %>%
  dplyr::select(lot_id, unit_id, CFUlotini, Genus, Rel_ab, Log_Reduction, Day, N, T_F, T_T, T_S, T_T2, T_H, t_F, t_T, t_S, t_T2)

# Combine all growth categories into one dataset
CombinedData <- rbind(ModelData_nogrowth_selected, 
                      ModelData_BCLc_selected,
                      #ModelData_Enterococcus_selected,
                      ModelData_D_selected)

# Reshape data: create separate columns for each genus
# This allows summing concentrations across all genera per container
CombinedData_wide <- CombinedData %>%
  pivot_wider(names_from = Genus, values_from = c(Rel_ab, Log_Reduction, N), names_glue = "{Genus}_{.value}")


# Calculate total bacterial concentration per container (sum across all genera)
CombinedData_wide <- CombinedData_wide %>%
  mutate(Total_N = rowSums(dplyr::select(., ends_with("_N")), na.rm = TRUE))

# Convert to log10 scale
CombinedData_wide$log10sumN = log10(CombinedData_wide$Total_N)

# Determine spoilage status: spoiled if total concentration > 6 log10 CFU/mL (1,000,000 CFU/mL)
CombinedData_wide = CombinedData_wide %>% 
  rowwise() %>% 
  mutate(spoil = log10sumN > log10(1000000)) 

# Extract results for specific days
results_d7 <- subset(CombinedData_wide, Day==7)
results_d14 <- subset(CombinedData_wide, Day==14)
results_d21 <- subset(CombinedData_wide, Day==21)
results_d28 <- subset(CombinedData_wide, Day==28)
results_d35 <- subset(CombinedData_wide, Day==35)
results_all_days <- CombinedData_wide

# Function to calculate spoilage summary statistics for a given day
calculate_spoil_stats <- function(results_day, day_num) {
  # Calculate spoilage summary per lot
  SpoilSummary <- results_day %>%
    group_by(lot_id) %>%
    summarise(
      Num_Spoiled_Containers = sum(spoil == TRUE, na.rm = TRUE),
      Total_Units = n_distinct(unit_id),
      Proportion_Spoiled = Num_Spoiled_Containers / Total_Units
    )
  
  # Calculate summary statistics across all lots
  SpoilStats <- SpoilSummary %>%
    summarise(
      Day = as.character(day_num),
      Median_Proportion = median(Proportion_Spoiled, na.rm = TRUE),
      Mean_Proportion = mean(Proportion_Spoiled, na.rm = TRUE),
      SD_proportion = sd(Proportion_Spoiled),
      p05 = quantile(Proportion_Spoiled, 0.05, na.rm = TRUE),
      p25 = quantile(Proportion_Spoiled, 0.25, na.rm = TRUE),
      p75 = quantile(Proportion_Spoiled, 0.75, na.rm = TRUE),
      p95 = quantile(Proportion_Spoiled, 0.95, na.rm = TRUE),
    )
  
  return(list(Summary = SpoilSummary, Stats = SpoilStats))
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

print(SpoilStats_all)

# Save spoilage statistics to output folder
# write.csv(SpoilStats_all, "Output/SpoilStats_all_days_optimized_revised_results.csv", row.names = FALSE)
# cat("Spoilage statistics saved to: Output/SpoilStats_all_days_optimized_revised_results.csv\n")

# Keep SpoilSummary_D21 for delta calculation (backward compatibility)
SpoilSummary_D21 <- stats_d21$Summary

# Calculate uncertainty metric (delta) for proportion spoiled
SpoilSummary_D21$Proportion_Spoiledx100 <- SpoilSummary_D21$Proportion_Spoiled*100

median_spoiled <- median(SpoilSummary_D21$Proportion_Spoiledx100, na.rm = TRUE)
alpha <- 0.05  # Significance level (5%)
n <- n_sim     # Sample size (number of lots)
df <- n - 1    # Degrees of freedom

# Calculate t-value for confidence interval
t_value <- qt(1 - alpha/2, df)

# Calculate delta: relative uncertainty (coefficient of variation of the median)
delta = (t_value*sqrt(sd(SpoilSummary_D21$Proportion_Spoiledx100)^2/n))/median_spoiled
# write.csv(delta, "Output/delta_optimized_revised_results.csv", row.names = FALSE)

# Save final model output: CombinedData_wide
# write.csv(CombinedData_wide, "Output/CombinedData_wide_optimized_revised_results.csv", row.names = FALSE)
# cat("Final model output saved to: Output/CombinedData_wide_optimized_revised_results.csv\n")

