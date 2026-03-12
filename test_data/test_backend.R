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
  progress_callback = function(message, value) cat("  [", round(value*100), "%]", message, "\n")
)
cat("  Output dimensions:", nrow(result1), "x", ncol(result1), "\n")
cat("  Days:", paste(result1$Day, collapse=", "), "\n")
cat("  Columns:", paste(names(result1), collapse=", "), "\n")
print(result1)

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
  progress_callback = function(message, value) cat("  [", round(value*100), "%]", message, "\n")
)
cat("  Output dimensions:", nrow(result2), "x", ncol(result2), "\n")
cat("  Days:", paste(result2$Day, collapse=", "), "\n")
print(result2)

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
  progress_callback = function(message, value) cat("  [", round(value*100), "%]", message, "\n")
)
cat("  Output dimensions:", nrow(result3), "x", ncol(result3), "\n")
cat("  Days:", paste(result3$Day, collapse=", "), "\n")
print(result3)

cat("\n=== All tests completed ===\n")
