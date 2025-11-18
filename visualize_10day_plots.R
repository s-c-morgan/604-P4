#!/usr/bin/env Rscript

# Generate individual PNG plots for each zone's 10-day predictions

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(lubridate)
  library(ggplot2)
})

cat("========================================================================\n")
cat("Generating 10-Day Load Prediction Plots\n")
cat("========================================================================\n\n")

# Check if predictions exist
if (!file.exists("data/predictions_10day.csv")) {
  stop("ERROR: 10-day predictions not found.\n",
       "Run: make peak_days")
}

if (!file.exists("data/peak_days.csv")) {
  stop("ERROR: Peak days not found.\n",
       "Run: make peak_days")
}

# Load predictions
predictions <- read_csv("data/predictions_10day.csv", show_col_types = FALSE) %>%
  mutate(datetime = ymd_hms(datetime))

# Load peak days
peak_days <- read_csv("data/peak_days.csv", show_col_types = FALSE)

cat(sprintf("Loaded %d predictions\n", nrow(predictions)))
cat(sprintf("Date range: %s to %s\n", min(predictions$date), max(predictions$date)))
cat(sprintf("Zones: %d\n\n", n_distinct(predictions$load_area)))

# Create output directory
dir.create("plots/10day_predictions", showWarnings = FALSE, recursive = TRUE)

# Get sorted list of zones (by average load)
zones_ordered <- predictions %>%
  group_by(load_area) %>%
  summarise(mean_load = mean(predicted_mw, na.rm = TRUE), .groups = "drop") %>%
  arrange(desc(mean_load)) %>%
  pull(load_area)

cat(sprintf("Generating plots for %d zones...\n", length(zones_ordered)))

# Generate plot for each zone
for (zone_name in zones_ordered) {

  # Filter data for this zone
  zone_data <- predictions %>%
    filter(load_area == zone_name) %>%
    arrange(datetime)

  # Get peak days for this zone
  zone_peaks <- peak_days %>%
    filter(load_area == zone_name, is_peak_day == 1) %>%
    arrange(desc(peak_hour_load))

  # Mark peak days in the data
  zone_data <- zone_data %>%
    mutate(
      day_type = case_when(
        date %in% zone_peaks$date[1] ~ "Peak Day #1",
        date %in% zone_peaks$date[2] ~ "Peak Day #2",
        TRUE ~ "Regular Day"
      ),
      day_type = factor(day_type, levels = c("Peak Day #1", "Peak Day #2", "Regular Day"))
    )

  # Get peak hour markers
  peak_markers <- data.frame()
  if (nrow(zone_peaks) > 0) {
    for (i in 1:nrow(zone_peaks)) {
      peak_datetime <- ymd_hms(sprintf("%s %02d:00:00",
                                       zone_peaks$date[i],
                                       zone_peaks$peak_hour[i]))
      peak_markers <- bind_rows(
        peak_markers,
        data.frame(
          datetime = peak_datetime,
          peak_hour_load = zone_peaks$peak_hour_load[i],
          peak_rank = sprintf("Peak Hour #%d", i)
        )
      )
    }
  }

  # Calculate statistics
  avg_load <- mean(zone_data$predicted_mw, na.rm = TRUE)
  min_load <- min(zone_data$predicted_mw, na.rm = TRUE)
  max_load <- max(zone_data$predicted_mw, na.rm = TRUE)

  # Create plot
  p <- ggplot(zone_data, aes(x = datetime, y = predicted_mw, group = date, color = day_type)) +
    geom_line(aes(size = day_type), alpha = 0.8) +
    scale_size_manual(values = c("Peak Day #1" = 1.5, "Peak Day #2" = 1.2, "Regular Day" = 0.6)) +
    scale_color_manual(values = c("Peak Day #1" = "#d62728",
                                   "Peak Day #2" = "#ff7f0e",
                                   "Regular Day" = "#1f77b4")) +
    labs(
      title = sprintf("%s - 10-Day Load Predictions", zone_name),
      subtitle = sprintf("Avg: %.0f MW | Min: %.0f MW | Max: %.0f MW | Peak Days: %d",
                        avg_load, min_load, max_load, nrow(zone_peaks)),
      x = "Date/Time",
      y = "Predicted Load (MW)",
      color = "Day Type",
      size = "Day Type"
    ) +
    theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      plot.subtitle = element_text(size = 10, color = "gray40"),
      legend.position = "bottom",
      legend.title = element_text(face = "bold"),
      panel.grid.minor = element_blank(),
      panel.grid.major = element_line(color = "gray90"),
      plot.background = element_rect(fill = "white", color = NA),
      panel.background = element_rect(fill = "white", color = NA)
    )

  # Add peak hour markers if they exist
  if (nrow(peak_markers) > 0) {
    p <- p +
      geom_point(data = peak_markers,
                 aes(x = datetime, y = peak_hour_load, shape = peak_rank),
                 size = 4, color = "black", inherit.aes = FALSE) +
      geom_point(data = peak_markers,
                 aes(x = datetime, y = peak_hour_load, shape = peak_rank, color = peak_rank),
                 size = 3, inherit.aes = FALSE) +
      scale_shape_manual(values = c("Peak Hour #1" = 17, "Peak Hour #2" = 17),
                        name = "Peak Hour") +
      guides(
        color = guide_legend(order = 1, override.aes = list(shape = NA)),
        size = guide_legend(order = 1),
        shape = guide_legend(order = 2,
                            override.aes = list(color = c("#d62728", "#ff7f0e")))
      )
  }

  # Save plot
  filename <- sprintf("plots/10day_predictions/%s.png", zone_name)
  ggsave(filename, p, width = 12, height = 6, dpi = 300, bg = "white")

  cat(sprintf("  ✓ %s\n", zone_name))
}

cat(sprintf("\n✓ Saved %d plots to: plots/10day_predictions/\n", length(zones_ordered)))

cat("\n========================================================================\n")
cat("Complete!\n")
cat("========================================================================\n")
