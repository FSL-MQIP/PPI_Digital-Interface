# No-Growth Pathway (A) — bacteria with no growth capability
# Source: PPI_Digital-Interface/model/run_model.R lines 299-340
# Concentration remains constant at initial level

run_nogrowth_pathway <- function(nogrowth_data, sim_duration) {
  # nogrowth_data: data frame with columns lot_id, unit_id, N0, log10N0
  #   sampled from the pre-generated container pool (rows where
  #   Growth_category == "A" or postpastcontainer < 1)

  if (nrow(nogrowth_data) == 0) {
    return(data.frame(lot_id = integer(0), unit_id = integer(0),
                      day = integer(0), log10_concentration = numeric(0),
                      N = numeric(0), pathway = character(0)))
  }

  n_days <- sim_duration + 1  # Days 0 to sim_duration

  # Create time series: repeat each row for each day (run_model.R lines 335-339)
  Day <- rep(0:sim_duration, times = nrow(nogrowth_data))
  expanded <- nogrowth_data[rep(1:nrow(nogrowth_data), each = n_days), ]

  result <- data.frame(
    lot_id = expanded$lot_id,
    unit_id = expanded$unit_id,
    day = Day,
    log10_concentration = expanded$log10N0,
    N = expanded$N0,
    pathway = "nogrowth"
  )

  return(result)
}
