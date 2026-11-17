# Milk Spoilage Predictor — Shiny App
# UI on top of milk-spoilage-model/run_model.R (PPC + non-PPC pathway simulation).

library(shiny)
library(shinydashboard)
library(ggplot2)

# =============================================================================
# LOAD THE MODEL
# =============================================================================
# run_model.R sources config.R and the pathway/scenario modules with paths
# relative to milk-spoilage-model/, and reads its input CSVs the same way on
# every call (not just at source time). with_model_dir() makes that directory
# current for the duration of a block, then restores the previous one.
model_dir <- "milk-spoilage-model"

with_model_dir <- function(expr) {
  old_wd <- setwd(model_dir)
  on.exit(setwd(old_wd), add = TRUE)
  force(expr)
}

with_model_dir({
  source("run_model_20260929.R")
})

# =============================================================================
# STAGE METADATA (mirrors dairy-api/r_bridge/run_simulation.R)
# =============================================================================
stages_meta <- list(
  processing_facility = list(label = "Processing Facility"),
  transportation_facility_to_retail = list(label = "Transport: Facility → Retail"),
  retail = list(label = "Retail"),
  transportation_retail_to_home = list(label = "Transport: Retail → Home"),
  consumer = list(label = "Consumer")
)
stage_ids <- names(stages_meta)

# ClosestST values present in input_data/ppc_st_frequency.csv ("9_23" is
# already excluded from PPC sampling by pathways/ppc_pathway.R, so it is not
# offered here).
ppc_st_choices <- c("2", "6", "9", "13", "17", "23", "24", "36", "41", "48",
                     "52", "56", "75", "81", "92", "100", "102")

id_for <- function(prefix, stage) paste0(prefix, stage)

# =============================================================================
# APC CSV HELPER
# =============================================================================
# Accepts a CSV with one numeric column named 'apc', 'cfu', or 'count' (case-
# insensitive) and returns its log10 mean/SD. A bulk-tank APC in raw CFU/mL is
# always in the thousands-to-millions range, far above any plausible log10
# value, so a median above 12 is treated as un-transformed CFU/mL and log10-ed
# first; NULL if the file doesn't have a usable column.
process_apc_csv <- function(file_input) {
  if (is.null(file_input)) return(NULL)
  df <- tryCatch(read.csv(file_input$datapath), error = function(e) NULL)
  if (is.null(df) || ncol(df) == 0) return(NULL)

  match_idx <- which(tolower(names(df)) %in% c("apc", "cfu", "count"))
  if (length(match_idx) == 0) return(NULL)

  vals <- suppressWarnings(as.numeric(df[[match_idx[1]]]))
  vals <- vals[!is.na(vals) & vals > 0]
  if (length(vals) < 2) return(NULL)

  log_vals <- if (median(vals) > 12) log10(vals) else vals
  list(mean = round(mean(log_vals), 3), sd = round(sd(log_vals), 3))
}

# =============================================================================
# UI HELPERS
# =============================================================================
make_upload_ui <- function(stage, meta) {
  wellPanel(
    h5(meta$label),
    fileInput(
      id_for("override_csv_", stage),
      tagList(
        paste0("Upload measured time-temperature data for ", meta$label, ":"),
        tags$span(
          icon("circle-info", style = "margin-left: 5px; color: #B31B1B; cursor: help;"),
          title = "CSV with exactly two columns: 'time' and 'temperature'. Time can be numeric days or a timestamp (e.g. 2026-02-11 21:44:58). Replaces this stage's baseline mean/SD/duration with the uploaded data."
        )
      ),
      accept = ".csv"
    )
  )
}

# =============================================================================
# UI
# =============================================================================
ui <- dashboardPage(
  skin = "red",
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
    # Lower-right "model running" indicator. Toggled via session$sendCustomMessage()
    # (server, observeEvent(input$run_model)) rather than a reactiveVal-driven
    # renderUI: run_model() blocks R synchronously for the whole observer, and Shiny
    # only flushes reactive UI updates once that observer returns, so a renderUI
    # bound to a reactiveVal would just flash at the end instead of showing while
    # the simulation is actually running. sendCustomMessage() writes straight to the
    # websocket, the same immediate-delivery path showNotification()/withProgress()
    # use, so it appears the instant the button is clicked.
    tags$head(
      tags$style(HTML("
        #running_indicator {
          display: none;
          position: fixed;
          bottom: 20px;
          right: 20px;
          z-index: 9999;
          background: #fff;
          border: 1px solid #ddd;
          border-radius: 6px;
          box-shadow: 0 2px 10px rgba(0,0,0,0.2);
          padding: 12px 18px;
          align-items: center;
          gap: 10px;
        }
      ")),
      tags$script(HTML("
        Shiny.addCustomMessageHandler('toggle-running-indicator', function(show) {
          var el = document.getElementById('running_indicator');
          if (el) el.style.display = show ? 'flex' : 'none';
        });
      "))
    ),
    div(
      id = "running_indicator",
      tags$div(class = "spinner-border spinner-border-sm", role = "status",
               style = "color: #B31B1B;", tags$span(class = "sr-only", "Loading...")),
      tags$span("Running simulation...", style = "color: #541E1B; font-weight: 600;")
    ),

    tabItems(
      # Intro Tab
      tabItem(
        tabName = "intro",
        fluidRow(
          box(
            width = 12,
            h3("Model Overview"),
            p("This model is a Monte Carlo simulation that predicts spoilage of pasteurized milk across the supply chain, combining a taxon-specific bacterial growth model for the bulk tank raw milk community with an optional model for post-pasteurization contamination (PPC) by environmental Gram-negative bacteria introduced after pasteurization. Users can explore how PPC prevalence, processing interventions, and supply chain disruptions each affect predicted shelf life."),
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
        )
      ),

      # Model Tab
      tabItem(
        tabName = "model",
        fluidRow(
          # Left panel: inputs
          column(
            width = 5,
            box(
              width = 12,
              title = "Simulation Settings",
              status = "danger",
              solidHeader = TRUE,
              numericInput("sim_duration", "Simulation duration (days):", value = config$sim_duration, min = 7, max = 90, step = 1)
            ),

            box(
              width = 12,
              title = "Post-Pasteurization Contamination (PPC)",
              status = "danger",
              solidHeader = TRUE,
              radioButtons(
                inputId = "include_ppc",
                label = "Include post-pasteurization contamination in this simulation?",
                choices = list("No" = "no", "Yes" = "yes"),
                selected = "no"
              ),
              conditionalPanel(
                condition = "input.include_ppc == 'yes'",
                sliderInput("ppc_range", "PPC proportion of containers per lot (min - max):",
                            min = 0, max = 1, value = c(0.05, 0.2), step = 0.01),
                hr(),
                h5("Advanced PPC interventions (optional)"),
                numericInput("ppc_initial_reduction_log", "Reduce mean initial PPC level (log10 CFU/mL):",
                             value = 0, min = 0, max = 5, step = 0.1),
                selectizeInput("ppc_remove_st", "Remove PPC sequence types from sampling pool:",
                               choices = ppc_st_choices, multiple = TRUE,
                               options = list(placeholder = "none removed"))
              )
            ),

            box(
              width = 12,
              title = "Raw Milk Microbial Load (APC)",
              status = "danger",
              solidHeader = TRUE,
              radioButtons(
                inputId = "has_apc_data",
                label = "Do you have APC (Aerobic Plate Count) data for bulk tank raw milk?",
                choices = list("No" = "no", "Yes" = "yes"),
                selected = "no"
              ),
              conditionalPanel(
                condition = "input.has_apc_data == 'yes'",
                radioButtons(
                  inputId = "apc_input_method",
                  label = "How would you like to provide APC data?",
                  choices = list("Enter mean and SD" = "manual", "Upload CSV file" = "csv"),
                  selected = "manual"
                ),
                conditionalPanel(
                  condition = "input.apc_input_method == 'manual'",
                  numericInput("apc_manual_mean", "Mean (log10 CFU/mL):", value = 3.52, min = 0, max = 5, step = 0.01),
                  numericInput("apc_manual_sd", "SD (log10 CFU/mL):", value = 0.70, min = 0, max = 2, step = 0.01)
                ),
                conditionalPanel(
                  condition = "input.apc_input_method == 'csv'",
                  fileInput(
                    "apc_csv_file",
                    tagList(
                      "Upload APC measurements (CSV):",
                      tags$span(
                        icon("circle-info", style = "margin-left: 5px; color: #B31B1B; cursor: help;"),
                        title = "Required format: CSV with one column of APC values (CFU/mL or log10 CFU/mL), named 'apc', 'cfu', or 'count'. Raw CFU/mL values are automatically log10-transformed."
                      )
                    ),
                    accept = ".csv"
                  ),
                  uiOutput("apc_csv_feedback")
                )
              ),
              conditionalPanel(
                condition = "input.has_apc_data == 'no'",
                p(em("Using the model's baseline raw milk microbial load (no override)."))
              )
            ),

            box(
              width = 12,
              title = "Interventions: Spore Reduction",
              status = "danger",
              solidHeader = TRUE,
              selectInput("spore_reduction_choice", "Spore removal method (non-PPC pathways):",
                choices = c(
                  "None" = "none",
                  "Microfiltration (2.2 log)" = "microfiltration",
                  "Microfiltration, low efficiency (0.6 log)" = "microfiltration_low",
                  "Bactofugation, single (1.4 log)" = "bactofugation_single",
                  "Bactofugation, double (2.0 log)" = "bactofugation_double",
                  "Custom (enter measured value)" = "custom"
                ),
                selected = "none"
              ),
              conditionalPanel(
                condition = "input.spore_reduction_choice == 'custom'",
                numericInput("spore_reduction_custom", "Measured spore log reduction:", value = 1.0, min = 0, max = 10, step = 0.1)
              )
            ),

            box(
              width = 12,
              title = "Custom Time-Temperature Data (Optional)",
              status = "danger",
              solidHeader = TRUE,
              collapsible = TRUE,
              collapsed = TRUE,
              p(em("Upload your own measured time-temperature data for a stage instead of using its baseline profile. Leave a stage blank to keep the baseline.")),
              do.call(tagList, lapply(stage_ids, function(s) make_upload_ui(s, stages_meta[[s]])))
            ),

            div(style = "margin-bottom: 20px;",
                actionButton("run_model", "Run Simulation", class = "btn-primary btn-lg"))
          ),

          # Right panel: results
          column(
            width = 7,
            uiOutput("warnings_ui"),
            uiOutput("metric_boxes"),
            box(
              width = 12,
              title = "Predicted Spoilage Over Time",
              status = "danger",
              solidHeader = TRUE,
              uiOutput("spoilage_plot_ui")
            ),
            box(
              width = 12,
              title = "Spoilage Summary",
              status = "danger",
              solidHeader = TRUE,
              collapsible = TRUE,
              div(style = "overflow-x: auto;", uiOutput("summary_table_ui"))
            ),
            box(
              width = 12,
              title = "Applied Interventions & Disruptions",
              status = "danger",
              solidHeader = TRUE,
              collapsible = TRUE,
              collapsed = TRUE,
              uiOutput("applied_ui")
            )
          )
        )
      )
    )
  )
)

# =============================================================================
# SERVER
# =============================================================================
server <- function(input, output, session) {

  model_running <- reactiveVal(FALSE)
  spoil_result <- reactiveVal(NULL)

  # Per-container metrics: lot-level totals divided by n_units (containers per lot)
  compute_economics <- function(result) {
    sl <- result$shelf_life
    container_volume_L <- 1.893 # half-gallon

    shelf_life_value_usd <- if (is.finite(sl$consumer_days)) {
      round(sl$consumer_days * 0.03, 2)
    } else NA_real_

    retail_frac <- sl$pct_spoiled_at_retail / 100
    consumer_frac <- max(0, sl$threshold_pct / 100 - retail_frac)
    co2e_kg <- round(retail_frac * container_volume_L * 0.55 +
                      consumer_frac * container_volume_L * 0.20, 3)

    list(shelf_life_value_usd = shelf_life_value_usd, co2e_kg = co2e_kg)
  }

  observeEvent(input$run_model, {
    model_running(TRUE)
    session$sendCustomMessage("toggle-running-indicator", TRUE)
    on.exit({
      model_running(FALSE)
      session$sendCustomMessage("toggle-running-indicator", FALSE)
    })

    user_config <- config
    user_config$sim_duration <- input$sim_duration
    # Report day 42 in the Spoilage Summary as well. Set here, not in config.R,
    # so the verification baselines (built on days 7-35) are unchanged. Days
    # past sim_duration have no rows and are skipped by the summary loop.
    user_config$output_days <- sort(unique(c(config$output_days, 42)))
    if (identical(input$include_ppc, "yes")) {
      user_config$P_ppc_min <- input$ppc_range[1]
      user_config$P_ppc_max <- input$ppc_range[2]
    } else {
      user_config$P_ppc_min <- 0
      user_config$P_ppc_max <- 0
    }

    interventions <- list()
    if (identical(input$has_apc_data, "yes")) {
      apc_vals <- if (identical(input$apc_input_method, "csv")) {
        process_apc_csv(input$apc_csv_file)
      } else if (!is.null(input$apc_manual_mean) && !is.na(input$apc_manual_mean) &&
                 !is.null(input$apc_manual_sd) && !is.na(input$apc_manual_sd)) {
        list(mean = input$apc_manual_mean, sd = input$apc_manual_sd)
      } else {
        NULL
      }

      if (!is.null(apc_vals)) {
        interventions$apc_mean <- apc_vals$mean
        interventions$apc_sd <- apc_vals$sd
      } else if (identical(input$apc_input_method, "csv")) {
        showModal(modalDialog(
          title = "APC CSV Error",
          "Could not extract APC values from the uploaded CSV. Ensure it has a numeric column named 'apc', 'cfu', or 'count'.",
          easyClose = TRUE
        ))
        return()
      }
    }
    if (!identical(input$spore_reduction_choice, "none")) {
      interventions$spore_reduction <- if (identical(input$spore_reduction_choice, "custom")) {
        input$spore_reduction_custom
      } else {
        input$spore_reduction_choice
      }
    }
    if (identical(input$include_ppc, "yes")) {
      if (!is.null(input$ppc_initial_reduction_log) && !is.na(input$ppc_initial_reduction_log) &&
          input$ppc_initial_reduction_log > 0) {
        interventions$ppc_initial_reduction_log <- input$ppc_initial_reduction_log
      }
      if (!is.null(input$ppc_remove_st) && length(input$ppc_remove_st) > 0) {
        interventions$ppc_remove_st <- input$ppc_remove_st
      }
    }

    # Per-stage uploaded time-temperature profile, if provided. Reuses the
    # model's profile_csv disruption handler, which reads the CSV and derives
    # mean/sd/duration/mode itself, so no manual entry is needed.
    disruptions <- list()
    for (stage in stage_ids) {
      upload <- input[[id_for("override_csv_", stage)]]
      if (!is.null(upload)) {
        disruptions[[stage]] <- list(type = "profile_csv", path = upload$datapath,
                                      source_filename = upload$name)
      }
    }

    tryCatch({
      set.seed(42)
      result <- with_model_dir({
        run_model(user_config = user_config, interventions = interventions, disruptions = disruptions)
      })
      spoil_result(result)
    }, error = function(e) {
      showModal(modalDialog(
        title = "Model Error",
        paste("An error occurred while running the model:", e$message),
        easyClose = TRUE
      ))
    })
  })

  output$apc_csv_feedback <- renderUI({
    if (is.null(input$apc_csv_file)) return(NULL)
    result <- process_apc_csv(input$apc_csv_file)
    if (!is.null(result)) {
      p(style = "color: green;",
        paste0("Extracted: mean = ", result$mean, ", SD = ", result$sd, " (log10 CFU/mL)"))
    } else {
      p(style = "color: red;",
        "Could not extract APC values. Ensure the CSV has a numeric column named 'apc', 'cfu', or 'count'.")
    }
  })

  output$warnings_ui <- renderUI({
    res <- spoil_result()
    if (is.null(res) || length(res$warnings) == 0) return(NULL)
    box(width = 12, title = "Model Warnings", status = "warning", solidHeader = TRUE,
        tags$ul(lapply(res$warnings, tags$li)))
  })

  output$metric_boxes <- renderUI({
    if (model_running()) {
      return(div(style = "text-align: center; padding: 20px;",
                 tags$div(class = "spinner-border spinner-border-lg", role = "status",
                          style = "color: #541E1B;", tags$span(class = "sr-only", "Loading...")),
                 br(), br(),
                 tags$p("Running model... this may take a few moments.", style = "color: #666;")))
    }

    res <- spoil_result()
    if (is.null(res)) {
      return(p(em("Configure your settings on the left and click 'Run Simulation' to see results."),
               style = "color: #666;"))
    }

    sl <- res$shelf_life
    econ <- compute_economics(res)
    sim_duration <- res$scenario$config$sim_duration

    consumer_days_text <- if (is.finite(sl$consumer_days)) {
      sprintf("%.1f days", sl$consumer_days)
    } else {
      paste0("> ", round(sim_duration - sl$pre_consumer_days, 1), " days")
    }
    econ_text <- if (!is.na(econ$shelf_life_value_usd)) {
      paste0("$", format(econ$shelf_life_value_usd, nsmall = 2, big.mark = ","))
    } else "N/A"

    fluidRow(
      column(width = 6,
        box(width = 12, title = "Pre-Consumer Spoilage", status = "danger", solidHeader = TRUE,
            h3(sprintf("%.1f%%", sl$pct_spoiled_at_retail), style = "text-align: center; margin: 10px 0;"),
            p("Containers spoiled before consumer purchase", style = "text-align: center; color: #777;"))),
      column(width = 6,
        box(width = 12, title = "Consumer Shelf Life", status = "danger", solidHeader = TRUE,
            h3(consumer_days_text, style = "text-align: center; margin: 10px 0;"),
            p(sprintf("Days to %.0f%% lot spoilage", sl$threshold_pct), style = "text-align: center; color: #777;"))),
      column(width = 6,
        box(width = 12, title = "Economic Value", status = "danger", solidHeader = TRUE,
            h3(econ_text, style = "text-align: center; margin: 10px 0;"),
            p("Shelf-life value per container (Lau et al. 2023)", style = "text-align: center; color: #777;"))),
      column(width = 6,
        box(width = 12, title = "Environmental Emission", status = "danger", solidHeader = TRUE,
            h3(paste0(econ$co2e_kg, " kg CO₂e"), style = "text-align: center; margin: 10px 0;"),
            p("Estimated waste emissions per container (EPA WARM)", style = "text-align: center; color: #777;")))
    )
  })

  output$spoilage_plot_ui <- renderUI({
    if (is.null(spoil_result())) {
      return(p(em("No results yet."), style = "color: #666;"))
    }
    plotOutput("spoilage_plot", height = "400px")
  })

  output$spoilage_plot <- renderPlot({
    res <- spoil_result()
    if (is.null(res)) return(NULL)

    d <- res$daily_median_spoilage
    threshold <- res$shelf_life$threshold_pct

    ggplot(d, aes(x = day)) +
      geom_ribbon(aes(ymin = P25, ymax = P75), fill = "#B31B1B", alpha = 0.2) +
      geom_line(aes(y = median_pct), color = "#B31B1B", linewidth = 1.2) +
      geom_point(aes(y = median_pct), color = "#B31B1B", size = 1.5) +
      geom_hline(yintercept = threshold, linetype = "dashed", color = "gray40") +
      annotate("text", x = max(d$day) * 0.95, y = threshold + 3,
               label = paste0(threshold, "% threshold"), hjust = 1, size = 3.5, color = "gray40") +
      scale_x_continuous(breaks = seq(0, max(d$day), by = 7)) +
      scale_y_continuous(limits = c(0, 100)) +
      labs(x = "Day", y = "Predicted Spoiled (%)",
           caption = "Shaded region: 25th-75th percentile range") +
      theme_minimal(base_size = 14) +
      theme(panel.grid.minor = element_blank())
  })

  output$summary_table_ui <- renderUI({
    if (is.null(spoil_result())) {
      return(p(em("No results yet."), style = "color: #666;"))
    }
    tagList(
      h5("Containers spoiled per lot (%)"),
      tableOutput("summary_table"),
      h5("Microbial concentration across all simulated containers (log10 CFU/mL)"),
      tableOutput("concentration_table")
    )
  })

  output$concentration_table <- renderTable({
    res <- spoil_result()
    if (is.null(res)) return(NULL)
    s <- res$spoilage_summary
    data.frame(
      Day = s$day,
      Median = s$conc_median_log10,
      P5 = s$conc_P5_log10,
      P25 = s$conc_P25_log10,
      P75 = s$conc_P75_log10,
      P95 = s$conc_P95_log10,
      check.names = FALSE
    )
  }, digits = 2)

  output$summary_table <- renderTable({
    res <- spoil_result()
    if (is.null(res)) return(NULL)
    s <- res$spoilage_summary
    data.frame(
      Day = s$day,
      `Median (%)` = round(s$median_pct_spoiled, 2),
      `Mean (%)` = round(s$mean_pct_spoiled, 2),
      `SD (%)` = round(s$sd, 2),
      `P5 (%)` = round(s$P5, 2),
      `P25 (%)` = round(s$P25, 2),
      `P75 (%)` = round(s$P75, 2),
      `P95 (%)` = round(s$P95, 2),
      check.names = FALSE
    )
  }, digits = 2)

  output$applied_ui <- renderUI({
    res <- spoil_result()
    if (is.null(res)) return(p(em("No results yet."), style = "color: #666;"))

    ia <- res$scenario$interventions_applied
    da <- res$scenario$disruptions_applied
    if (length(ia) == 0 && length(da) == 0) {
      return(p(em("No interventions or disruptions applied — baseline run.")))
    }

    tagList(
      if (length(ia) > 0) tagList(h5("Interventions applied:"),
        tags$pre(paste(capture.output(str(ia)), collapse = "\n"))),
      if (length(da) > 0) tagList(h5("Disruptions applied:"),
        tags$pre(paste(capture.output(str(da)), collapse = "\n")))
    )
  })
}

# Run the app
shinyApp(ui = ui, server = server)
