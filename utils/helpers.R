# Utility functions for the Milk Shelf-life Predictor application

# Helper function to get default parameters for a stage
# @param stage Character string identifying the supply chain stage
# @param param_type Character string: "temperature" or "time"
# @return List with mean and sd values, or "N/A" if not found
get_default_params <- function(stage, param_type) {
  if (stage %in% names(default_parameters)) {
    params <- default_parameters[[stage]][[param_type]]
    if (!is.null(params)) {
      return(list(mean = params$mean, sd = params$sd))
    }
  }
  return(list(mean = "N/A", sd = "N/A"))
}

# Robust function to parse time/date values and convert to numeric days
# Handles various date formats and converts to days (numeric)
# @param time_values Vector of time/date values (can be character, Date, POSIXct, or numeric)
# @return Numeric vector of time values in days
parse_time_to_days <- function(time_values) {
  if (is.null(time_values) || length(time_values) == 0) {
    return(numeric(0))
  }
  
  # Convert to character for consistent processing
  time_values <- as.character(time_values)
  
  # Try to convert to numeric first (if already in days)
  numeric_vals <- suppressWarnings(as.numeric(time_values))
  if (sum(is.na(numeric_vals)) == 0) {
    return(numeric_vals)
  }
  
  # Try parsing as dates
  # Common date formats to try (ordered by likelihood)
  date_formats <- c(
    "%m/%d/%Y %H:%M",      # MM/DD/YYYY HH:MM (e.g., 12/17/2025 10:00)
    "%m/%d/%Y %H:%M:%S",  # MM/DD/YYYY HH:MM:SS
    "%m/%d/%Y",           # MM/DD/YYYY
    "%Y-%m-%d %H:%M:%S",  # YYYY-MM-DD HH:MM:SS
    "%Y-%m-%d %H:%M",     # YYYY-MM-DD HH:MM
    "%Y-%m-%d",           # YYYY-MM-DD
    "%d/%m/%Y %H:%M:%S",  # DD/MM/YYYY HH:MM:SS
    "%d/%m/%Y %H:%M",     # DD/MM/YYYY HH:MM
    "%d/%m/%Y",           # DD/MM/YYYY
    "%Y/%m/%d %H:%M:%S",  # YYYY/MM/DD HH:MM:SS
    "%Y/%m/%d %H:%M",     # YYYY/MM/DD HH:MM
    "%Y/%m/%d"            # YYYY/MM/DD
  )
  
  # Try individual formats and use the one that parses the most values
  best_format <- NULL
  best_parsed <- NULL
  best_count <- 0
  
  for (fmt in date_formats) {
    try_parse <- suppressWarnings(as.POSIXct(time_values, format = fmt))
    success_count <- sum(!is.na(try_parse))
    
    if (success_count > best_count) {
      best_count <- success_count
      best_format <- fmt
      best_parsed <- try_parse
    }
    
    # If we got all values, we're done
    if (success_count == length(time_values)) {
      break
    }
  }
  
  # If we found a good format, use it
  if (!is.null(best_parsed) && best_count > 0) {
    parsed_dates <- best_parsed
  } else {
    # Try as.POSIXct without format as last resort
    parsed_dates <- suppressWarnings(as.POSIXct(time_values))
  }
  
  # If we successfully parsed dates (at least some), convert to absolute POSIXct timestamps
  valid_indices <- which(!is.na(parsed_dates))
  if (length(valid_indices) > 0) {
    # Return absolute timestamps in days since epoch (1970-01-01)
    # This preserves the actual time values
    days_since_epoch <- rep(NA, length(time_values))
    days_since_epoch[valid_indices] <- as.numeric(difftime(parsed_dates[valid_indices], as.POSIXct("1970-01-01", tz = "UTC"), units = "days"))
    return(days_since_epoch)
  }
  
  # If all parsing failed, try one more time with as.Date
  try_date <- suppressWarnings(as.Date(time_values))
  valid_indices <- which(!is.na(try_date))
  if (length(valid_indices) > 0) {
    days_since_epoch <- rep(NA, length(time_values))
    days_since_epoch[valid_indices] <- as.numeric(difftime(try_date[valid_indices], as.Date("1970-01-01"), units = "days"))
    return(days_since_epoch)
  }
  
  # If all parsing failed, return NA
  return(rep(NA, length(time_values)))
}

# Extract temperature statistics from CSV data
# @param data Data frame containing the CSV data
# @return List with mean and sd, or "N/A" if not found
extract_temperature_stats <- function(data) {
  temp_mean <- "N/A"
  temp_sd <- "N/A"
  
  if (is.null(data) || nrow(data) == 0) {
    return(list(mean = temp_mean, sd = temp_sd))
  }
  
  # Extract temperature data
  temp_col <- grep("^temp|^Temp|^TEMPERATURE|^temperature", names(data), ignore.case = TRUE, value = TRUE)
  if (length(temp_col) > 0) {
    temp_values <- as.numeric(data[[temp_col[1]]])
    temp_values <- temp_values[!is.na(temp_values)]
    if (length(temp_values) > 0) {
      temp_mean <- round(mean(temp_values), 2)
      temp_sd <- round(sd(temp_values), 2)
    }
  }
  
  return(list(mean = temp_mean, sd = temp_sd))
}

# Extract time statistics from CSV data
# Calculates difference between first and last row
# @param data Data frame containing the CSV data
# @return List with mean (difference) and sd (always 0 for user data)
extract_time_stats <- function(data) {
  time_mean <- "N/A"
  time_sd <- "N/A"
  
  if (is.null(data) || nrow(data) == 0) {
    return(list(mean = time_mean, sd = time_sd))
  }
  
  # Extract time data
  time_col <- grep("^time$|^Time$|^TIME$", names(data), ignore.case = TRUE, value = TRUE)
  if (length(time_col) > 0) {
    # Parse time values robustly (handles dates and numeric)
    raw_time_values <- data[[time_col[1]]]
    time_values <- parse_time_to_days(raw_time_values)
    
    # Find first and last valid (non-NA) values preserving row order
    valid_indices <- which(!is.na(time_values))
    if (length(valid_indices) > 0) {
      first_valid_idx <- valid_indices[1]
      last_valid_idx <- valid_indices[length(valid_indices)]
      
      # Time mean is the difference between last row and first row time value in days
      time_mean <- round(time_values[last_valid_idx] - time_values[first_valid_idx], 2)
      # Time SD is always 0 for user data
      time_sd <- 0
    }
  }
  
  return(list(mean = time_mean, sd = time_sd))
}

# Process uploaded CSV file and extract statistics
# @param file Shiny fileInput object
# @return List with temperature and time statistics
process_csv_file <- function(file) {
  temp_stats <- list(mean = "N/A", sd = "N/A")
  time_stats <- list(mean = "N/A", sd = "N/A")
  
  if (is.null(file)) {
    return(list(temperature = temp_stats, time = time_stats))
  }
  
  tryCatch({
    data <- read.csv(file$datapath, stringsAsFactors = FALSE)
    temp_stats <- extract_temperature_stats(data)
    time_stats <- extract_time_stats(data)
  }, error = function(e) {
    # Keep default values on error
  })
  
  return(list(temperature = temp_stats, time = time_stats))
}

# Create a summary table row
# @param stage_label Character string for the supply chain stage
# @param data_type Character string: "Temperature" or "Time"
# @param source Character string: "User Upload" or "Default"
# @param mean Numeric or character mean value
# @param sd Numeric or character sd value
# @param unit Character string for the unit
# @return Data frame row for summary table
create_summary_row <- function(stage_label, data_type, source, mean, sd, unit) {
  mean_val <- ifelse(is.numeric(mean) && !is.na(mean), mean, "N/A")
  sd_val <- ifelse(is.numeric(sd) && !is.na(sd), sd, "N/A")

  data.frame(
    `Supply Chain Stage` = stage_label,
    `Data Type` = data_type,
    Source = source,
    Mean = as.character(mean_val),
    SD = as.character(sd_val),
    Unit = unit,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

# Get human-readable label for a supply chain stage
# @param stage Character string identifying the supply chain stage (internal name)
# @return Character string with human-readable stage label
get_stage_label <- function(stage) {
  stage_labels <- c(
    "processing_facility" = "Processing Facility",
    "transportation_facility_to_retail" = "Transportation from facility to retail",
    "retail" = "Retail",
    "transportation_retail_to_home" = "Transportation from retail to home",
    "consumer" = "Consumer"
  )
  
  if (stage %in% names(stage_labels)) {
    return(stage_labels[[stage]])
  } else {
    return(stage)  # Return original if not found
  }
}

# Get all supply chain stage names
# @return Character vector of all stage internal names
get_all_stages <- function() {
  c("processing_facility", "transportation_facility_to_retail", "retail",
    "transportation_retail_to_home", "consumer")
}

# Process uploaded APC CSV file and fit normal distribution
# @param file Shiny fileInput object (must have $datapath)
# @return List with mean and sd of log10 CFU/mL, or NULL on failure
process_apc_csv <- function(file) {
  if (is.null(file)) return(NULL)

  tryCatch({
    data <- read.csv(file$datapath, stringsAsFactors = FALSE)

    # Find APC column (case-insensitive, matches "apc", "cfu", "count", or first numeric column)
    apc_col <- grep("^apc$|^cfu$|^count$|^log10", names(data), ignore.case = TRUE, value = TRUE)
    if (length(apc_col) == 0) {
      # Fall back to first numeric column
      numeric_cols <- sapply(data, is.numeric)
      if (any(numeric_cols)) {
        apc_col <- names(data)[which(numeric_cols)[1]]
      } else {
        return(NULL)
      }
    } else {
      apc_col <- apc_col[1]
    }

    values <- as.numeric(data[[apc_col]])
    values <- values[!is.na(values) & values > 0]
    if (length(values) < 2) return(NULL)

    # Determine if values are already log10-transformed
    # Raw CFU/mL values are typically > 10; log10 values are typically < 10
    if (max(values) > 10) {
      # Assume raw CFU/mL — convert to log10
      values <- log10(values)
    }

    # Fit normal distribution to log10 values
    fit <- fitdistrplus::fitdist(values, "norm")
    list(
      mean = round(fit$estimate[["mean"]], 2),
      sd = round(fit$estimate[["sd"]], 2)
    )
  }, error = function(e) {
    NULL
  })
}

