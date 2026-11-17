# Verification baseline: PPC pathway concentration distribution
# Runs the PPC model code from Digital-dairy-platform with fixed seed
# Saves distributional summaries (quantiles per day) for comparison

set.seed(42)

library(dplyr)
library(tidyr)
library(tibble)
library(purrr)
library(deSolve)
library(lamW)
library(formula.tools)
library(truncnorm)

# Determine script directory
args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("--file=", "", args[grep("--file=", args)])
if (length(script_path) > 0) {
  script_dir <- dirname(normalizePath(script_path))
} else {
  script_dir <- getwd()
}
ddp_dir <- file.path(script_dir, "..", "Digital-dairy-platform")
setwd(ddp_dir)
cat("Working directory:", getwd(), "\n")

source("UtilityFunctions.R")
source("UtilityFunctions_dynamic_growth.R")

# Load data (server.R lines 27-56)
data_ppc <- read.csv("InputData/ppc_gp.csv")
data_ppc$mumax <- 0.684 * data_ppc$mumax
ppc_ST_freq <- read.csv("InputData/ppc_STfreq_clean.csv")

data_ppc$h0 <- data_ppc$lag * data_ppc$mumax
Tmin_PPC <- -4.15
T_PPC <- 6
data_ppc$b <- sqrt(data_ppc$mumax / log(10) * 24) / (T_PPC - Tmin_PPC)

result_df <- data_ppc %>%
  group_by(isolate) %>%
  reframe(
    Mean_h0 = mean(h0), StdDev_h0 = sd(h0),
    Mean_b = mean(b), StdDev_b = sd(b),
    Mean_LOG10Nmax = mean(LOG10Nmax), StdDev_LOG10Nmax = sd(LOG10Nmax),
    Topt = Topt
  ) %>% distinct()
result_df <- as.data.frame(result_df)
result_df$STorAT <- paste0("ST_", unique(data_ppc$STorAT))
growth_parameter <- result_df

# Generate 500 PPC containers with PPI temperature defaults
n_containers <- 500
data <- data.frame(lot_id = rep(1, n_containers), unit_id = 1:n_containers)

data$T_F <- rnorm(n_containers, mean = 1.7037, sd = 0.1111)
data$t_F <- rep(2.4264 / 24, n_containers)
data$T_T <- rnorm(n_containers, mean = 4.549, sd = 0.8403)
data$t_T <- rep(0.3299, n_containers)
data$T_S <- rep(6.5, n_containers)
data$t_S <- rep(5.4583, n_containers)
data$T_T2 <- rnorm(n_containers, mean = 8.5, sd = 1.0)
data$t_T2 <- pmax(rnorm(n_containers, mean = 0.04, sd = 0.02), 0.001)
data$T_H <- rep(6.5, n_containers)
data$t_H <- rep(27.9583, n_containers)

# Assign ST types
data$STorAT <- NA
for (i in 1:n_containers) {
  sampled_value <- sample(ppc_ST_freq$ClosestST, 1, replace = TRUE)
  while (sampled_value == "9_23") {
    sampled_value <- sample(ppc_ST_freq$ClosestST, 1, replace = TRUE)
  }
  data$STorAT[i] <- sampled_value
}
data$STorAT <- paste0("ST_", data$STorAT)

# Sample initial contamination
data <- data %>% rowwise() %>% mutate(N0 = rnorm(1, mean = 0.38, sd = 1.11))

# Partial cell filtering
data$N0_MPN_ppc <- 10^data$N0 * 1900
data_filtered <- subset(data, N0_MPN_ppc < 1)
data_filtered$new_column <- runif(nrow(data_filtered))
data_filtered$N0_MPN_ppc_assigned <- ifelse(
  data_filtered$N0_MPN_ppc > data_filtered$new_column, 1,
  ifelse(data_filtered$N0_MPN_ppc < data_filtered$new_column, 0, NA))
data_filtered <- data_filtered[, !(names(data_filtered) %in% c("N0_MPN_ppc", "new_column"))]
names(data_filtered)[names(data_filtered) == "N0_MPN_ppc_assigned"] <- "N0_MPN_ppc"
filtered_rows <- anti_join(data, data_filtered, by = c("lot_id", "unit_id"))
data <- rbind(filtered_rows, data_filtered)
data$N0 <- data$N0_MPN_ppc / 1900
data <- subset(data, select = -N0_MPN_ppc)
data <- as.data.frame(data)

# Assign growth parameters
data$allele_index <- match(data$STorAT, growth_parameter$STorAT)
data$Mean_h0 <- growth_parameter$Mean_h0[data$allele_index]
data$StdDev_h0 <- growth_parameter$StdDev_h0[data$allele_index]
data$Mean_b <- growth_parameter$Mean_b[data$allele_index]
data$StdDev_b <- growth_parameter$StdDev_b[data$allele_index]
data$Mean_Nmax <- growth_parameter$Mean_LOG10Nmax[data$allele_index]
data$StdDev_Nmax <- growth_parameter$StdDev_LOG10Nmax[data$allele_index]
data$Topt <- growth_parameter$Topt[data$allele_index]

data <- data %>% rowwise() %>%
  mutate(h0 = rtruncnorm(1, a = 0, mean = Mean_h0, sd = StdDev_h0))
data$Q0 <- 1 / (exp(data$h0) - 1)
data <- data %>% rowwise() %>%
  mutate(b = rtruncnorm(1, a = 0, mean = Mean_b, sd = StdDev_b))
data <- data %>% rowwise() %>%
  mutate(Nmax = rnorm(1, mean = Mean_Nmax, sd = StdDev_Nmax))
data$Nmax <- 10^(data$Nmax)
data$Tmin <- Tmin_PPC
data$mu_opt <- (data$b * (data$Topt - data$Tmin))^2
data <- as.data.frame(data)

# Temperature matrices
n_ppc <- nrow(data)
env_cond_time <- matrix(c(
  rep(0, n_ppc),
  data$t_F, data$t_F + 1e-5,
  data$t_F + data$t_T, data$t_F + data$t_T + 1e-5,
  data$t_F + data$t_T + data$t_S, data$t_F + data$t_T + data$t_S + 1e-5,
  data$t_F + data$t_T + data$t_S + data$t_T2,
  data$t_F + data$t_T + data$t_S + data$t_T2 + 1e-5,
  data$t_F + data$t_T + data$t_S + data$t_T2 + data$t_H
), ncol = 10)

env_cond_temp <- matrix(c(
  data$T_F, data$T_F, data$T_T, data$T_T,
  data$T_S, data$T_S, data$T_T2, data$T_T2,
  data$T_H, data$T_H
), ncol = 10)

# Run growth simulation
my_times <- seq(0, 40)
all_simulations <- list()
cat("Running PPC growth simulation for", n_ppc, "containers...\n")
for (i in 1:n_ppc) {
  my_primary <- list(mu_opt = data$mu_opt[i], Nmax = data$Nmax[i],
                     N0 = data$N0[i], Q0 = data$Q0[i])
  sec_temperature <- list(model = "reducedRatkowsky",
                          xmin = data$Tmin[i], b = data$b[i], xopt = data$Topt[i])
  my_secondary <- list(temperature = sec_temperature)
  growth <- predict_dynamic_growth(
    times = my_times,
    env_conditions = tibble(time = env_cond_time[i, ], temperature = env_cond_temp[i, ]),
    my_primary, my_secondary
  )
  all_simulations[[i]] <- growth$simulation
  if (i %% 100 == 0) cat("  Completed", i, "/", n_ppc, "\n")
}

final_conc <- do.call(rbind, all_simulations)
n_days <- length(my_times)
data_expanded <- data[rep(1:nrow(data), each = n_days), ]

ppc_result <- data.frame(
  day = final_conc$time,
  log10_concentration = ifelse(final_conc$logN == -Inf, -2, final_conc$logN)
)

# Calculate distributional summary per day
ppc_distribution <- ppc_result %>%
  group_by(day) %>%
  summarise(
    n = n(),
    mean = mean(log10_concentration, na.rm = TRUE),
    sd = sd(log10_concentration, na.rm = TRUE),
    P5 = quantile(log10_concentration, 0.05, na.rm = TRUE),
    P25 = quantile(log10_concentration, 0.25, na.rm = TRUE),
    median = median(log10_concentration, na.rm = TRUE),
    P75 = quantile(log10_concentration, 0.75, na.rm = TRUE),
    P95 = quantile(log10_concentration, 0.95, na.rm = TRUE),
    .groups = "drop"
  )

cat("\nPPC concentration distribution at key days:\n")
print(ppc_distribution %>% filter(day %in% c(7, 14, 21, 28, 35)))

# Save
output_dir <- file.path(script_dir)
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
write.csv(ppc_distribution, file.path(output_dir, "baseline_ppc_distribution.csv"), row.names = FALSE)
cat("\nSaved to verification/baseline_ppc_distribution.csv\n")
