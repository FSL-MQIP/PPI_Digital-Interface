library(shiny)
library(shinydashboard)
library(tidyverse)      # Data manipulation: filter, mutate, select, group_by, left_join, etc.
library(fitdistrplus)   # Fit probability distributions to data
library(rmutil)         # Laplace distribution functions
library(truncnorm)      # Truncated normal distribution functions
library(EnvStats)       # Environmental statistics: truncated normal and triangular distributions
library(MCMCpack)       # Dirichlet distribution for sampling relative abundances
library(furrr)          # Parallel processing with future_map() and plan()
library(deSolve)        # Ordinary differential equation solver (used by predict_dynamic_growth)

# Source default parameters configuration
source("config/default_parameters.R")

# Source utility functions
source("utils/helpers.R")

# Source model helper functions
source("utils/model_helpers.R")

# Source model execution function
source("model/run_model.R")

# Configure parallel processing for model
# Adaptive configuration: use sequential processing on shinyapps.io to avoid resource limits
# shinyapps.io has limited resources and multisession plans can cause startup failures
if (Sys.getenv("SHINY_PORT") != "") {
  # Running on shinyapps.io - use sequential processing (safest option)
  plan(sequential)
} else {
  # Running locally - use parallel processing with available cores
  available_cores <- parallel::detectCores()
  workers <- min(4, max(1, available_cores - 1))  # Use at most 4 workers, leave 1 core free
  plan(multisession, workers = workers)
}

# Load input data
ModelData_BCLc_input <- read_csv("input_data/ModelData_BCLc_input.csv", show_col_types = FALSE)
ModelData_D_input <- read_csv("input_data/ModelData_D_input.csv", show_col_types = FALSE)

# Source input data processing functions (when available)
# source("input_data/data_processing.R")

# Define the UI
ui <- dashboardPage(
  skin = "blue",
  dashboardHeader(
    title = tags$span(style = "font-size: 18px;", "Milk Shelf-life Predictor")
  ),
  
  dashboardSidebar(
    sidebarMenu(
      menuItem("Intro", tabName = "intro", icon = icon("info-circle")),
      menuItem("Model", tabName = "model", icon = icon("calculator"))
    )
  ),
  
  dashboardBody(
    tags$head(
      # Include custom CSS
      includeCSS("css/styles.css")
    ),
    tabItems(
      # Intro Tab
      tabItem(
        tabName = "intro",
        h2("Model Overview"),
        box(
          width = 12,
          h3("Model Overview"),
          p("This model is a two-dimensional Monte Carlo simulation that predicts spoilage of HTST-pasteurized milk by explicitly modeling survival during pasteurization and subsequent growth of the bulk tank raw milk (BTRM) bacterial community across the supply chain. It integrates metagenomic-informed community composition, taxon-specific heat resistance (including spore-formers, thermodurics, and heat-sensitive taxa), and temperature-dependent growth to estimate lot-level spoilage risk over shelf life."),
          br(),
          h3("Developers"),
          p("This web app is developed by researchers from ", 
            tags$a(href = "https://cals.cornell.edu/food-safety-laboratory", target = "_blank", "Milk Quality Improvement Lab (MQIP)"), 
            " in the department of food science at Cornell University. Our lab aims to leverage digital tools to facilitate management decision-making in reducing spoilage of dairy products and evaluating intervention strategies. For more information about what we do, please visit our ", 
            tags$a(href = "https://cals.cornell.edu/food-safety-laboratory", target = "_blank", "lab website"), 
            " and ", 
            tags$a(href = "https://cals.cornell.edu/digital-dairy", target = "_blank", "digital dairy central hub"), 
            "."),
          br(),
          h3("Funding"),
          p("The funding of this work is supported by a grant to Rochester Institute of Technology's NYS Pollution Prevention Institute from the Environmental Protection Fund as administered by the NYS Department of Environmental Conservation."),
          br(),
          h3("Disclaimers"),
          p("The models for predicting dairy spoilage (the 'Models') are provided 'as is' at no cost to the users. The predicted values provided by the Models are only estimations and not actual values obtained in a real milk supply chain. Actual values will differ from the Models predictions due to variations such as milk type, microbial load, pressure and other factors not covered by the Models. By using the Models the user is accepting economic and all other risks associated with it and remain responsible for compliance with all regulatory, food safety and other requirements related to their activities."),
          br(),
          p(tags$strong("CORNELL UNIVERSITY EXPRESSLY DISCLAIMS ANY AND ALL WARRANTIES IN CONNECTION WITH THE MODEL, INCLUDING BUT NOT LIMITED TO WARRANTIES OF FITNESS FOR A PARTICULAR PURPOSE, WARRANTIES OF MERCHANTABILITY, AND WARRANTIES OF NON-INFRINGEMENT.")),
          br(),
          p("By using the Models you acknowledge and agree to the foregoing and waive any and all claims of any kind and description against Cornell University, its officers, employees and agents, in connection with your use of the Model and any decisions you may make as a result of using the Model."),
          br(),
          h3("Contacts"),
          p(tags$strong("Luke Qian"), " - Postdoctoral Associate. Email: ", tags$a(href = "mailto:cq87@cornell.edu", "cq87@cornell.edu")),
          p(tags$strong("Leonie Kemmerling"), " - Ph.D. Student. Email: ", tags$a(href = "mailto:lk483@cornell.edu", "lk483@cornell.edu")),
          p(tags$strong("Martin Wiedmann"), " - Gellert Family Professor in Food Safety. Email: ", tags$a(href = "mailto:mw16@cornell.edu", "mw16@cornell.edu"))
        )
      ),
      
      # Model Tab
      tabItem(
        tabName = "model",
        fluidRow(
          sidebarPanel(
            width = 4,
            h3("Preliminary Questions"),
            
            # Question 1: Microbial concentration in raw milk
            # COMMENTED OUT - Using default values for now
            # h4("Question 1: Microbial Concentration"),
            # radioButtons(
            #   inputId = "has_microbial_data",
            #   label = "Do you have APC (Aerobic Plate Count) data in bulk tank raw milk?",
            #   choices = list("Yes" = "yes", "No" = "no"),
            #   selected = character(0)
            # ),
            # 
            # # If yes, show mean and SD inputs
            # conditionalPanel(
            #   condition = "input.has_microbial_data == 'yes'",
            #   fluidRow(
            #     column(6, numericInput(
            #       inputId = "mean_microbial",
            #       label = "Mean:",
            #       value = NULL
            #     )),
            #     column(6, numericInput(
            #       inputId = "sd_microbial",
            #       label = "Standard Deviation:",
            #       value = NULL
            #     ))
            #   )
            # ),
            # 
            # # If no, show default message
            # conditionalPanel(
            #   condition = "input.has_microbial_data == 'no'",
            #   p(em("Using default values")),
            #   br()
            # ),
            
            # Question 2: Temperature data on supply chain stages
            uiOutput("question2_ui")
          ),
          
          mainPanel(
            width = 8,
            uiOutput("prediction_section")
          )
        )
      )
    )
  )
)

# Define the server
server <- function(input, output, session) {
  
  # Reactive value to track if Question 2 is completed
  q2_completed <- reactiveVal(FALSE)
  
  # Reactive values to store temperature and time statistics for each stage
  stage_stats <- reactiveValues(
    processing_facility = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL),
    transportation_facility_to_retail = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL),
    retail = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL),
    transportation_retail_to_home = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL),
    consumer = list(temp_mean = NULL, temp_sd = NULL, time_mean = NULL, time_sd = NULL)
  )
  
  # Reactive value to track if model is running
  model_running <- reactiveVal(FALSE)
  
  # Reactive value to store model results
  spoil_stats_result <- reactiveVal(NULL)
  
  # Reactive expression to check if Question 1 is completed
  # COMMENTED OUT - Using default microbial concentration values
  # q1_completed <- reactive({
  #   if (is.null(input$has_microbial_data) || input$has_microbial_data == "") {
  #     return(FALSE)
  #   }
  #   if (input$has_microbial_data == "yes") {
  #     # If yes, need both mean and sd
  #     if (is.null(input$mean_microbial) || is.na(input$mean_microbial) || 
  #         is.null(input$sd_microbial) || is.na(input$sd_microbial)) {
  #       return(FALSE)
  #     }
  #   }
  #   return(TRUE)
  # })
  
  # Render Question 2 UI
  output$question2_ui <- renderUI({
    # COMMENTED OUT - No longer depends on Question 1
    # if (!q1_completed()) {
    #   return(NULL)
    # }
    
    tagList(
      br(),
      hr(),
      h4("Temperature Data"),
      radioButtons(
        inputId = "has_temperature_data",
        label = "Do you have temperature data on any of the supply chain stages (e.g., processing facility, retail)?",
        choices = list("Yes" = "yes", "No" = "no"),
        selected = character(0)
      ),
      
      # If yes, show checkboxes for supply chain stages
      conditionalPanel(
        condition = "input.has_temperature_data == 'yes'",
        checkboxGroupInput(
          inputId = "selected_stages",
          label = "Select the supply chain stages you have data for:",
          choices = c(
            "Processing Facility" = "processing_facility",
            "Transportation from facility to retail" = "transportation_facility_to_retail",
            "Retail" = "retail",
            "Transportation from retail to home" = "transportation_retail_to_home",
            "Consumer" = "consumer"
          )
        ),
        p(em("For stages not selected, default data will be used")),
        br()
      ),
      
      # If no, show default message
      conditionalPanel(
        condition = "input.has_temperature_data == 'no'",
        p(em("Using default temperature data")),
        br()
      ),
      
      # Navigation buttons for Question 2
      conditionalPanel(
        condition = "input.has_temperature_data != ''",
        br(),
        actionButton("back_q1", "Back", class = "btn-default"),
        actionButton("next_q2", "Continue", class = "btn-primary")
      )
    )
  })
  
  # Render prediction section
  output$prediction_section <- renderUI({
    if (!q2_completed()) {
      return(NULL)
    }
    
    tagList(
      h4("Supply Chain Data Input"),
      uiOutput("stage_panels"),
      actionButton("submit", "Predict", class = "btn-primary"),
      h4("Summary"),
      tableOutput("summary_table"),
      br(),
      h4("Spoilage Statistics"),
      uiOutput("spoil_stats_ui")
    )
  })
  
  # Handle navigation buttons
  observeEvent(input$back_q1, {
    # Reset Question 2 only - go back one level
    q2_completed(FALSE)
    updateRadioButtons(session, "has_temperature_data", selected = character(0))
    updateCheckboxGroupInput(session, "selected_stages", selected = character(0))
    # Keep Question 1 answers intact - don't reset them
  })
  
  observeEvent(input$next_q2, {
    # Validate Question 2 before proceeding
    if (is.null(input$has_temperature_data) || input$has_temperature_data == "") {
      showModal(modalDialog(
        title = "Validation Error",
        "Please answer Question 2 first.",
        easyClose = TRUE
      ))
      return()
    }
    
    if (input$has_temperature_data == "yes") {
      if (is.null(input$selected_stages) || length(input$selected_stages) == 0) {
        showModal(modalDialog(
          title = "Validation Error",
          "Please select at least one supply chain stage.",
          easyClose = TRUE
        ))
        return()
      }
    }
    q2_completed(TRUE)
  })
  
  # Observe file uploads and extract statistics for each stage
  observeEvent(input$csv_file_processing_facility, {
    if (!is.null(input$csv_file_processing_facility)) {
      file_stats <- process_csv_file(input$csv_file_processing_facility)
      stage_stats$processing_facility$temp_mean <- file_stats$temperature$mean
      stage_stats$processing_facility$temp_sd <- file_stats$temperature$sd
      stage_stats$processing_facility$time_mean <- file_stats$time$mean
      stage_stats$processing_facility$time_sd <- file_stats$time$sd
    }
  })
  
  observeEvent(input$csv_file_transportation_facility_to_retail, {
    if (!is.null(input$csv_file_transportation_facility_to_retail)) {
      file_stats <- process_csv_file(input$csv_file_transportation_facility_to_retail)
      stage_stats$transportation_facility_to_retail$temp_mean <- file_stats$temperature$mean
      stage_stats$transportation_facility_to_retail$temp_sd <- file_stats$temperature$sd
      stage_stats$transportation_facility_to_retail$time_mean <- file_stats$time$mean
      stage_stats$transportation_facility_to_retail$time_sd <- file_stats$time$sd
    }
  })
  
  observeEvent(input$csv_file_retail, {
    if (!is.null(input$csv_file_retail)) {
      file_stats <- process_csv_file(input$csv_file_retail)
      stage_stats$retail$temp_mean <- file_stats$temperature$mean
      stage_stats$retail$temp_sd <- file_stats$temperature$sd
      stage_stats$retail$time_mean <- file_stats$time$mean
      stage_stats$retail$time_sd <- file_stats$time$sd
    }
  })
  
  observeEvent(input$csv_file_transportation_retail_to_home, {
    if (!is.null(input$csv_file_transportation_retail_to_home)) {
      file_stats <- process_csv_file(input$csv_file_transportation_retail_to_home)
      stage_stats$transportation_retail_to_home$temp_mean <- file_stats$temperature$mean
      stage_stats$transportation_retail_to_home$temp_sd <- file_stats$temperature$sd
      stage_stats$transportation_retail_to_home$time_mean <- file_stats$time$mean
      stage_stats$transportation_retail_to_home$time_sd <- file_stats$time$sd
    }
  })
  
  observeEvent(input$csv_file_consumer, {
    if (!is.null(input$csv_file_consumer)) {
      file_stats <- process_csv_file(input$csv_file_consumer)
      stage_stats$consumer$temp_mean <- file_stats$temperature$mean
      stage_stats$consumer$temp_sd <- file_stats$temperature$sd
      stage_stats$consumer$time_mean <- file_stats$time$mean
      stage_stats$consumer$time_sd <- file_stats$time$sd
    }
  })
  
  # Dynamically generate panels for each selected stage
  output$stage_panels <- renderUI({
    # Show panels only if user has temperature data and selected stages, or if they don't have data (use defaults)
    if (!is.null(input$has_temperature_data) && input$has_temperature_data == "yes" && !is.null(input$selected_stages) && length(input$selected_stages) > 0) {
      lapply(input$selected_stages, function(stage) {
        stage_label <- get_stage_label(stage)
        
        wellPanel(
          h4(stage_label),
          
          fileInput(
            inputId = paste0("csv_file_", stage),
            label = tagList(
              paste("Upload the time-temperature profile for", stage_label, "(CSV file):"),
              tags$span(
                icon("info-circle", style = "margin-left: 5px; color: #B31B1B; cursor: help;"),
                title = "Required format: CSV file with two columns only - 'time' and 'temperature'. Recommended time format: YYYY-MM-DD HH:MM:SS (e.g., 2024-01-15 10:30:00) or numeric days. Other date formats are also supported."
              )
            ),
            accept = ".csv"
          )
        )
      })
    } else if (!is.null(input$has_temperature_data) && input$has_temperature_data == "no") {
      # Show message that default data will be used
      wellPanel(
        h4("Using Default Temperature Data"),
        p("Default temperature data will be used for all supply chain stages.")
      )
    }
  })
  
  # Summarize the input data
  output$summary_table <- renderTable({
    # Show summary based on what data is available
    summary_rows <- list()
    
    # Add microbial concentration data summary
    # COMMENTED OUT - Using default values for now
    # if (input$has_microbial_data == "yes") {
    #   summary_rows[[length(summary_rows) + 1]] <- data.frame(
    #     `Supply Chain Stage` = "Bulk tank",
    #     `Data Type` = "Microbial Concentration",
    #     Source = "User Input",
    #     Mean = input$mean_microbial,
    #     SD = input$sd_microbial,
    #     Unit = "log10CFU/mL",
    #     stringsAsFactors = FALSE,
    #     check.names = FALSE
    #   )
    # } else {
    #   summary_rows[[length(summary_rows) + 1]] <- data.frame(
    #     `Supply Chain Stage` = "Bulk tank",
    #     `Data Type` = "Microbial Concentration",
    #     Source = "Default",
    #     Mean = default_microbial$mean,
    #     SD = default_microbial$sd,
    #     Unit = "log10CFU/mL",
    #     stringsAsFactors = FALSE,
    #     check.names = FALSE
    #   )
    # }
    
    # Always use default microbial concentration
    summary_rows[[length(summary_rows) + 1]] <- data.frame(
      `Supply Chain Stage` = "Bulk tank",
      `Data Type` = "Microbial Concentration",
      Source = "Default",
      Mean = default_microbial$mean,
      SD = default_microbial$sd,
      Unit = "log10CFU/mL",
      stringsAsFactors = FALSE,
      check.names = FALSE
    )
    
    # Add temperature and time data summary - show all stages individually
    all_stages <- get_all_stages()
    
    if (!is.null(input$has_temperature_data) && input$has_temperature_data == "yes" && !is.null(input$selected_stages) && length(input$selected_stages) > 0) {
      # User has temperature data - show selected stages with their data, and non-selected with defaults
      for (stage in all_stages) {
        stage_label <- get_stage_label(stage)
        if (stage %in% input$selected_stages) {
          # Stage was selected - check if file was uploaded
          file <- input[[paste0("csv_file_", stage)]]
          source <- ifelse(!is.null(file), "User Upload", "Default")
          
          # Extract temperature and time data from uploaded CSV file
          temp_mean <- "N/A"
          temp_sd <- "N/A"
          time_mean <- "N/A"
          time_sd <- "N/A"
          
          # Process uploaded CSV file
          if (!is.null(file)) {
            file_stats <- process_csv_file(file)
            temp_mean <- file_stats$temperature$mean
            temp_sd <- file_stats$temperature$sd
            time_mean <- file_stats$time$mean
            time_sd <- file_stats$time$sd
          }
          
          # If no file uploaded but stage was selected, use defaults
          if (source == "Default") {
            temp_params <- get_default_params(stage, "temperature")
            temp_mean <- temp_params$mean
            temp_sd <- temp_params$sd
            time_params <- get_default_params(stage, "time")
            time_mean <- time_params$mean
            time_sd <- time_params$sd
          }
        } else {
          # Stage was not selected - use default parameters
          source <- "Default"
          temp_params <- get_default_params(stage, "temperature")
          temp_mean <- temp_params$mean
          temp_sd <- temp_params$sd
          time_params <- get_default_params(stage, "time")
          time_mean <- time_params$mean
          time_sd <- time_params$sd
        }
        
        # Add Temperature row
        summary_rows[[length(summary_rows) + 1]] <- create_summary_row(
          stage_label, "Temperature", source, temp_mean, temp_sd, "degree C"
        )
        
        # Add Time row
        summary_rows[[length(summary_rows) + 1]] <- create_summary_row(
          stage_label, "Time", source, time_mean, time_sd, "day"
        )
      }
    } else if (!is.null(input$has_temperature_data) && input$has_temperature_data == "no") {
      # User doesn't have temperature data - show all stages with default parameters
      for (stage in all_stages) {
        stage_label <- get_stage_label(stage)
        
        # Get default parameters
        temp_params <- get_default_params(stage, "temperature")
        time_params <- get_default_params(stage, "time")
        
        # Add Temperature row
        summary_rows[[length(summary_rows) + 1]] <- create_summary_row(
          stage_label, "Temperature", "Default", temp_params$mean, temp_params$sd, "degree C"
        )
        
        # Add Time row
        summary_rows[[length(summary_rows) + 1]] <- create_summary_row(
          stage_label, "Time", "Default", time_params$mean, time_params$sd, "day"
        )
      }
    }
    
    if (length(summary_rows) == 0) {
      return(data.frame(Message = "No data entered yet."))
    }
    
    do.call(rbind, summary_rows)
  })
  
  # Output to track if model is running (for conditionalPanel)
  output$model_running <- reactive({
    model_running()
  })
  outputOptions(output, "model_running", suspendWhenHidden = FALSE)
  
  # Render spoilage statistics UI with loading indicator
  output$spoil_stats_ui <- renderUI({
    if (model_running()) {
      return(
        div(
          style = "text-align: center; padding: 20px;",
          tags$div(
            class = "spinner-border spinner-border-lg",
            role = "status",
            style = "color: #541E1B;",
            tags$span(class = "sr-only", "Loading...")
          ),
          br(),
          br(),
          tags$p("Running model... This may take a few moments.", style = "color: #666;")
        )
      )
    } else if (!is.null(spoil_stats_result())) {
      return(tableOutput("spoil_stats_table"))
    } else {
      return(
        tags$p("Click 'Predict' to run the model and view spoilage statistics.", 
               style = "color: #666; font-style: italic;")
      )
    }
  })
  
  # Observe the submit button and run the model
  observeEvent(input$submit, {
    # Validate that preliminary questions are answered
    if (is.null(input$has_temperature_data) || input$has_temperature_data == "") {
      showModal(modalDialog(
        title = "Error",
        "Please complete Question 2 first.",
        easyClose = TRUE
      ))
      return()
    }
    
    if (input$has_temperature_data == "yes" && (is.null(input$selected_stages) || length(input$selected_stages) == 0)) {
      showModal(modalDialog(
        title = "Error",
        "Please select at least one supply chain stage.",
        easyClose = TRUE
      ))
      return()
    }
    
    # Set model as running
    model_running(TRUE)
    spoil_stats_result(NULL)
    
    # Get selected stages (stages with user-submitted data)
    selected_stages <- NULL
    if (input$has_temperature_data == "yes" && !is.null(input$selected_stages) && length(input$selected_stages) > 0) {
      selected_stages <- input$selected_stages
    }

    # Run the model with progress tracking
    tryCatch({
      withProgress(
        message = "Running spoilage model",
        value = 0,
        {
          # Create progress callback function
          progress_callback <- function(message, value) {
            setProgress(value = value, detail = message)
          }

          # Run the model (sampling logic is now inside the function)
          # t_H (total shelf-life horizon) defaults to 35 inside run_spoilage_model
          result <- run_spoilage_model(
            ModelData_BCLc_input = ModelData_BCLc_input,
            ModelData_D_input = ModelData_D_input,
            stage_stats = stage_stats,
            selected_stages = selected_stages,
            progress_callback = progress_callback
          )
          
          # Store results
          spoil_stats_result(result)
          model_running(FALSE)
        }
      )
    }, error = function(e) {
      model_running(FALSE)
      showModal(modalDialog(
        title = "Model Error",
        paste("An error occurred while running the model:", e$message),
        easyClose = TRUE
      ))
    })
  })
  
  # Render spoilage statistics table
  output$spoil_stats_table <- renderTable({
    if (is.null(spoil_stats_result())) {
      return(NULL)
    }
    
    # Format the table nicely
    result <- spoil_stats_result()
    
    # Convert proportions to percentages for better readability
    result_formatted <- data.frame(
      Day = result$Day,
      `Median (%)` = round(result$Median_Proportion * 100, 2),
      `Mean (%)` = round(result$Mean_Proportion * 100, 2),
      `SD (%)` = round(result$SD_proportion * 100, 2),
      `5th Percentile (%)` = round(result$p05 * 100, 2),
      `25th Percentile (%)` = round(result$p25 * 100, 2),
      `75th Percentile (%)` = round(result$p75 * 100, 2),
      `95th Percentile (%)` = round(result$p95 * 100, 2),
      `Median Bacterial Concentration (log10 QBU/mL)` = round(result$Median_Bacterial_Concentration, 2),
      `25th Percentile Bacterial Concentration (log10 QBU/mL)` = round(result$p25_Bacterial_Concentration, 2),
      `75th Percentile Bacterial Concentration (log10 QBU/mL)` = round(result$p75_Bacterial_Concentration, 2),
      stringsAsFactors = FALSE,
      check.names = FALSE
    )
    
    result_formatted
  }, digits = 2)
}

# Run the app
shinyApp(ui = ui, server = server)
