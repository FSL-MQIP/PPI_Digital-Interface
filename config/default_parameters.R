# Default time and temperature parameters for each supply chain stage
# Used when user does not provide their own data
# Values computed from baseline CSVs (mean/SD of temperature, time span from first to last timestamp)

# Default microbial concentration parameters
default_microbial <- list(
  mean = 3.52,
  sd = 0.70,
  b = 5
)

default_parameters <- list(
  processing_facility = list(
    temperature = list(
      mean = 1.7037,
      sd = 0.1111
    ),
    time = list(
      mean = 2.4264,
      sd = 0
    )
  ),
  transportation_facility_to_retail = list(
    temperature = list(
      mean = 4.549,
      sd = 0.8403
    ),
    time = list(
      mean = 0.3299,
      sd = 0
    )
  ),
  retail = list(
    temperature = list(
      mean = 6.5,
      sd = 0
    ),
    time = list(
      mean = 5.4583,
      sd = 0
    )
  ),
  transportation_retail_to_home = list(
    temperature = list(
      a = 0,
      b = 10,
      mean = 8.5,
      sd = 1.0
    ),
    time = list(
      a = 0.01,
      b = 0.24,
      mean = 0.04,
      sd = 0.02
    )
  ),
  consumer = list(
    temperature = list(
      mean = 6.5,
      sd = 0
    ),
    time = list(
      mean = 27.9583,
      sd = 0
    )
  )
)

default_profile_paths <- list(
  processing_facility = "input_data/baseline_facility_storage.csv",
  transportation_facility_to_retail = "input_data/baseline_transport_to_retail.csv",
  retail = "input_data/baseline_retail.csv",
  transportation_retail_to_home = NULL,
  consumer = "input_data/baseline_consumer.csv"
)

scenario_profile_paths <- list(
  s1 = list(
    path = "input_data/scenario_s1_storage_cooling_disruption.csv",
    stage = "processing_facility",
    label = "S1: Storage Cooling System Disruption"
  ),
  s2 = list(
    path = "input_data/scenario_s2_delivery_delay.csv",
    stage = "processing_facility",
    label = "S2: Delivery Delay"
  ),
  s3 = list(
    path = "input_data/scenario_s3_trunk_opening.csv",
    stage = "transportation_facility_to_retail",
    label = "S3: Temp Increase (Trunk Opening)"
  ),
  s4 = list(
    path = "input_data/scenario_s4_delivery_cooling_disruption.csv",
    stage = "transportation_facility_to_retail",
    label = "S4: Delivery Cooling System Disruption"
  )
)
