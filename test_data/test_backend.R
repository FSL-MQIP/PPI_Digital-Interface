# Backend integration test — runs model with mock user data
# Usage: Rscript test_data/test_backend.R

setwd("D:/GitHub/PPI_Digital-Interface")

cat("=== Loading dependencies ===\n")
suppressPackageStartupMessages({
  source("config/default_parameters.R")
  source("utils/helpers.R")
  source("utils/model_helpers.R")
  source("model/run_model.R")
  library(tidyverse)
  library(furrr)
  library(deSolve)
  library(truncnorm)
  library(EnvStats)
  library(rmutil)
  library(MCMCpack)
  library(fitdistrplus)
})

plan(sequential)  # Keep it simple for testing

# Load baseline temperature profiles
default_profiles <- list()
for (stage in names(default_profile_paths)) {
  path <- default_profile_paths[[stage]]
  if (!is.null(path) && file.exists(path)) {
    data <- read.csv(path, stringsAsFactors = FALSE)
    default_profiles[[stage]] <- extract_temp_profile(data)
  }
}

cat("=== Loading input data (subsampled for speed) ===\n")
ModelData_BCLc_input <- read_csv("input_data/ModelData_BCLc_input.csv", show_col_types = FALSE)
ModelData_D_input <- read_csv("input_data/ModelData_D_input.csv", show_col_types = FALSE)

# Subsample to first 3 lots for faster testing
test_lots <- unique(ModelData_BCLc_input$lot_id)[1:3]
ModelData_BCLc_input <- ModelData_BCLc_input %>% filter(lot_id %in% test_lots)
test_lots_d <- unique(ModelData_D_input$lot_id)[1:3]
ModelData_D_input <- ModelData_D_input %>% filter(lot_id %in% test_lots_d)

cat("  BCLc rows:", nrow(ModelData_BCLc_input), "\n")
cat("  D rows:", nrow(ModelData_D_input), "\n")

# --- Test 1: All defaults (no user data) ---
cat("\n=== Test 1: All defaults ===\n")
result1 <- run_spoilage_model(
  ModelData_BCLc_input = ModelData_BCLc_input,
  ModelData_D_input = ModelData_D_input,
  stage_stats = NULL,
  selected_stages = NULL,
  default_profiles = default_profiles,
  progress_callback = function(message, value) cat("  [", round(value*100), "%]", message, "\n")
)
cat("  Output dimensions:", nrow(result1$SpoilStats_all), "x", ncol(result1$SpoilStats_all), "\n")
cat("  Days:", paste(result1$SpoilStats_all$Day, collapse=", "), "\n")
cat("  Columns:", paste(names(result1$SpoilStats_all), collapse=", "), "\n")
print(result1$SpoilStats_all)
cat("  Pre-consumer spoilage:", result1$pct_spoiled_at_retail, "%\n")
cat("  Consumer days to 25% spoilage:", result1$days_to_25pct_consumer, "\n")
stopifnot(is.numeric(result1$pct_spoiled_at_retail))
stopifnot(result1$pct_spoiled_at_retail >= 0 && result1$pct_spoiled_at_retail <= 100)
stopifnot(is.numeric(result1$days_to_25pct_consumer) || is.na(result1$days_to_25pct_consumer))
cat("  New metrics check: PASSED\n")

# --- Test 2: User data for processing facility + retail ---
cat("\n=== Test 2: User data for 2 stages ===\n")

# Process mock CSVs (simulating what App.R does)
pf_file <- list(datapath = "test_data/processing_facility.csv")
retail_file <- list(datapath = "test_data/retail.csv")

pf_stats <- process_csv_file(pf_file)
retail_stats <- process_csv_file(retail_file)

cat("  Processing facility - temp:", pf_stats$temperature$mean, "±", pf_stats$temperature$sd,
    "| time:", pf_stats$time$mean, "days\n")
cat("  Retail - temp:", retail_stats$temperature$mean, "±", retail_stats$temperature$sd,
    "| time:", retail_stats$time$mean, "days\n")

# Build stage_stats (mimicking App.R reactive values)
stage_stats <- list(
  processing_facility = list(
    temp_mean = pf_stats$temperature$mean,
    temp_sd = pf_stats$temperature$sd,
    time_mean = pf_stats$time$mean,
    time_sd = pf_stats$time$sd
  ),
  transportation_facility_to_retail = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL),
  retail = list(
    temp_mean = retail_stats$temperature$mean,
    temp_sd = retail_stats$temperature$sd,
    time_mean = retail_stats$time$mean,
    time_sd = retail_stats$time$sd
  ),
  transportation_retail_to_home = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL),
  consumer = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL)
)

result2 <- run_spoilage_model(
  ModelData_BCLc_input = ModelData_BCLc_input,
  ModelData_D_input = ModelData_D_input,
  stage_stats = stage_stats,
  selected_stages = c("processing_facility", "retail"),
  default_profiles = default_profiles,
  progress_callback = function(message, value) cat("  [", round(value*100), "%]", message, "\n")
)
cat("  Output dimensions:", nrow(result2$SpoilStats_all), "x", ncol(result2$SpoilStats_all), "\n")
cat("  Days:", paste(result2$SpoilStats_all$Day, collapse=", "), "\n")
print(result2$SpoilStats_all)
cat("  Pre-consumer spoilage:", result2$pct_spoiled_at_retail, "%\n")
cat("  Consumer days to 25% spoilage:", result2$days_to_25pct_consumer, "\n")

# --- Test 3: User data for all 3 stages including consumer ---
cat("\n=== Test 3: User data for 3 stages (incl. consumer) ===\n")

consumer_file <- list(datapath = "test_data/consumer.csv")
consumer_stats <- process_csv_file(consumer_file)
cat("  Consumer - temp:", consumer_stats$temperature$mean, "±", consumer_stats$temperature$sd,
    "| time:", consumer_stats$time$mean, "days\n")

stage_stats3 <- stage_stats
stage_stats3$consumer <- list(
  temp_mean = consumer_stats$temperature$mean,
  temp_sd = consumer_stats$temperature$sd,
  time_mean = consumer_stats$time$mean,
  time_sd = consumer_stats$time$sd
)

result3 <- run_spoilage_model(
  ModelData_BCLc_input = ModelData_BCLc_input,
  ModelData_D_input = ModelData_D_input,
  stage_stats = stage_stats3,
  selected_stages = c("processing_facility", "retail", "consumer"),
  default_profiles = default_profiles,
  progress_callback = function(message, value) cat("  [", round(value*100), "%]", message, "\n")
)
cat("  Output dimensions:", nrow(result3$SpoilStats_all), "x", ncol(result3$SpoilStats_all), "\n")
cat("  Days:", paste(result3$SpoilStats_all$Day, collapse=", "), "\n")
print(result3$SpoilStats_all)
cat("  Pre-consumer spoilage:", result3$pct_spoiled_at_retail, "%\n")
cat("  Consumer days to 25% spoilage:", result3$days_to_25pct_consumer, "\n")

# --- Test: APC CSV processing ---
cat("\n=== Test: APC CSV processing ===\n")
apc_file <- list(datapath = "test_data/apc_measurements.csv")
apc_result <- process_apc_csv(apc_file)
cat("  Extracted mean:", apc_result$mean, "sd:", apc_result$sd, "(log10 CFU/mL)\n")
stopifnot(!is.null(apc_result))
stopifnot(apc_result$mean > 3 && apc_result$mean < 4)  # log10 of ~2100-5500 should be ~3.3-3.7
cat("  APC CSV processing: PASSED\n")

# --- Test 4: User APC data (custom microbial concentration) ---
cat("\n=== Test 4: User APC data ===\n")
cat("  Using custom APC: mean=4.0, sd=0.5 (higher than default 3.52)\n")

# Store original N0 values for comparison
orig_bclc_n0 <- ModelData_BCLc_input$log10N0
orig_d_n0 <- ModelData_D_input$log10N0

result4 <- run_spoilage_model(
  ModelData_BCLc_input = ModelData_BCLc_input,
  ModelData_D_input = ModelData_D_input,
  stage_stats = NULL,
  selected_stages = NULL,
  apc_mean = 4.0,
  apc_sd = 0.5,
  default_profiles = default_profiles,
  progress_callback = function(message, value) cat("  [", round(value*100), "%]", message, "\n")
)
cat("  Output dimensions:", nrow(result4$SpoilStats_all), "x", ncol(result4$SpoilStats_all), "\n")
cat("  Days:", paste(result4$SpoilStats_all$Day, collapse=", "), "\n")
print(result4$SpoilStats_all)
cat("  Pre-consumer spoilage:", result4$pct_spoiled_at_retail, "%\n")
cat("  Consumer days to 25% spoilage:", result4$days_to_25pct_consumer, "\n")

# Verify original data was NOT modified (immutability check)
stopifnot(all.equal(orig_bclc_n0, ModelData_BCLc_input$log10N0))
stopifnot(all.equal(orig_d_n0, ModelData_D_input$log10N0))
cat("  Immutability check: PASSED (original data unchanged)\n")

# --- Test: extract_temp_profile() helper ---
cat("\n=== Test: extract_temp_profile() helper ===\n")
temp_csv_data <- read_csv("input_data/baseline_consumer.csv", show_col_types = FALSE)
profile <- extract_temp_profile(temp_csv_data)
cat("  Profile rows:", nrow(profile), "\n")
cat("  Profile columns:", paste(names(profile), collapse=", "), "\n")
cat("  time_days[1]:", profile$time_days[1], "\n")
cat("  time_days range: [", min(profile$time_days), ",", max(profile$time_days), "]\n")
stopifnot(!is.null(profile))
stopifnot(nrow(profile) > 2)
stopifnot("time_days" %in% names(profile))
stopifnot("temperature" %in% names(profile))
stopifnot(profile$time_days[1] == 0)
cat("  extract_temp_profile: PASSED\n")

# --- Test 5: Dynamic temperature profile (consumer stage) ---
cat("\n=== Test 5: Dynamic temperature profile (consumer stage) ===\n")
cat("  Using baseline_consumer.csv as consumer temp profile\n")

stage_stats_dynamic <- list(
  processing_facility = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL, temp_profile = NULL),
  transportation_facility_to_retail = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL, temp_profile = NULL),
  retail = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL, temp_profile = NULL),
  transportation_retail_to_home = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL, temp_profile = NULL),
  consumer = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL, temp_profile = profile)
)

# Store original N0 values for immutability check
orig_bclc_n0_dyn <- ModelData_BCLc_input$log10N0
orig_d_n0_dyn <- ModelData_D_input$log10N0

result5 <- run_spoilage_model(
  ModelData_BCLc_input = ModelData_BCLc_input,
  ModelData_D_input = ModelData_D_input,
  stage_stats = stage_stats_dynamic,
  selected_stages = c("consumer"),
  default_profiles = default_profiles,
  progress_callback = function(message, value) cat("  [", round(value*100), "%]", message, "\n")
)
cat("  Output dimensions:", nrow(result5$SpoilStats_all), "x", ncol(result5$SpoilStats_all), "\n")
cat("  Days:", paste(result5$SpoilStats_all$Day, collapse=", "), "\n")
print(result5$SpoilStats_all)
cat("  Pre-consumer spoilage:", result5$pct_spoiled_at_retail, "%\n")
cat("  Consumer days to 25% spoilage:", result5$days_to_25pct_consumer, "\n")

# Verify expected dimensions: 5 rows (days 7,14,21,28,35) x expected columns
stopifnot(nrow(result5$SpoilStats_all) == 5)
stopifnot("Day" %in% names(result5$SpoilStats_all))
stopifnot(all(result5$SpoilStats_all$Day == c(7, 14, 21, 28, 35)))
cat("  Dimension check (5 rows, days 7/14/21/28/35): PASSED\n")

# Verify original data was NOT modified (immutability check)
stopifnot(all.equal(orig_bclc_n0_dyn, ModelData_BCLc_input$log10N0))
stopifnot(all.equal(orig_d_n0_dyn, ModelData_D_input$log10N0))
cat("  Immutability check: PASSED (original data unchanged)\n")

cat("  Dynamic temperature profile test: PASSED\n")

# --- Load scenario profiles (mirrors App.R logic) ---
scenario_profiles <- list()
for (scenario_id in names(scenario_profile_paths)) {
  info <- scenario_profile_paths[[scenario_id]]
  if (!is.null(info$path) && file.exists(info$path)) {
    data <- read.csv(info$path, stringsAsFactors = FALSE)
    scenario_profiles[[scenario_id]] <- list(
      profile = extract_temp_profile(data),
      stage   = info$stage,
      label   = info$label
    )
  }
}
cat("\n  Loaded", length(scenario_profiles), "scenario profiles:",
    paste(names(scenario_profiles), collapse = ", "), "\n")

# --- Test 6: Disruption scenario – S1 (facility storage cooling disruption) ---
cat("\n=== Test 6: Disruption scenario S1 (facility storage cooling) ===\n")

scenario_overrides_s1 <- list(processing_facility = scenario_profiles[["s1"]]$profile)

# Store original default_profiles reference for immutability check
orig_pf_profile <- default_profiles[["processing_facility"]]

result6 <- run_spoilage_model(
  ModelData_BCLc_input = ModelData_BCLc_input,
  ModelData_D_input    = ModelData_D_input,
  stage_stats          = NULL,
  selected_stages      = NULL,
  default_profiles     = default_profiles,
  scenario_overrides   = scenario_overrides_s1,
  progress_callback    = function(message, value) cat("  [", round(value * 100), "%]", message, "\n")
)
cat("  Output dimensions:", nrow(result6$SpoilStats_all), "x", ncol(result6$SpoilStats_all), "\n")
cat("  Days:", paste(result6$SpoilStats_all$Day, collapse = ", "), "\n")
print(result6$SpoilStats_all)
cat("  Pre-consumer spoilage:", result6$pct_spoiled_at_retail, "%\n")
cat("  Consumer days to 25% spoilage:", result6$days_to_25pct_consumer, "\n")

stopifnot(nrow(result6$SpoilStats_all) == 5)
stopifnot(ncol(result6$SpoilStats_all) == 11)
stopifnot(all(result6$SpoilStats_all$Day == c(7, 14, 21, 28, 35)))
cat("  Dimension check (5 rows x 11 cols, days 7/14/21/28/35): PASSED\n")

# Immutability: original default_profiles must not have been altered
stopifnot(identical(default_profiles[["processing_facility"]], orig_pf_profile))
cat("  Immutability check: PASSED (original default_profiles unchanged)\n")

cat("  S1 disruption scenario test: PASSED\n")

# --- Test 7: Combined disruption scenarios – S1 + S3 ---
cat("\n=== Test 7: Combined disruption S1 + S3 (facility storage + delivery) ===\n")

scenario_overrides_combined <- list(
  processing_facility            = scenario_profiles[["s1"]]$profile,
  transportation_facility_to_retail = scenario_profiles[["s3"]]$profile
)

orig_pf_profile2      <- default_profiles[["processing_facility"]]
orig_transport_profile <- default_profiles[["transportation_facility_to_retail"]]

result7 <- run_spoilage_model(
  ModelData_BCLc_input = ModelData_BCLc_input,
  ModelData_D_input    = ModelData_D_input,
  stage_stats          = NULL,
  selected_stages      = NULL,
  default_profiles     = default_profiles,
  scenario_overrides   = scenario_overrides_combined,
  progress_callback    = function(message, value) cat("  [", round(value * 100), "%]", message, "\n")
)
cat("  Output dimensions:", nrow(result7$SpoilStats_all), "x", ncol(result7$SpoilStats_all), "\n")
cat("  Days:", paste(result7$SpoilStats_all$Day, collapse = ", "), "\n")
print(result7$SpoilStats_all)
cat("  Pre-consumer spoilage:", result7$pct_spoiled_at_retail, "%\n")
cat("  Consumer days to 25% spoilage:", result7$days_to_25pct_consumer, "\n")

stopifnot(nrow(result7$SpoilStats_all) == 5)
stopifnot(ncol(result7$SpoilStats_all) == 11)
stopifnot(all(result7$SpoilStats_all$Day == c(7, 14, 21, 28, 35)))
cat("  Dimension check (5 rows x 11 cols, days 7/14/21/28/35): PASSED\n")

# Immutability: original default_profiles must not have been altered
stopifnot(identical(default_profiles[["processing_facility"]], orig_pf_profile2))
stopifnot(identical(default_profiles[["transportation_facility_to_retail"]], orig_transport_profile))
cat("  Immutability check: PASSED (original default_profiles unchanged)\n")

cat("  S1 + S3 combined disruption scenario test: PASSED\n")

cat("\n=== All tests completed ===\n")
