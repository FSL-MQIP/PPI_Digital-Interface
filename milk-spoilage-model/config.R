# Milk Spoilage Model — Configuration
# All simulation parameters and defaults

# =============================================================================
# SIMULATION PARAMETERS
# =============================================================================
config <- list(
  # Simulation size (n_lots = 10 for testing, increase for production runs)
  n_lots = 200,
  n_units = 50,

  # Simulation duration and output
  sim_duration = 42,         # Total days from production
  output_days = c(7, 14, 21, 28, 35),
  spoilage_threshold = 6.0,  # log10 CFU/mL

  # =============================================================================
  # PPC PARAMETERS
  # =============================================================================
  # PPC frequency per lot (proportion, 0-1)
  P_ppc_min = 0.8,
  P_ppc_max = 1,

  # PPC initial contamination (log10 CFU/mL)
  mean_ppc_N0 = 0.38,
  sd_ppc_N0 = 1.11,

  # PPC minimum growth temperature (Celsius)
  Tmin_PPC = -4.15,

  # PPC reference temperature for Ratkowsky calculation
  T_ref_PPC = 6,

  # PPC mumax correction factor (applied to raw mumax from growth_params CSV)
  ppc_mumax_correction = 0.684,

  # MPN conversion factor (mL per container)
  mpn_conversion = 1900,

  # Genera that form spores, and so are the only ones a spore_reduction
  # intervention removes. Microfiltration and bactofugation act on spores; they do
  # not touch a vegetative cell. Applying the reduction to every genus understates
  # spoilage, which is the wrong direction for this tool.
  #
  # Measured shares in the shipped pools: medium pool Bacillus = 147 of 2,794
  # (5.3%); high pool Bacillus + Paenibacillus = 1,503 of 2,109 (71.3%). So the
  # gate changes the medium pool far more than the high one.
  # Source: docs/research/2026-08-06-port-audit.md, D12.
  spore_forming_genera = c("Bacillus", "Paenibacillus"),

  # =============================================================================
  # TEMPERATURE CONFIGURATION
  # =============================================================================
  # Per-stage temperature settings. Each stage has:
  #   mode: "dynamic" (use CSV profile) or "static" (use mean/sd)
  #   path: CSV file path (used when mode = "dynamic"; NULL if no file)
  #   mean, sd: temperature parameters (used when mode = "static")
  #   duration: stage duration in days
  #   duration_sd: duration std dev in days (optional, default 0)
  # If mode = "dynamic" but path is NULL or file missing, falls back to static with a warning.

  temperature_stages = list(
    processing_facility = list(
      mode = "dynamic",
      path = "input_data/baseline_facility_storage.csv",
      # 2.4264 days, the span of baseline_facility_storage.csv
      # (2026-02-11 21:44:58 to 2026-02-14 07:58:58 = 2 d 10 h 14 m). This was
      # 2.4264 / 24, treating the figure as hours, which under-reported the
      # pre-consumer window by 2.33 d. The profile drives the simulation, so only
      # the reported shelf life was ever affected.
      mean = 1.7037, sd = 0.1111, duration = 2.4264
    ),
    transportation_facility_to_retail = list(
      mode = "dynamic",
      path = "input_data/baseline_transport_to_retail.csv",
      mean = 4.549, sd = 0.8403, duration = 0.3299
    ),
    retail = list(
      mode = "static",
      path = "input_data/baseline_retail.csv",
      mean = 2.3, sd = 0, duration = 1.821, duration_sd = 3.3 
    ),
    transportation_retail_to_home = list(
      mode = "static",
      path = NULL,
      mean = 8.5, sd = 0, duration = 0.04, duration_sd = 0.02
    ),
    consumer = list(
      mode = "static",
      path = "input_data/baseline_consumer.csv",
      mean = 6.5, sd = 0, duration = 27.9583
    )
  ),

  # Supply chain stage order and column mapping
  stage_order = c("processing_facility", "transportation_facility_to_retail",
                  "retail", "transportation_retail_to_home", "consumer"),

  stage_to_cols = list(
    processing_facility = list(temp = "T_F", time = "t_F"),
    transportation_facility_to_retail = list(temp = "T_T", time = "t_T"),
    retail = list(temp = "T_S", time = "t_S"),
    transportation_retail_to_home = list(temp = "T_T2", time = "t_T2"),
    consumer = list(temp = "T_H", time = "t_H")
  )
)
