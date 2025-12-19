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

- **Interactive Dashboard**: User-friendly interface built with Shiny Dashboard
- **Monte Carlo Simulation**: Two-dimensional Monte Carlo simulation for robust spoilage prediction
- **Flexible Data Input**: Accept user-provided time-temperature profiles or use default parameters
- **CSV Upload**: Support for time-temperature profile uploads with automatic statistics extraction
- **Robust Date Parsing**: Handles multiple date/time formats (YYYY-MM-DD HH:MM:SS, MM/DD/YYYY, numeric days, etc.)
- **Real-time Summary**: Displays a comprehensive summary of all input parameters
- **Default Parameters**: Pre-configured default values for all supply chain stages based on empirical data
- **Parallel Processing**: Utilizes 16 parallel workers for efficient model execution
- **Progress Tracking**: Real-time progress indicators during model execution
- **Statistical Output**: Provides median, mean, standard deviation, and percentiles (5th, 25th, 75th, 95th) for spoilage predictions
- **Multi-day Predictions**: Predicts spoilage percentages at days 7, 14, 21, 28, and 35

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
   git clone https://github.com/chenhaoq87/PPI_Digital-Interface.git
   cd PPI_Digital-Interface
   ```

2. **Open R or RStudio and run:**
   ```r
   shiny::runApp()
   ```
   
   Or directly run the app file:
   ```r
   source("App.R")
   ```

3. **Access the application:**
   The app will open in your default web browser or in the RStudio Viewer pane.

### Using the Application

#### Step 1: Intro Tab
- Review the model overview, developer information, funding details, and disclaimers
- Understand the purpose and limitations of the model
- Access contact information for the development team

#### Step 2: Model Tab - Temperature Data
- Indicate whether you have temperature data for any supply chain stages
- **If Yes**: Select which stages you have data for
- **If No**: The application will use default temperature data for all stages
- Click **"Continue"** to proceed

#### Step 3: Data Input
- For each selected supply chain stage, upload a CSV file with time-temperature profiles
- CSV files must contain exactly two columns: `time` and `temperature`
- The application automatically extracts mean and standard deviation statistics from uploaded files
- **Time formats supported:**
  - YYYY-MM-DD HH:MM:SS (e.g., 2024-01-15 10:30:00)
  - MM/DD/YYYY HH:MM:SS (e.g., 12/17/2025 10:00:00)
  - MM/DD/YYYY HH:MM
  - Numeric days (e.g., 0, 0.5, 1.0, 1.5)
  - Other standard date formats

#### Step 4: Prediction
- Review the summary table showing all input parameters (microbial concentration, temperature, and time for each stage)
- Click **"Predict"** to run the Monte Carlo simulation
- The model will run with progress indicators (this may take a few moments)
- Results will be displayed in a table showing spoilage statistics for days 7, 14, 21, 28, and 35

**Note**: The application currently uses default microbial concentration values (mean: 3.52 log10CFU/mL, SD: 0.70 log10CFU/mL) from bulk tank raw milk. Custom microbial concentration input may be available in future versions.

### CSV File Format

Time-temperature profile CSV files should have the following format:

```csv
time,temperature
2024-01-15 08:00:00,4.2
2024-01-15 10:00:00,4.5
2024-01-15 12:00:00,4.8
2024-01-15 14:00:00,4.3
```

## Project Structure

```
PPI_Digital-Interface/
│
├── App.R                       # Main Shiny application file
├── config/
│   └── default_parameters.R    # Default parameters for all supply chain stages
├── css/
│   └── styles.css              # Custom styling for the application
├── utils/
│   ├── helpers.R               # Utility functions for data processing
│   └── model_helpers.R         # Model-related utility functions
├── input_data/                 # Directory for input data files
│   ├── ModelData_BCLc_input.csv
│   └── ModelData_D_input.csv
├── model/                      # Directory for prediction model files
│   ├── Model.R                 # Standalone model script
│   └── run_model.R             # Model execution function for Shiny app
├── LICENSE                     # MIT License
└── README.md                   # This file
```

## Default Parameters

The application includes default parameters for all supply chain stages when user data is not provided. These values are based on empirical data from the dairy supply chain:

### Microbial Concentration (Bulk Tank Raw Milk)
- Mean: 3.52 log10CFU/mL
- SD: 0.70 log10CFU/mL
- Distribution: Normal

### Processing Facility
- Temperature: Mean 4°C, SD 0.289°C (Range: 3.5-4.5°C)
- Time: Mean 1.5 days, SD 0.289 days (Range: 1-2 days)
- Distribution: Truncated normal

### Transportation (Facility to Retail)
- Temperature: Mean 5.37°C, SD 1.72°C (Range: 1.7-10.0°C, Mode: 4.4°C)
- Time: Mean 5.33 days, SD 1.84 days (Range: 1-10 days, Mode: 5 days)
- Distribution: Triangular

### Retail
- Temperature: Mean 2.3°C, SD 1.8°C (Range: -1.4 to 5.4°C)
- Time: Mean 1.821 days, SD 3.3 days (Range: 0.042 to 10.0 days)
- Distribution: Laplace

### Transportation (Retail to Home)
- Temperature: Mean 8.5°C, SD 1.0°C (Range: 0-10°C)
- Time: Mean 0.04 days, SD 0.02 days (Range: 0.01-0.24 days)
- Distribution: Uniform

### Consumer
- Temperature: Mean 4.06°C, SD 2.31°C (Range: -1 to 15°C)
- Time: Mean 28 days, SD 0 days (Fixed)
- Distribution: Truncated normal

## Model Methodology

The model uses a two-dimensional Monte Carlo simulation approach:

1. **Microbial Community Modeling**: Incorporates metagenomic-informed community composition with taxon-specific characteristics
2. **Heat Resistance**: Models survival during HTST pasteurization for different bacterial taxa (spore-formers, thermodurics, heat-sensitive)
3. **Growth Modeling**: Uses temperature-dependent growth models:
   - Buchanan model without lag phase for certain bacterial groups
   - Dynamic growth model with reduced Ratkowsky temperature dependence for others
4. **Spoilage Threshold**: Milk is considered spoiled when total bacterial concentration exceeds 6 log10 CFU/mL (1,000,000 CFU/mL)
5. **Statistical Analysis**: Calculates spoilage statistics across multiple lots and containers at days 7, 14, 21, 28, and 35

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

## Future Enhancements

- [ ] Custom microbial concentration input (currently uses defaults)
- [ ] Export functionality for results (CSV, PDF reports)
- [ ] Visualization of time-temperature profiles
- [ ] Interactive plots for spoilage predictions over time
- [ ] Batch processing capabilities for multiple scenarios
- [ ] Advanced statistical analysis options
- [ ] Sensitivity analysis tools
- [ ] Comparison of different supply chain scenarios

## Troubleshooting

### Common Issues

**Issue**: CSV file upload fails
- **Solution**: Ensure your CSV file has exactly two columns named `time` and `temperature`

**Issue**: Date parsing errors
- **Solution**: Use recommended format YYYY-MM-DD HH:MM:SS or numeric days

**Issue**: Application doesn't start
- **Solution**: Verify all required packages are installed:
  ```r
  install.packages(c(
    "shiny", "shinydashboard", "tidyverse", "fitdistrplus",
    "rmutil", "truncnorm", "EnvStats", "MCMCpack", "furrr", "deSolve"
  ))
  ```

**Issue**: Model runs slowly
- **Solution**: The model uses parallel processing with 16 workers. Ensure your system has sufficient CPU cores. You can adjust the number of workers in `App.R` (line 25) if needed.

## Technical Details

- **Framework**: Shiny R
- **UI Framework**: shinydashboard
- **Language**: R (version 4.0 or higher recommended)
- **Parallel Processing**: furrr package with 16 workers (multisession)
- **Model Version**: 2024-10-11
- **License**: MIT

### Key Dependencies

- **shiny**: Web application framework
- **shinydashboard**: Dashboard UI components
- **tidyverse**: Data manipulation and transformation
- **fitdistrplus**: Probability distribution fitting
- **rmutil**: Laplace distribution functions
- **truncnorm**: Truncated normal distribution functions
- **EnvStats**: Environmental statistics (truncated normal, triangular distributions)
- **MCMCpack**: Dirichlet distribution for sampling relative abundances
- **furrr**: Parallel processing with future_map()
- **deSolve**: Ordinary differential equation solver for dynamic growth modeling

