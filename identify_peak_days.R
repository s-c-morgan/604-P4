#!/usr/bin/env Rscript

# Identify the 2 peak days (out of 10) for each zone
# Peak days are defined as the 2 days with highest load during their peak hour
# Input: data/predictions_10day.csv
# Output: data/peak_days.csv

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

cat("========================================================================\n", file = stderr())
cat("Identifying Peak Days from 10-Day Predictions\n", file = stderr())
cat("========================================================================\n\n", file = stderr())

# Load 10-day predictions
predictions_file <- "data/predictions_10day.csv"
if (!file.exists(predictions_file)) {
  stop("ERROR: 10-day predictions not found: ", predictions_file, "\n",
       "Run predict_10day_loads.R first.")
}

predictions <- read_csv(predictions_file, show_col_types = FALSE)
cat(sprintf("Loaded %d predictions\n", nrow(predictions)), file = stderr())

zones <- unique(predictions$load_area)
dates <- unique(predictions$date)

cat(sprintf("Zones: %d\n", length(zones)), file = stderr())
cat(sprintf("Dates: %d (%s to %s)\n\n", length(dates), min(dates), max(dates)),
    file = stderr())

# For each zone, find the peak hour load for each day
cat("Calculating peak hour loads for each zone-day...\n", file = stderr())

peak_hour_loads <- predictions %>%
  group_by(load_area, date) %>%
  summarise(
    peak_hour = hour_raw[which.max(predicted_mw)],
    peak_hour_load = max(predicted_mw),
    .groups = "drop"
  )

cat(sprintf("  Calculated %d peak hour loads\n", nrow(peak_hour_loads)), file = stderr())

# For each zone, identify the top 2 days with highest peak hour load
cat("\nIdentifying top 2 peak days for each zone...\n", file = stderr())

peak_days <- peak_hour_loads %>%
  group_by(load_area) %>%
  arrange(desc(peak_hour_load)) %>%
  mutate(
    rank = row_number(),
    is_peak_day = ifelse(rank <= 2, 1, 0)
  ) %>%
  ungroup() %>%
  select(load_area, date, peak_hour, peak_hour_load, is_peak_day)

# Count peak days per zone
peak_day_counts <- peak_days %>%
  group_by(load_area) %>%
  summarise(
    n_peak_days = sum(is_peak_day),
    .groups = "drop"
  )

cat(sprintf("  Identified peak days for %d zones\n", nrow(peak_day_counts)), file = stderr())

# Verify each zone has exactly 2 peak days
if (any(peak_day_counts$n_peak_days != 2)) {
  cat("WARNING: Some zones don't have exactly 2 peak days:\n", file = stderr())
  print(peak_day_counts %>% filter(n_peak_days != 2))
}

# Save peak days
output_file <- "data/peak_days.csv"
write_csv(peak_days, output_file)

cat(sprintf("\n✓ Saved peak days to: %s\n", output_file), file = stderr())

# Summary
cat("\n========================================================================\n", file = stderr())
cat("SUMMARY\n", file = stderr())
cat("========================================================================\n\n", file = stderr())

cat(sprintf("Total zone-day combinations: %d\n", nrow(peak_days)), file = stderr())
cat(sprintf("Peak days identified: %d\n", sum(peak_days$is_peak_day)), file = stderr())
cat(sprintf("Expected peak days: %d (29 zones × 2 days)\n\n", 29 * 2), file = stderr())

# Show top 5 peak days by load
cat("Top 5 peak days by load:\n", file = stderr())
top_peaks <- peak_days %>%
  filter(is_peak_day == 1) %>%
  arrange(desc(peak_hour_load)) %>%
  head(5)
print(top_peaks)

# Show distribution of peak days across dates
cat("\nPeak days by date:\n", file = stderr())
peak_date_dist <- peak_days %>%
  filter(is_peak_day == 1) %>%
  group_by(date) %>%
  summarise(n_zones_peaking = n(), .groups = "drop") %>%
  arrange(desc(n_zones_peaking))
print(peak_date_dist)

cat("\n========================================================================\n", file = stderr())
cat("Complete!\n", file = stderr())
cat("========================================================================\n", file = stderr())
