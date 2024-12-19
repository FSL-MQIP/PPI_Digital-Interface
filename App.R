library(shiny)

# Define the UI
ui <- fluidPage(
  titlePanel("Supply Chain Data Input"),
  
  sidebarLayout(
    sidebarPanel(
      h3("Preliminary Questions"),
      
      # Frequency of PPC
      numericInput(
        inputId = "frequency_ppc",
        label = tagList("1. Enter the frequency of PPC:", icon("info-circle", title = "PPC frequency means the frequency of post-pasteurization contamination that occurs in the processing plants, and the value is expressed in percentage.")),
        value = NULL,
        min = 0
      ),
      
      # Mean and SD for cold-tolerant sporeformer
      conditionalPanel(
        condition = "input.frequency_ppc != null",
        fluidRow(
          column(6, numericInput(
            inputId = "mean_sporeformer",
            label = tagList("2. Mean (Cold-Tolerant Sporeformer):", icon("info-circle", title = "Cold-tolerant sporeformer means the MPN/mL value for psychrotolerant sporeformer measured in raw milk.")),
            value = NULL
          )),
          column(6, numericInput(
            inputId = "sd_sporeformer",
            label = "SD (Cold-Tolerant Sporeformer):",
            value = NULL
          ))
        )
      ),
      
      # Mean and SD for Gram-negative bacteria
      conditionalPanel(
        condition = "input.mean_sporeformer != null && input.sd_sporeformer != null",
        fluidRow(
          column(6, numericInput(
            inputId = "mean_gram_negative",
            label = tagList("3. Mean (Gram-Negative Bacteria):", icon("info-circle", title = "Gram-negative bacteria means the log10 CFU/mL value for Gram-negative bacteria measured in the day 0 storage at processing facility.")),
            value = NULL
          )),
          column(6, numericInput(
            inputId = "sd_gram_negative",
            label = "SD (Gram-Negative Bacteria):",
            value = NULL
          ))
        )
      )
    ),
    
    mainPanel(
      h4("Supply Chain Data Input"),
      conditionalPanel(
        condition = "input.sd_gram_negative != null",
        checkboxGroupInput(
          inputId = "selected_stages",
          label = "Choose the stages you have data for:",
          choices = c(
            "Bulk Tank Storage" = "bulk_tank_storage",
            "Farm to Facility Transportation" = "farm_to_facility_transportation",
            "Processing Facility Storage" = "processing_facility_storage",
            "Facility to Distribution Transportation" = "facility_to_distribution_transportation",
            "Distribution Center Storage" = "distribution_center_storage",
            "Distribution to Retail Transportation" = "distribution_to_retail_transportation",
            "Retail Storage" = "retail_storage",
            "Retail to Consumer Transportation" = "retail_to_consumer_transportation",
            "Consumer Storage" = "consumer_storage"
          )
        ),
        
        uiOutput("stage_panels"),
        actionButton("submit", "Submit"),
        h4("Summary"),
        tableOutput("summary_table"),
        h4("Percentage of Spoiled Milk"),
        verbatimTextOutput("spoiled_milk_output")
      )
    )
  )
)

# Define the server
server <- function(input, output, session) {
  
  # Dynamically generate panels for each selected stage
  output$stage_panels <- renderUI({
    req(input$selected_stages) # Only generate if stages are selected
    
    lapply(input$selected_stages, function(stage) {
      stage_label <- switch(
        stage,
        "bulk_tank_storage" = "Bulk Tank Storage",
        "farm_to_facility_transportation" = "Farm to Facility Transportation",
        "processing_facility_storage" = "Processing Facility Storage",
        "facility_to_distribution_transportation" = "Facility to Distribution Transportation",
        "distribution_center_storage" = "Distribution Center Storage",
        "distribution_to_retail_transportation" = "Distribution to Retail Transportation",
        "retail_storage" = "Retail Storage",
        "retail_to_consumer_transportation" = "Retail to Consumer Transportation",
        "consumer_storage" = "Consumer Storage"
      )
      
      wellPanel(
        h4(stage_label),
        
        fileInput(
          inputId = paste0("csv_file_", stage),
          label = paste("Upload the time-temperature profile for", stage_label, "(CSV file):"),
          accept = ".csv"
        ),
        
        checkboxInput(
          inputId = paste0("waste_reduction_", stage),
          label = "Is a waste reduction strategy applied?",
          value = FALSE
        )
      )
    })
  })
  
  # Summarize the input data
  output$summary_table <- renderTable({
    if (is.null(input$selected_stages)) {
      return(data.frame(Stage = "No stages selected."))
    }
    
    summary_list <- lapply(input$selected_stages, function(stage) {
      file <- input[[paste0("csv_file_", stage)]]
      waste_reduction <- ifelse(input[[paste0("waste_reduction_", stage)]], "Yes", "No")
      
      data.frame(
        Stage = switch(
          stage,
          "bulk_tank_storage" = "Bulk Tank Storage",
          "farm_to_facility_transportation" = "Farm to Facility Transportation",
          "processing_facility_storage" = "Processing Facility Storage",
          "facility_to_distribution_transportation" = "Facility to Distribution Transportation",
          "distribution_center_storage" = "Distribution Center Storage",
          "distribution_to_retail_transportation" = "Distribution to Retail Transportation",
          "retail_storage" = "Retail Storage",
          "retail_to_consumer_transportation" = "Retail to Consumer Transportation",
          "consumer_storage" = "Consumer Storage"
        ),
        FileUploaded = ifelse(!is.null(file), "Yes", "No"),
        WasteReduction = waste_reduction
      )
    })
    
    do.call(rbind, summary_list)
  })
  
  # Observe the submit button and calculate the percentage of spoiled milk
  observeEvent(input$submit, {
    if (is.null(input$selected_stages)) {
      showModal(modalDialog(
        title = "Error",
        "No stages selected.",
        easyClose = TRUE
      ))
      return()
    }
    
    # Placeholder: Calculate the percentage of spoiled milk
    percentage_spoiled <- 5 # Replace with actual calculation logic
    
    output$spoiled_milk_output <- renderPrint({
      paste("The percentage of spoiled milk is:", percentage_spoiled, "%")
    })
  })
}

# Run the app
shinyApp(ui = ui, server = server)
