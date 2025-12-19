## Model-Related Utility Functions
# Combined utility functions for growth models and dynamic growth predictions
# Last edited: 2024

# Required packages
if (!require("deSolve")) install.packages("deSolve")
if (!require("lamW")) install.packages("lamW")
if (!require("dplyr")) install.packages("dplyr")
if (!require("tibble")) install.packages("tibble")
if (!require("purrr")) install.packages("purrr")
if (!require("formula.tools")) install.packages("formula.tools")

library(deSolve)
library(lamW)
library(dplyr)
library(tibble)
library(purrr)
library(formula.tools)

# ============================================================================
# PRIMARY GROWTH MODELS
# ============================================================================

## (1) buchanan_log10N, (2) gompertz_log10N, (3) baranyi_log10N
# Source: All equations for the 3 models below are copied from the Nlms package in R (https://rdrr.io/cran/nlsMicrobio/src/R/growthmodels.R)

# Purpose: Calculate log10N using respective growth model (either buchanan, gompertz, or barayani)

# Parameters: Same for (1) buchanan, (2) gompertz, and (3) barayani
# (i) t: time in hours
# (ii) lag: length of lag phase
# (iii) mumax: growth rate (ln/hour)
# (iv) LOG10N0: initial microbial concentration 
# (v) LOG10Nmax: carrying capacity

# Functions:
buchanan_nl_log10 = function(t, mumax, LOG10N0, LOG10Nmax){
  LOG10N <- LOG10N0 + (t <= ((LOG10Nmax - LOG10N0) /mumax)) * mumax * t + (t > ((LOG10Nmax - LOG10N0) /mumax)) * (LOG10Nmax - LOG10N0)
  return(LOG10N)
}

buchanan_log10N = function(t, lag, mumax, LOG10N0, LOG10Nmax){
  ans <- LOG10N0 + (t >= lag) * (t <= (lag + (LOG10Nmax - LOG10N0) * log(10)/mumax)) * mumax * (t - lag)/log(10) + (t >= lag) * (t > (lag + (LOG10Nmax - LOG10N0) * log(10)/mumax)) * (LOG10Nmax - LOG10N0)
  return(ans)
}

gompertz_log10N = function(t, lag, mumax, LOG10N0, LOG10Nmax) {
  ans <- LOG10N0 + (LOG10Nmax - LOG10N0) * exp(-exp(mumax * exp(1) * (lag - t)/((LOG10Nmax - LOG10N0) * log(10)) + 1))
  return(ans)
}

baranyi_log10N = function(t, lag, mumax, LOG10N0, LOG10Nmax) {
  ans <- LOG10Nmax + log10((-1 + exp(mumax * lag) + exp(mumax * t))/(exp(mumax * t) - 1 + exp(mumax * lag) * 10^(LOG10Nmax - LOG10N0)))
  return(ans)
}

## (4) log10N_func

#Purpose: Implement the appropriate growth model based on provided model_name, in order to calculate log10N 

#Parameters:
# (i) t, (ii) lag, (iii) mumax, (iv) LOG10N0, & (v) LOG10Nmax: Same as for above functions for the 3 growth models
# (vi) model_name: Model to use for calcuating log10N

# Function:
log10N_func <- function(t, lag, mumax, LOG10N0, LOG10Nmax, model_name="buchanan") {
  if (model_name == "buchanan") {
    return(buchanan_log10N(t, lag, mumax, LOG10N0, LOG10Nmax) )
  }
  else if(model_name == 'baranyi') {
    return(baranyi_log10N(t, lag, mumax, LOG10N0, LOG10Nmax) )
  }
  else if(model_name == 'gompertz') {
    return(gompertz_log10N(t, lag, mumax, LOG10N0, LOG10Nmax) )
  }
  else {
    stop(paste0(model_name, " is not a valid model name. Must be one of buchanan, baranyi, gompertz"))
  }
}

# ============================================================================
# DYNAMIC GROWTH MODELS
# ============================================================================

# Define dBaranyi model 
dBaranyi <- function(time, state, pars, env_func, sec_models) {
  pars <- as.list(pars)
  state <- as.list(state)
  alpha <- state$Q/(1 + state$Q) # when lag time = 0, alpha = 1
  beta <- 1 - state$N/pars$Nmax
  gamma <- calculate_gammas(time, env_func, sec_models)
  mu <- pars$mu_opt*prod(gamma)
  mu <- mu*log(10)  # Convert to ln CFU/[t]
  dN <- alpha * mu * beta * state$N 
  dQ <- mu*state$Q
  list(c(dQ = dQ,
         dN = dN))
}

# Define secondary models 
CPM_model <- function(x, xmin, xopt, xmax, n) {
  num <- (x-xmax)*(x-xmin)^n
  den <- (xopt-xmin)^(n-1)*( (xopt-xmin)*(x-xopt) - (xopt-xmax)*((n-1)*xopt + xmin-n*x) )
  gamma <- num/den
  gamma[x < xmin] <- 0
  gamma[x > xmax] <- 0
  return(gamma)
}

zwietering_gamma <- function(x, xmin, xopt, n) {
  gamma <- ((x-xmin)/(xopt-xmin))^n
  gamma[x < xmin] <- 0
  gamma[x > xopt] <- 0
  return(gamma)
}

full_Ratkowski <- function(x, xmin, xmax, c) {
  b <- 1 # Does not affect predictions (see supp. material)
  xopt <- (lambertW0(exp(-xmin*c + xmax*c + 1)) + c*xmin - 1)/c
  mu_opt <- b*(xopt - xmin)*(1 - exp(c*(xopt - xmax)))
  gamma <- b*(x - xmin)*(1 - exp(c*(x - xmax)))
  gamma <- gamma/mu_opt
  gamma <- gamma^2
  gamma[x < xmin] <- 0
  gamma[x > xmax] <- 0
  return(gamma)
}

reduced_Ratkowski <- function(x, xmin, b, xopt){
  mu_opt <- b * (xopt - xmin)
  gamma <- b * (x - xmin)
  gamma <- gamma/mu_opt
  gamma <- gamma^2
  gamma[x < xmin] <- 0
  return(gamma)
}

# Define calculate_gammas
calculate_gammas <- function (this_t, env_func, sec_models) 
{
  out <- lapply(names(sec_models), function(this_condition) {
    this_x <- env_func[[this_condition]](this_t)
    this_sec <- sec_models[[this_condition]]
    this_gamma <- switch(this_sec$model, 
                         fullRatkowsky = full_Ratkowski(this_x, this_sec$xmin, this_sec$xmax, this_sec$c), 
                         CPM = CPM_model(this_x, this_sec$xmin, this_sec$xopt, this_sec$xmax, this_sec$n), 
                         Zwietering = zwietering_gamma(this_x, this_sec$xmin, this_sec$xopt, this_sec$n), 
                         reducedRatkowsky = reduced_Ratkowski(this_x, this_sec$xmin, this_sec$b, this_sec$xopt), 
                         stop(paste("Model",this_sec$model, "not known.")))
    this_gamma
  })
  out <- unlist(out)
  names(out) <- names(sec_models)
  out
}

# Secondary model data
secondary_model_data <- function (model_name = NULL) {
  model_data <- list(CPM = list(identifier = "CPM", 
                                name = "Cardinal Parameter Model", 
                                pars = c("xmin", "xopt", "xmax", "n"), 
                                model = CPM_model, 
                                ref = paste("Rosso, L., Lobry, J. R., Bajard, S., and Flandrois, J. P. (1995).", 
                                            "Convenient Model To Describe the Combined Effects of Temperature and pH on", 
                                            "Microbial Growth. Applied and Environmental Microbiology, 61(2), 610-616.")), 
                     
                     Zwietering = list(identifier = "Zwietering", 
                                       name = "Zwietering gamma function", 
                                       pars = c("xmin", "xopt", "n"), 
                                       model = zwietering_gamma, 
                                       ref = paste("Zwietering, Marcel H., Wijtzes, T., De Wit, J. C., and Riet,", 
                                                   "K. V. (1992). A Decision Support System for Prediction of the Microbial", 
                                                   "Spoilage in Foods. Journal of Food Protection, 55(12), 973-979.", 
                                                   "https://doi.org/10.4315/0362-028X-55.12.973")), 
                     
                     fullRatkowsky = list(identifier = "fullRatkowsky", 
                                          name = "(Adapted) Full Ratkowsky model", 
                                          pars = c("xmin", "xmax", "c"), 
                                          model = full_Ratkowski, 
                                          ref = paste("Ratkowsky, D. A., Lowry, R. K., McMeekin, T. A.,", 
                                                      "Stokes, A. N., and Chandler, R. E. (1983). Model for", 
                                                      "bacterial culture growth rate throughout the entire", 
                                                      "biokinetic temperature range. Journal of Bacteriology,", 
                                                      "154(3), 1222-1226.")),
                     
                     reducedRatkowsky = list(identifier = "reducedRatkowsky", 
                                             name = "Reduced Ratkowsky model", 
                                             pars = c("xmin", "b", "xopt"),
                                             model = reduced_Ratkowski, 
                                             ref = paste("Ratkowsky, D. A., Lowry, R. K., McMeekin, T. A.,", 
                                                         "Stokes, A. N., and Chandler, R. E. (1983). Model for", 
                                                         "bacterial culture growth rate throughout the entire", 
                                                         "biokinetic temperature range. Journal of Bacteriology,", 
                                                         "154(3), 1222-1226.")))
  
  
  if (is.null(model_name)) {
    return(names(model_data))
  }
  my_model <- model_data[[model_name]]
  if (is.null(my_model)) {
    stop(paste("Unknown model name:", model_name))
  }
  else {
    my_model
  }
}

# Define check_secondary_pars
check_secondary_pars <- function (starting_point, known_pars, sec_model_names, primary_pars = "mu_opt") 
{
  if (any(names(starting_point) %in% names(known_pars))) {
    stop("Parameters cannot be defined as both fixed and to be fitted.")
  }
  par_names <- c(names(starting_point), names(known_pars))
  missing_primary <- primary_pars[!primary_pars %in% par_names]
  if (length(missing_primary) > 0) {
    stop(paste("Parameter not defined:", missing_primary, 
               "\n"))
  }
  my_regex <- paste(primary_pars, collapse = "|")
  par_names <- par_names[!grepl(my_regex, par_names)]
  for (each_factor in names(sec_model_names)) {
    model_data <- secondary_model_data(sec_model_names[[each_factor]])
    req_pars <- paste0(each_factor, "_", model_data$pars)
    missing_pars <- req_pars[!req_pars %in% par_names]
    if (length(missing_pars) > 0) {
      stop(paste("Parameter not defined:", missing_pars, 
                 "\n"))
    }
    this_pars <- par_names[grepl(paste0(each_factor, "_"), 
                                 par_names)]
    unknown_pars <- this_pars[!this_pars %in% req_pars]
    if (length(unknown_pars) > 0) {
      stop(paste("Unknown parameter: ", unknown_pars, 
                 "\n"))
    }
  }
  my_regex <- paste(paste0(names(sec_model_names), "_"), collapse = "|")
  wtpars <- par_names[!grepl(my_regex, par_names)]
  if (length(wtpars) > 0) {
    stop(paste("Unknown parameter: ", wtpars, "\n"))
  }
}

# Define approx_env
approx_env <- function (env_conditions) 
{
  out <- lapply(names(env_conditions[-1]), function(this_col) {
    x <- env_conditions$time
    y <- env_conditions[[this_col]]
    approxfun(x, y, rule = 2)
  })
  names(out) <- names(env_conditions[-1])
  out
}

# Define predict_dynamic_growth
predict_dynamic_growth <- function (times, env_conditions, primary_pars, secondary_models, 
          ..., check = TRUE, logbase_logN = 10, logbase_mu = logbase_logN, 
          formula = . ~ time) 
{
  x_col <- formula.tools:::rhs(formula)
  env_conditions <- rename(env_conditions, time = x_col)
  if (isTRUE(check)) {
    sec_model_names <- secondary_models %>% map(~.$model) %>% 
      unlist()
    check_pars_names <- lapply(names(secondary_models), 
                               function(each_factor) {
                                 this_model <- secondary_models[[each_factor]]
                                 this_model$model <- NULL
                                 paste0(each_factor, "_", names(this_model))
                               }) %>% unlist()
    check_pars <- rep(1, length(check_pars_names))
    names(check_pars) <- check_pars_names
    check_secondary_pars(check_pars, unlist(primary_pars), 
                         sec_model_names, primary_pars = c("mu_opt", "N0", 
                                                           "Nmax", "Q0"))
  }
  primary_pars_calc <- primary_pars
  primary_pars_calc$mu_opt <- primary_pars_calc$mu_opt/log(10, 
                                                           base = logbase_mu)
  my_env <- approx_env(env_conditions)
  yini <- c(Q = primary_pars_calc$Q0, N = primary_pars_calc$N0)
  my_sim <- ode(yini, times, dBaranyi, primary_pars_calc, 
                env_func = my_env, sec_models = secondary_models, ...) %>% 
    as.data.frame() %>% as_tibble() %>% mutate(logN = log(.data$N, 
                                                          base = logbase_logN))
  gammas <- lapply(times, function(x) {
    calculate_gammas(x, my_env, secondary_models)
  })
  gammas <- do.call(rbind.data.frame, gammas)
  names(gammas) <- names(secondary_models)
  gammas <- bind_cols(time = times, gammas)
  out <- list(simulation = my_sim, gammas = as_tibble(gammas), 
              env_conditions = my_env, primary_pars = primary_pars, 
              sec_models = secondary_models, logbase_mu = logbase_mu, 
              logbase_logN = logbase_logN)
  class(out) <- c("DynamicGrowth", class(out))
  out
}

# ============================================================================
# TEMPERATURE AND LAG ADJUSTMENT FUNCTIONS
# ============================================================================

## (5) muAtNewTemp

# Source: this function uses Ratkowsky's square root model which describes the effect of temperature on the growth of microorganisms (https://www.ncbi.nlm.nih.gov/pubmed/22417595)

# Purpose: Calculate the new mu parameter at new temperature.

# Parameters: 
# (i) newTemp: New temperature for which we calculate mu
# (ii) oldMu: Previous mu value to adjust
# (iii) oldTemp: Temperature corresponding to previous mu; NOTE: If you don't specify "oldTemp", 
#then automatically oldTemp = 6C; this value (6C) was the temp at which growth curve experiments were originally performed at)
# (iv) T0: Parameter used to calculate new mu; NOTE: If you don't specify "T0", then automatically T0 = -3.62C; this value (-3.62C) 
#was determined using Ratkowsky's square root model and Paenibacillus ordorifer growth curves obtained at 4, 7, and 32C in BHI broth (N.H. Martin unpublished data)

# Function:
muAtNewTemp <- function(newTemp, oldMu, oldTemp = 6, T0 = -3.62) { 
  numerator <- newTemp - T0
  denom <- oldTemp - T0
  newMu <- ((numerator / denom)^2) * oldMu
  
  return(newMu)
}

## (6) adjustLag

# Purpose: Adjust the lag phase based on the Zwietering 1994 paper.

# Parameters:  
# (i) t: Current timestep (in days)
# (ii) oldLag: Lag time (in days) at the previous temperature 
# (iii) newLag: Lag time (in days) at the current temparature 
# (iv) restartExp: If true, then lag phase restarts even if already in exponential growth phase; NOTE: If you don't 
#specify "restartExp", then automatically restartExp = T;
# (v) adjustmentConstant: Amount to adjust lag; NOTE: If you don't provide "adjustmentConstant", 
#then automatically adjustmentConstant = 0.25; Zwietering 1994 paper suggests using adjustmentConstant = 0.25

# Function:
adjustLag <- function (t, oldLag, newLag, restartExp = T, adjustmentConstant = 0.25) {
  #determine the amount of lag phase completed
  remainingLag <- 1 - (t / oldLag)
  if(restartExp) {
    remainingLag <- ifelse(remainingLag < 0, 0, remainingLag)
  }
  else {
    adjustedLag <- ifelse(remainingLag <=0, oldLag,
                          t + remainingLag * newLag + adjustmentConstant*newLag)
  }
  
  adjustedLag <- t + remainingLag*newLag + adjustmentConstant*newLag
  return(adjustedLag)
}

## (7) lagAtNewTemp

# Purpose: Calculate the new lag parameter at new temperature.

# Parameters:
# (i) t: Current timestep (in days)
# (ii) newTemp: New temperature for which we calculate lag
# (iii) oldLag: Previous lag value to adjust
# (iv) oldTemp: Temperature corresponding to previous lag; NOTE: If you don't specify "oldTemp", 
#then automatically oldTemp = 6C; this value (6C) was the temp at which growth curve experiments were originally performed at)
# (v) T0: Parameter used to calculate new mu; NOTE: If you don't specify "T0", then automatically T0 = -3.62C; this value (-3.62C) 
#was determined using Ratkowsky's square root model and Paenibacillus ordorifer growth curves obtained at 4, 7, and 32C in BHI broth (N.H. Martin unpublished data)

# Function:
lagAtNewTemp <- function (newTemp, oldLag, oldTemp = 6, T0 = 1.15) {
  numerator <- oldTemp -T0
  denom <- newTemp - T0
  newLag <- ( (numerator / denom)^2) * oldLag
  return(newLag)
}

# ============================================================================
# DATA PROCESSING AND HELPER FUNCTIONS
# ============================================================================

## (8) getPrevRow

getPrevRow <- function(df, sim_run, milk_unit, day) {
  old_temp <- df[df$lot_id == sim_run & df$milk_unit == milk_unit & df$day==day-1,] 
}

# Purpose: 

# Parameters:
# (i) df: dataframe
# (ii) sim_run:
# (iii) milk_unit:
# (iv) day:

## (9) SampleAT
SampleAT = function(len) {
  AT <- vector()
  for (i in 1:(length(len))){
    AT_samp <- sample(AT_freq, 1,replace = T)
    #while(AT_samp == "AT_23" || AT_samp == "AT_159"){
      #AT_samp <- sample(AT_freq, 1,replace = T)}
    AT<- c(AT,AT_samp)
  }
  return(AT)
}

## (10) sample category

#Purpose: function to sample categories for genera in each lot iteration
#Input: 
  # Data frame that contains lot_ids, unit_ids, and taxa
  # Data frame that defines the category proportions of each genus

assign_category <- function(ModelData, genus_cat) {
  # Ensure the Genus column in both data frames is treated consistently
  ModelData <- ModelData %>%
    mutate(Genus = as.character(Genus))
  
  genus_cat <- genus_cat %>%
    mutate(Genus = as.character(Genus))
  
  # Extract unique Genus-Iteration combinations
  unique_genus_iteration <- ModelData %>%
    dplyr::select(lot_id, Genus) %>%
    distinct()
  
  # Assign a abundance category to each Genus-Iteration combination
  sampled_categories <- unique_genus_iteration %>%
    rowwise() %>%
    mutate(
      category = {
        # Extract the current Genus value
        current_genus <- Genus
        
        # Extract probabilities for the current genus
        genus_row <- genus_cat %>%
          filter(Genus == current_genus)
        
        if (nrow(genus_row) == 0) {
          # If no matching genus is found, return NA
          NA
        } else {
          # Select the A, B, C, D columns as probabilities
          probabilities <- unlist(genus_row[, c("A", "B", "C", "D")])
          
          # Check if probabilities are valid
          if (all(is.na(probabilities)) || sum(probabilities) == 0) {
            NA  # If invalid, assign NA
          } else {
            # Normalize probabilities to ensure they sum to 1
            probabilities <- probabilities / sum(probabilities)
            
            # Sample a category based on probabilities
            sample(c("A", "B", "C", "D"), 1, prob = probabilities)
          }
        }
      }
    ) %>%
    ungroup()
  
  # Join sampled categories back to the full ModelData frame
  ModelData <- ModelData %>%
    left_join(sampled_categories, by = c("lot_id", "Genus"))
  
  return(ModelData)
}

## (11) fix_simulation

fix_simulation <- function(sim) {
  if (nrow(sim) < row_run) {
    # Remove last row (assumed to be decimal time)
    sim_fixed <- sim[-nrow(sim), ]
    
    # Get last two rows
    last_two <- sim_fixed %>% tail(2)
    
    # Check if last row has NaNs
    if (is.na(last_two$N[2]) || is.na(last_two$logN[2])) {
      # Replace last row's values with second-to-last row's values
      sim_fixed[nrow(sim_fixed), c("Q","N", "logN")] <- last_two[1, c("Q","N", "logN")]
      source_row <- last_two[1, ]
    } else {
      source_row <- last_two[2, ]
    }
    
    # Create new rows from next integer time to 40
    new_times <- seq(last_two[2,]$time + 1, row_run-1)
    new_rows <- tibble(
      time = new_times,
      Q = source_row$Q,
      N = source_row$N,
      logN = source_row$logN
    )
    
    # Combine and return
    bind_rows(sim_fixed, new_rows)
  } else {
    sim
  }
}

