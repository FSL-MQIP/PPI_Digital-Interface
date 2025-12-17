# Milk Shelf-life Predictor

A Shiny R application for predicting milk spoilage percentages based on microbial concentration and time-temperature profiles across the dairy supply chain.

## Overview

This interactive web application provides a predictive model for analyzing supply chain data related to milk spoilage. The model allows users to input microbial concentration data (APC - Aerobic Plate Count) from bulk tank raw milk and time-temperature profiles from various supply chain stages to predict the percentage of spoiled milk.

The application supports the following supply chain stages:
- **Processing Facility** - Initial milk processing
- **Transportation (Facility to Retail)** - Distribution from processing to retail
- **Retail** - Storage at retail locations
- **Transportation (Retail to Home)** - Consumer transport from store
- **Consumer** - Home storage

## Features

- **Interactive Dashboard**: User-friendly interface built with Shiny Dashboard
- **Flexible Data Input**: Accept user-provided data or use default parameters
- **CSV Upload**: Support for time-temperature profile uploads
- **Robust Date Parsing**: Handles multiple date/time formats (YYYY-MM-DD HH:MM:SS, MM/DD/YYYY, numeric days, etc.)
- **Real-time Summary**: Displays a comprehensive summary of all input parameters
- **Default Parameters**: Pre-configured default values for all supply chain stages
- **Validation**: Built-in data validation and error handling

## Installation

### Prerequisites

- R (version 4.0 or higher recommended)
- RStudio (optional, but recommended)

### Required R Packages

```r
install.packages(c("shiny", "shinydashboard"))
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
- Review the model overview and disclaimer
- Understand the purpose and limitations of the model

#### Step 2: Model Tab - Question 1 (Microbial Concentration)
- Indicate whether you have APC (Aerobic Plate Count) data from bulk tank raw milk
- **If Yes**: Enter the mean and standard deviation (in log10CFU/mL)
- **If No**: The application will use default values

#### Step 3: Question 2 (Temperature Data)
- Indicate whether you have temperature data for any supply chain stages
- **If Yes**: Select which stages you have data for
- **If No**: The application will use default temperature data for all stages

#### Step 4: Data Input
- For each selected supply chain stage, upload a CSV file with time-temperature profiles
- CSV files must contain exactly two columns: `time` and `temperature`
- **Time formats supported:**
  - YYYY-MM-DD HH:MM:SS (e.g., 2024-01-15 10:30:00)
  - MM/DD/YYYY HH:MM:SS
  - Numeric days
  - Other standard date formats

#### Step 5: Prediction
- Review the summary table showing all input parameters
- Click **"Predict"** to calculate the percentage of spoiled milk
- Results will be displayed below the summary table

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
│   └── helpers.R               # Utility functions for data processing
├── input_data/                 # Directory for input data files (optional)
├── model/                      # Directory for prediction model files (future)
├── test data.csv               # Sample test data
├── LICENSE                     # MIT License
└── README.md                   # This file
```

## Default Parameters

The application includes default parameters for all supply chain stages when user data is not provided:

### Microbial Concentration (Bulk Tank)
- Mean: 3.52 log10CFU/mL
- SD: 0.70 log10CFU/mL

### Processing Facility
- Temperature: Mean 4°C, SD 0.289°C
- Time: Mean 1.5 days, SD 0.289 days

### Transportation (Facility to Retail)
- Temperature: Mean 5.37°C, SD 1.72°C
- Time: Mean 5.33 days, SD 1.84 days

### Retail
- Temperature: Mean 2.3°C, SD 1.8°C
- Time: Mean 1.821 days, SD 3.3 days

### Transportation (Retail to Home)
- Temperature: Mean 8.5°C, SD 1.0°C
- Time: Mean 0.04 days, SD 0.02 days

### Consumer
- Temperature: Mean 4.06°C, SD 2.31°C
- Time: Mean 28 days, SD 0 days

## Development Status

⚠️ **Note**: The prediction model calculation is currently a placeholder. The actual predictive algorithm is under development and will be integrated in future versions.

## Disclaimer

This model is provided for informational purposes only. The predictions generated by this model are estimates based on the input data provided and should not be used as the sole basis for decision-making. Users are responsible for verifying the accuracy of their input data and interpreting the results appropriately.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Author

Copyright (c) 2024 chenhaoq87

## Contact

For questions, issues, or contributions, please open an issue on the GitHub repository.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Future Enhancements

- [ ] Integration of full predictive model algorithm
- [ ] Export functionality for results
- [ ] Visualization of time-temperature profiles
- [ ] Batch processing capabilities
- [ ] Advanced statistical analysis options
- [ ] Report generation

## Troubleshooting

### Common Issues

**Issue**: CSV file upload fails
- **Solution**: Ensure your CSV file has exactly two columns named `time` and `temperature`

**Issue**: Date parsing errors
- **Solution**: Use recommended format YYYY-MM-DD HH:MM:SS or numeric days

**Issue**: Application doesn't start
- **Solution**: Verify all required packages are installed:
  ```r
  install.packages(c("shiny", "shinydashboard"))
  ```

## Technical Details

- **Framework**: Shiny R
- **UI Framework**: shinydashboard
- **Language**: R
- **License**: MIT

