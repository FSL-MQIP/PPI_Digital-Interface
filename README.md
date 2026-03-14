# Milk Shelf-life Predictor

A Shiny R application for predicting milk spoilage percentages using a two-dimensional Monte Carlo simulation that models survival during pasteurization and subsequent growth of the bulk tank raw milk (BTRM) bacterial community across the dairy supply chain.

## Overview

This interactive web application provides a predictive model for analyzing supply chain data related to milk spoilage. The model integrates metagenomic-informed community composition, taxon-specific heat resistance (including spore-formers, thermodurics, and heat-sensitive taxa), and temperature-dependent growth to estimate lot-level spoilage risk over shelf life.

The application supports the following supply chain stages:
- **Processing Facility** - Initial milk processing (HTST pasteurization)
- **Transportation (Facility to Retail)** - Distribution from processing to retail
- **Retail** - Storage at retail locations
- **Transportation (Retail to Home)** - Consumer transport from store
- **Consumer** - Home storage

## Features

- **Interactive Dashboard**: User-friendly interface built with Shiny Dashboard (Cornell red theme)
- **Monte Carlo Simulation**: Two-dimensional Monte Carlo simulation for robust spoilage prediction
- **Custom APC Input**: Enter microbial concentration manually or upload APC measurement CSV
- **Flexible Data Input**: Accept user-provided time-temperature profiles or use baseline profiles
- **Dynamic Temperature Profiles**: D pathway ODE solver uses hourly temperature profiles for realistic growth modeling
- **Disruption Scenarios**: Four pre-configured disruption scenarios (S1-S4) that can be combined
- **Spoilage Prediction Plot**: Median spoiled % over time with P25-P75 interquartile ribbon
- **Key Metrics**:
  - Pre-consumer spoilage rate (% spoiled at end of retail)
  - Consumer shelf life (days until 25% of containers spoiled)
- **Economic & Environmental Analysis**: Scenario vs baseline comparison showing economic loss and CO₂e impact
- **CSV Upload**: Support for time-temperature profile uploads with automatic statistics extraction
- **Robust Date Parsing**: Handles multiple date/time formats
- **Parallel Processing**: Adaptive configuration (sequential on shinyapps.io, multisession locally)
- **Progress Tracking**: Real-time progress indicators during model execution
- **Statistical Output**: Median, mean, SD, and percentiles (5th, 25th, 75th, 95th) for spoilage predictions at days 7, 14, 21, 28, and 35

## Installation

### Prerequisites

- R (version 4.0 or higher recommended)
- RStudio (optional, but recommended)

### Required R Packages

```r
install.packages(c(
  "shiny",
  "shinydashboard",
  "tidyverse",
  "fitdistrplus",
  "rmutil",
  "truncnorm",
  "EnvStats",
  "MCMCpack",
  "furrr",
  "deSolve"
))
```

## Usage

### Running the Application

1. **Clone the repository:**
   ```bash
   git clone https://github.com/FSL-MQIP/PPI_Digital-Interface.git
   cd PPI_Digital-Interface
   ```

2. **Open R or RStudio and run:**
   ```r
   shiny::runApp()
   ```

3. **Access the application:**
   The app will open in your default web browser or in the RStudio Viewer pane.

### Using the Application

#### Step 1: Microbial Concentration (Q1)
- Choose to use default APC values (mean: 3.52, SD: 0.70 log₁₀ CFU/mL) or provide custom data
- **Manual entry**: Enter mean and SD directly
- **CSV upload**: Upload a CSV of raw APC measurements (auto-fits normal distribution; raw CFU/mL values are automatically log₁₀-transformed)

#### Step 2: Temperature Data & Scenarios (Q2)
- Indicate whether you have temperature data for any supply chain stages
- **If Yes**: Select stages and upload CSV files with time-temperature profiles
- **If No**: Baseline temperature profiles are used
- **Disruption Scenarios** (optional): Select from two independent dropdowns:
  - Facility Storage: S1 (Storage Cooling System Disruption) or S2 (Delivery Delay)
  - Delivery: S3 (Temp Increase from Trunk Opening) or S4 (Delivery Cooling System Disruption)
  - Scenarios can be combined (one from each dropdown)
  - Scenarios override baseline and user data for their respective stage

#### Step 3: Data Input & Prediction
- Set **containers per lot** (default: 1000 half-gallon containers) for economic/environmental analysis
- Review the summary table showing all input parameters
- Click **"Predict"** to run the Monte Carlo simulation

#### Results
- **Pre-Consumer Spoilage**: % of containers spoiled before consumer purchase (end of retail)
- **Consumer Shelf Life**: Days of consumer storage until 25% of containers are spoiled
- **Economic Loss** (when scenario active): Dollar loss from reduced shelf life vs baseline ($0.03/unit/day)
- **Environmental Emission** (when scenario active): Delta CO₂e from additional waste (retail→landfill, consumer→wastewater)
- **Spoilage Plot**: Median spoiled % over days 7-35 with P25-P75 ribbon
- **Spoilage Statistics Table**: Detailed statistics at each time point

### CSV File Format

Time-temperature profile CSV files should have two columns: `time` and `temperature`.

```csv
time,temperature
2024-01-15 08:00:00,4.2
2024-01-15 10:00:00,4.5
2024-01-15 12:00:00,4.8
2024-01-15 14:00:00,4.3
```

Supported time formats: `YYYY-MM-DD HH:MM:SS`, `MM/DD/YYYY HH:MM:SS`, `MM/DD/YYYY HH:MM`, numeric days.

APC CSV files should have one column of APC values (CFU/mL or log₁₀ CFU/mL). Column name should be `apc`, `cfu`, or `count`.

## Project Structure

```
PPI_Digital-Interface/
├── App.R                          # Main Shiny application (UI + server)
├── config/
│   └── default_parameters.R      # Default parameters, baseline/scenario paths
├── css/
│   └── styles.css                # Cornell red theme styling
├── model/
│   └── run_model.R               # Model execution function
├── utils/
│   ├── helpers.R                 # Data processing utilities
│   └── model_helpers.R           # Growth model functions
├── input_data/
│   ├── ModelData_BCLc_input.csv  # Pre-generated BCLc container data
│   ├── ModelData_D_input.csv     # Pre-generated D container data
│   ├── baseline_*.csv            # Baseline temperature profiles (4 stages)
│   ├── scenario_s*.csv           # Disruption scenario profiles (S1-S4)
│   └── baseline_result.rds       # Precomputed baseline model results
├── scripts/
│   └── precompute_baseline.R     # Script to regenerate baseline_result.rds
├── test_data/
│   ├── test_backend.R            # Backend integration tests (7 tests)
│   ├── test_comparison.R         # Scenario vs baseline comparison tests
│   └── *.csv                     # Mock test data files
├── docs/
│   ├── development.md            # Development log
│   ├── kanban.md                 # Feature tracking
│   └── adr/                      # Architecture Decision Records
└── README.md
```

## Model Methodology

The model uses a two-dimensional Monte Carlo simulation approach:

1. **Microbial Community Modeling**: Incorporates metagenomic-informed community composition with taxon-specific characteristics
2. **Heat Resistance**: Models survival during HTST pasteurization for different bacterial taxa (spore-formers, thermodurics, heat-sensitive)
3. **Growth Modeling**: Uses temperature-dependent growth models:
   - **BCLc pathway** (medium-growth bacteria): Buchanan model without lag phase, using mean stage temperatures
   - **D pathway** (high-growth bacteria): Dynamic ODE solver (Baranyi model) with reduced Ratkowsky temperature dependence, using hourly temperature profiles
   - **A pathway** (no growth): Concentration remains at initial level
4. **Spoilage Threshold**: Milk is considered spoiled when total bacterial concentration exceeds 6 log₁₀ CFU/mL (1,000,000 CFU/mL)
5. **Statistical Analysis**: Calculates spoilage statistics across multiple lots and containers at days 7, 14, 21, 28, and 35

### Economic Analysis

When a disruption scenario is active, the economic impact is computed as:

```
economic_loss = (baseline_shelf_life - scenario_shelf_life) × $0.03/unit × containers_per_lot
```

The $0.03/unit/day value is from Lau et al. (2023), estimating the added value of one additional day of fluid milk shelf life.

### Environmental Analysis

CO₂e emissions are computed using EPA WARM model factors, differentiated by disposal pathway:
- **Retail waste → landfill**: 0.55 kg CO₂e per liter
- **Consumer waste → wastewater**: 0.2 kg CO₂e per liter

Spoilage is evaluated at the baseline's consumer shelf-life day using per-container spoil times, ensuring consistent comparison regardless of pre-consumer stage durations.

### Baseline Precomputation

Baseline model results are precomputed and stored in `input_data/baseline_result.rds` for fast app startup. To regenerate after changing default parameters or input data:

```r
Rscript scripts/precompute_baseline.R
```

## Developers

This web application is developed by researchers from the [Milk Quality Improvement Lab (MQIP)](https://cals.cornell.edu/food-safety-laboratory) in the Department of Food Science at Cornell University. The lab aims to leverage digital tools to facilitate management decision-making in reducing spoilage of dairy products and evaluating intervention strategies.

**Contact Information:**
- **Luke Qian** - Postdoctoral Associate (cq87@cornell.edu)
- **Leonie Kemmerling** - Ph.D. Student (lk483@cornell.edu)
- **Martin Wiedmann** - Gellert Family Professor in Food Safety (mw16@cornell.edu)

**Resources:**
- [Lab Website](https://cals.cornell.edu/food-safety-laboratory)
- [Digital Dairy Central Hub](https://cals.cornell.edu/digital-dairy)

## Funding

The funding of this work is supported by a grant to Rochester Institute of Technology's NYS Pollution Prevention Institute from the Environmental Protection Fund as administered by the NYS Department of Environmental Conservation.

## Disclaimer

The models for predicting dairy spoilage (the 'Models') are provided 'as is' at no cost to the users. The predicted values provided by the Models are only estimations and not actual values obtained in a real milk supply chain. Actual values will differ from the Models predictions due to variations such as milk type, microbial load, pressure and other factors not covered by the Models. By using the Models the user is accepting economic and all other risks associated with it and remain responsible for compliance with all regulatory, food safety and other requirements related to their activities.

**CORNELL UNIVERSITY EXPRESSLY DISCLAIMS ANY AND ALL WARRANTIES IN CONNECTION WITH THE MODEL, INCLUDING BUT NOT LIMITED TO WARRANTIES OF FITNESS FOR A PARTICULAR PURPOSE, WARRANTIES OF MERCHANTABILITY, AND WARRANTIES OF NON-INFRINGEMENT.**

By using the Models you acknowledge and agree to the foregoing and waive any and all claims of any kind and description against Cornell University, its officers, employees and agents, in connection with your use of the Model and any decisions you may make as a result of using the Model.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contact

For questions, issues, or contributions, please:
- Open an issue on the GitHub repository
- Contact the development team directly (see Developers section above)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
