# Renders spoilage curve as base64 PNG from daily spoilage data.

library(ggplot2)
library(base64enc)

render_spoilage_plot <- function(daily_data, shelf_life_threshold = 25) {
  # daily_data: data frame with columns day, median_pct, P25, P75

  tmpfile <- tempfile(fileext = ".png")
  png(tmpfile, width = 800, height = 500, res = 120)

  p <- ggplot(daily_data, aes(x = day)) +
    geom_ribbon(aes(ymin = P25, ymax = P75), fill = "#B31B1B", alpha = 0.2) +
    geom_line(aes(y = median_pct), color = "#B31B1B", linewidth = 1.2) +
    geom_point(aes(y = median_pct), color = "#B31B1B", size = 1.5) +
    geom_hline(yintercept = shelf_life_threshold, linetype = "dashed",
               color = "gray40", linewidth = 0.5) +
    annotate("text", x = max(daily_data$day) * 0.95, y = shelf_life_threshold + 3,
             label = paste0(shelf_life_threshold, "% threshold"),
             hjust = 1, size = 3, color = "gray40") +
    scale_x_continuous(breaks = seq(0, max(daily_data$day), by = 7)) +
    scale_y_continuous(limits = c(0, 100)) +
    labs(x = "Day", y = "Predicted Spoiled (%)",
         title = "Predicted Spoilage Over Time",
         subtitle = "Median with 25th-75th percentile band") +
    theme_minimal() +
    theme(
      plot.title = element_text(size = 14, face = "bold"),
      plot.subtitle = element_text(size = 10, color = "gray50"),
      panel.grid.minor = element_blank()
    )

  print(p)
  dev.off()

  # Read and encode as base64
  raw <- readBin(tmpfile, "raw", file.info(tmpfile)$size)
  file.remove(tmpfile)
  paste0("data:image/png;base64,", base64encode(raw))
}
