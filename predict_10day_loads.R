#!/usr/bin/env Rscript

# Predict loads for all 10 days using 10-day weather forecast
# Input: data/forecast_10day.csv
# Output: data/predictions_10day.csv

suppressPackageStartupMessages({
  library(lubridate)
  library(dplyr)
  library(readr)
})

cat("========================================================================\n", file = stderr())
cat("Predicting Loads for 10-Day Period\n", file = stderr())
cat("========================================================================\n\n", file = stderr())

# Load trained models
models_file <- "data/optimized_models.rds"
if (!file.exists(models_file)) {
  stop("ERROR: Models file not found: ", models_file)
}

models <- readRDS(models_file)
zones <- names(models)
cat(sprintf("Loaded %d optimized models\n", length(models)), file = stderr())

# CRITICAL: Require exactly 29 zones
REQUIRED_ZONES <- 29
if (length(zones) != REQUIRED_ZONES) {
  cat(sprintf("\n\nERROR: Expected %d zones but only have %d models!\n",
              REQUIRED_ZONES, length(zones)), file = stderr())
  cat("  Cannot make predictions - need all 29 zones.\n", file = stderr())
  cat("  Run fit_optimized_models.R to train missing models.\n\n", file = stderr())
  stop(sprintf("Incomplete models: %d/%d zones", length(zones), REQUIRED_ZONES))
}

# Load 10-day temperature forecast
forecast_file <- "data/forecast_10day.csv"
if (!file.exists(forecast_file)) {
  stop("ERROR: 10-day forecast not found: ", forecast_file, "\n",
       "Run fetch_10day_forecast.R first.")
}

temp_forecast <- read_csv(forecast_file, show_col_types = FALSE)
cat(sprintf("Loaded %d temperature forecasts\n", nrow(temp_forecast)), file = stderr())

# Parse datetime once and ensure EST timezone
temp_forecast <- temp_forecast %>%
  mutate(datetime = force_tz(ymd_hms(datetime), "America/New_York"))

# Determine prediction dates
prediction_dates <- unique(as.Date(temp_forecast$datetime))
cat(sprintf("Prediction period: %s to %s (%d days)\n\n",
            min(prediction_dates), max(prediction_dates),
            length(prediction_dates)), file = stderr())

# Prepare prediction data
cat("Preparing prediction data...\n", file = stderr())

# Create template for all zone-hour-date combinations
# Note: expand.grid converts datetime to numeric, so we rebuild it properly
unique_datetimes <- sort(unique(temp_forecast$datetime))

prediction_data <- expand.grid(
  load_area = zones,
  datetime_index = seq_along(unique_datetimes),
  stringsAsFactors = FALSE
) %>%
  mutate(datetime = unique_datetimes[datetime_index]) %>%
  select(-datetime_index)

# Function to determine if a date is in Thanksgiving week
is_thanksgiving_week <- function(date) {
  if (is.na(date)) return(FALSE)

  d <- as.Date(date)
  m <- month(d)
  y <- year(d)

  if (is.na(m) || m != 11) return(FALSE)

  nov_dates <- seq(ymd(paste(y, "11", "01", sep="-")),
                   ymd(paste(y, "11", "30", sep="-")),
                   by = "day")
  thursdays <- nov_dates[wday(nov_dates) == 5]

  if (length(thursdays) < 4) return(FALSE)

  thanksgiving <- thursdays[4]
  week_start <- thanksgiving - days(wday(thanksgiving) - 1)
  week_end <- week_start + days(6)

  return(d >= week_start & d <= week_end)
}

# Add temporal features
prediction_data <- prediction_data %>%
  mutate(
    day_of_week = wday(datetime, label = FALSE),
    hour_raw = hour(datetime),
    hour = hour_raw,  # Use actual hour (0-23)
    thanksgiving_week = sapply(datetime, is_thanksgiving_week)
  )

# Join temperature forecast (already parsed datetime above)
prediction_data <- prediction_data %>%
  left_join(
    temp_forecast %>%
      rename(load_area = load_zone) %>%
      select(load_area, datetime, temp_f),
    by = c("load_area", "datetime")
  )

# Check for missing temperatures
missing_temp <- prediction_data %>% filter(is.na(temp_f))
if (nrow(missing_temp) > 0) {
  cat(sprintf("  WARNING: %d observations missing temperature\n",
              nrow(missing_temp)), file = stderr())
  mean_temp <- mean(prediction_data$temp_f, na.rm = TRUE)
  prediction_data <- prediction_data %>%
    mutate(temp_f = ifelse(is.na(temp_f), mean_temp, temp_f))
}

cat(sprintf("  Prepared %d prediction rows\n", nrow(prediction_data)), file = stderr())

# Make predictions
cat("\nGenerating predictions...\n", file = stderr())

all_predictions <- data.frame()

for (zone in zones) {
  zone_data <- prediction_data %>% filter(load_area == zone)

  if (nrow(zone_data) == 0) next

  # Predict using zone model
  zone_data$predicted_mw <- predict(models[[zone]], newdata = zone_data)

  all_predictions <- bind_rows(all_predictions, zone_data)
}

cat(sprintf("  Generated %d predictions\n", nrow(all_predictions)), file = stderr())

# Add date column for easy grouping
all_predictions <- all_predictions %>%
  mutate(date = as.Date(datetime))

# Save predictions
output_file <- "data/predictions_10day.csv"
write_csv(all_predictions %>%
            select(load_area, datetime, date, hour_raw, day_of_week, temp_f, predicted_mw),
          output_file)

cat(sprintf("\n✓ Saved 10-day predictions to: %s\n", output_file), file = stderr())

# Summary statistics
cat("\n========================================================================\n", file = stderr())
cat("SUMMARY\n", file = stderr())
cat("========================================================================\n\n", file = stderr())

summary_by_zone <- all_predictions %>%
  group_by(load_area) %>%
  summarise(
    n_days = n_distinct(date),
    n_hours = n(),
    mean_load = mean(predicted_mw),
    min_load = min(predicted_mw),
    max_load = max(predicted_mw),
    .groups = "drop"
  ) %>%
  arrange(desc(mean_load))

cat(sprintf("Total predictions: %d\n", nrow(all_predictions)), file = stderr())
cat(sprintf("Expected: %d (29 zones × %d days × 24 hours)\n",
            29 * length(prediction_dates) * 24, length(prediction_dates)), file = stderr())
cat(sprintf("\nTop 5 zones by average load:\n"), file = stderr())
print(head(summary_by_zone, 5))

cat("\n========================================================================\n", file = stderr())
cat("Complete!\n", file = stderr())
cat("========================================================================\n", file = stderr())
