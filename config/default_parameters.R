# Default time and temperature parameters for each supply chain stage
# Used when user does not provide their own data

# Default microbial concentration parameters
default_microbial <- list(
  mean = 3.52,
  sd = 0.70,
  b = 5
)

default_parameters <- list(
  processing_facility = list(
    temperature = list(
      min = 3.5,
      max = 4.5,
      mean = 4,
      sd = 0.289
    ),
    time = list(
      min = 1,
      max = 2,
      mean = 1.5,
      sd = 0.289
    )
  ),
  transportation_facility_to_retail = list(
    temperature = list(
      min = 1.7,
      max = 10.0,
      mode = 4.4,
      mean = 5.37,
      sd = 1.72
    ),
    time = list(
      min = 1,
      max = 10,
      mode = 5,
      mean = 5.33,
      sd = 1.84
    )
  ),
  retail = list(
    temperature = list(
      a = -1.4,
      b = 5.4,
      mean = 2.3,
      sd = 1.8
    ),
    time = list(
      a = 0.042,
      b = 10.0,
      mean = 1.821,
      sd = 3.3
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
      mean = 4.06,
      sd = 2.31,
      a = -1,
      b = 15
    ),
    time = list(
      mean = 28,
      sd = 0
    )
  )
)

