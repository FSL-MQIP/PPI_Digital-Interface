# JSON stdin -> run_model() -> economics -> plot -> JSON stdout
#
# Usage: echo '{"interventions":{...}}' | Rscript run_simulation.R
#
# Expects to be run with working directory set to milk-spoilage-model/.

library(jsonlite)

# Source the model (sets up parallel workers, loads modules)
source("run_model.R")

# Source plot renderer
# Resolve script directory from command args (works with Rscript)
args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grep("--file=", args)])
if (length(script_path) > 0) {
  script_dir <- dirname(normalizePath(script_path))
} else {
  script_dir <- getwd()
}
source(file.path(script_dir, "render_plot.R"))

# Read JSON from stdin
input_json <- paste(readLines("stdin", warn = FALSE), collapse = "")
if (nchar(trimws(input_json)) == 0) {
  input <- list()
} else {
  input <- fromJSON(input_json, simplifyVector = FALSE)
}

# Parse config overrides
user_config <- NULL
if (!is.null(input$config)) {
  user_config <- config  # start from defaults
  overrides <- input$config
  if (!is.null(overrides$n_lots)) user_config$n_lots <- as.integer(overrides$n_lots)
  if (!is.null(overrides$n_units)) user_config$n_units <- as.integer(overrides$n_units)
  if (!is.null(overrides$P_ppc_min)) user_config$P_ppc_min <- as.numeric(overrides$P_ppc_min)
  if (!is.null(overrides$P_ppc_max)) user_config$P_ppc_max <- as.numeric(overrides$P_ppc_max)
  if (!is.null(overrides$sim_duration)) user_config$sim_duration <- as.integer(overrides$sim_duration)
}

# Parse interventions
interventions <- if (!is.null(input$interventions)) input$interventions else list()

# Parse disruptions — handle preset type
disruptions <- if (!is.null(input$disruptions)) input$disruptions else list()
preset_map <- list(
  s1_cooling_failure = list(
    stage = "processing_facility",
    def = list(type = "profile_csv",
               path = "input_data/scenario_s1_storage_cooling_disruption.csv")),
  s2_delivery_delay = list(
    stage = "processing_facility",
    def = list(type = "profile_csv",
               path = "input_data/scenario_s2_delivery_delay.csv")),
  s3_trunk_opening = list(
    stage = "transportation_facility_to_retail",
    def = list(type = "profile_csv",
               path = "input_data/scenario_s3_trunk_opening.csv")),
  s4_cooling_disruption = list(
    stage = "transportation_facility_to_retail",
    def = list(type = "profile_csv",
               path = "input_data/scenario_s4_delivery_cooling_disruption.csv"))
)

# Expand presets
stages_to_remove <- character()
stages_to_add <- list()
for (stage in names(disruptions)) {
  d <- disruptions[[stage]]
  if (!is.null(d$type) && d$type == "preset" && !is.null(d$name)) {
    preset <- preset_map[[d$name]]
    if (is.null(preset)) {
      stop(paste0("Unknown disruption preset: '", d$name, "'"))
    }
    stages_to_remove <- c(stages_to_remove, stage)
    stages_to_add[[preset$stage]] <- preset$def
  }
}
for (s in stages_to_remove) disruptions[[s]] <- NULL
for (s in names(stages_to_add)) disruptions[[s]] <- stages_to_add[[s]]

# Set seed if provided
if (!is.null(input$seed)) set.seed(as.integer(input$seed))

# Run model
result <- run_model(
  user_config = user_config,
  interventions = interventions,
  disruptions = disruptions
)

# Compute economics
cfg <- result$scenario$config
sl <- result$shelf_life
n_units <- cfg$n_units
container_volume_L <- 1.893  # half-gallon

# Economic shelf-life value: $0.03/unit/day x consumer_days x n_units
# Reference: Lau et al. (2023), Journal of Dairy Science
shelf_life_value_usd <- 0
if (is.finite(sl$consumer_days)) {
  shelf_life_value_usd <- round(sl$consumer_days * 0.03 * n_units, 2)
}

# CO2e: retail waste (landfill) + consumer waste (wastewater)
# Reference: EPA WARM model (2020)
#
# The waste cohort is the spoilage that DEFINES end of shelf life: run_model.R
# ends shelf life on the first day median lot spoilage exceeds threshold_pct, so
# that fraction is spoiled by construction. This partitions it by where it
# spoiled -- the part already gone at retail exit, and the remainder that spoils
# in the consumer's fridge. Read the fraction off threshold_pct rather than
# restating 0.25 here; the two are the same quantity and must move together.
retail_spoiled_frac <- sl$pct_spoiled_at_retail / 100
consumer_spoiled_frac <- max(0, sl$threshold_pct / 100 - retail_spoiled_frac)

retail_waste_L <- retail_spoiled_frac * n_units * container_volume_L
consumer_waste_L <- consumer_spoiled_frac * n_units * container_volume_L
co2e_kg <- round(retail_waste_L * 0.55 + consumer_waste_L * 0.20, 2)

# Render plot
plot_base64 <- render_spoilage_plot(result$daily_median_spoilage, sl$threshold_pct)

# Build lean spoilage summary
#
# seq_len(), not 1:nrow(). spoilage_summary reports cfg$output_days -- 7, 14, 21,
# 28 and 35 -- and run_model.R skips a day the run never reached, so a horizon
# under 7 days leaves it with no rows at all. `1:0` counts DOWN, to c(1, 0), so
# the body then indexed row 1 of an empty frame and round(row$sd, 2) died on the
# NULL it got back. Measured: sim_duration = 4 returned HTTP 500 from /simulate.
# daily_rows below already used seq_len(); this follows it.
spoilage_rows <- lapply(seq_len(nrow(result$spoilage_summary)), function(i) {
  row <- result$spoilage_summary[i, ]
  list(
    day = row$day,
    median_pct = row$median_pct_spoiled,
    mean_pct = row$mean_pct_spoiled,
    sd = round(row$sd, 2),
    P5 = row$P5,
    P95 = row$P95
  )
})

# Build the daily spoilage series
#
# spoilage_summary reports cfg$output_days -- 7, 14, 21, 28 and 35 -- and no
# request key reaches output_days, so a caller cannot add a day to it. The
# shipped supply chain exits retail at 8.25 days, which that set never reports.
# ADR 012 compares two runs at the baseline's pre-consumer day, so the method
# had nothing to read. run_model() already builds this series over every day for
# the shelf-life calculation and the plot; serialise it.
# Rounded to 2 dp to match economics.pct_spoiled_at_retail below, which is the
# same median off this same series at pre_consumer_day. Routes 2 and 3 tell the
# agent the two are one number, so they have to serialise alike: a lot's
# percentage is 100 * spoiled / n_units, which repeats whenever n_units does not
# divide 100 -- at n_units = 3 the run holds 33.3333... and the economics field
# reports 33.33. Rounding one side only makes a documented equality false.
daily_rows <- lapply(seq_len(nrow(result$daily_median_spoilage)), function(i) {
  row <- result$daily_median_spoilage[i, ]
  list(
    day = row$day,
    median_pct = round(row$median_pct, 2),
    P25 = round(row$P25, 2),
    P75 = round(row$P75, 2)
  )
})

# Build output JSON
output <- list(
  spoilage_summary = spoilage_rows,
  daily_spoilage = daily_rows,
  shelf_life = list(
    total_days = if (is.finite(sl$total_days)) sl$total_days else -1,
    consumer_days = if (is.finite(sl$consumer_days)) round(sl$consumer_days, 1) else -1,
    pre_consumer_days = round(sl$pre_consumer_days, 1),
    # The whole day the run evaluates retail exit on, and the day a two-run
    # comparison reads daily_spoilage at. A caller cannot recover it from
    # pre_consumer_days: run_model.R floors full precision, this response rounds
    # to one decimal, and 8.9546 d comes back as 9.0 -- so flooring the response
    # gives day 9 where the run used day 8. Off by one in the direction that
    # compares two arms on a day the baseline has already left retail on.
    pre_consumer_day = floor(sl$pre_consumer_days),
    # The criterion that ends shelf life, and the same fraction the emission
    # calculation partitions. Reported so a client reads the value the run used
    # rather than one restated in prose that can drift away from it.
    threshold_pct = sl$threshold_pct
  ),
  economics = list(
    shelf_life_value_usd = shelf_life_value_usd,
    pct_spoiled_at_retail = round(sl$pct_spoiled_at_retail, 2),
    co2e_kg = co2e_kg
  ),
  plot = plot_base64,
  warnings = if (length(result$warnings) > 0) result$warnings else list(),
  scenario = list(
    interventions_applied = if (length(result$scenario$interventions_applied) > 0)
      result$scenario$interventions_applied else list(),
    disruptions_applied = if (length(result$scenario$disruptions_applied) > 0)
      result$scenario$disruptions_applied else list()
  )
)

# Write JSON to stdout (stderr is reserved for R warnings/messages)
cat(toJSON(output, auto_unbox = TRUE, pretty = FALSE))

# Clean up parallel workers
plan(sequential)
