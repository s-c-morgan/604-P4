#!/usr/bin/env Rscript

# Make predictions using optimized seasonal weight models
# Required inputs:
#   1. Next day's temperature forecast (24 hours per zone)

# Suppress package startup messages
suppressPackageStartupMessages({
  library(lubridate)
  library(dplyr)
  library(readr)
})

# Redirect all diagnostic output to stderr so only predictions go to stdout
cat("========================================================================\n", file = stderr())
cat("PJM Load Forecasting - Daily Prediction Script (Optimized Models)\n", file = stderr())
cat("========================================================================\n\n", file = stderr())

# Load trained models
models_file <- "data/optimized_models.rds"
if (!file.exists(models_file)) {
  stop("ERROR: Models file not found: ", models_file, "\n",
       "Run fit_optimized_models.R first to create models.")
}

models <- readRDS(models_file)
zones <- names(models)

cat(sprintf("Loaded %d optimized models\n\n", length(models)), file = stderr())

# ==============================================================================
# STEP 1: Get prediction date (tomorrow)
# ==============================================================================

# For Docker: prediction date should be passed as environment variable
prediction_date_str <- Sys.getenv("PREDICTION_DATE", "")

if (prediction_date_str == "") {
  # Default: tomorrow
  prediction_date <- Sys.Date() + days(1)
} else {
  prediction_date <- ymd(prediction_date_str)
}

cat(sprintf("Prediction date: %s\n\n", prediction_date), file = stderr())

# ==============================================================================
# STEP 2: Load temperature forecast for prediction day
# ==============================================================================

cat("Loading temperature forecast for prediction day...\n", file = stderr())

temp_file <- sprintf("data/forecast_%s.csv", prediction_date)

if (!file.exists(temp_file)) {
  cat(sprintf("WARNING: Temperature forecast file not found: %s\n", temp_file))
  cat("\nYou need to provide temperature forecasts in this format:\n")
  cat("  load_zone,datetime,temp_f\n")
  cat("  AECO,2025-11-19 00:00:00,45.2\n")
  cat("  AECO,2025-11-19 01:00:00,44.8\n")
  cat("  ...\n\n")
  cat("Save this file as: ", temp_file, "\n")
  cat("\nTo fetch weather forecasts:\n")
  cat("  Rscript fetch_weather_forecast.R\n")
  stop("Cannot proceed without temperature forecast.")
}

temp_forecast <- read_csv(temp_file, show_col_types = FALSE)
cat(sprintf("  Loaded %d temperature forecasts from %s\n",
            nrow(temp_forecast), temp_file), file = stderr())

# ==============================================================================
# STEP 3: Prepare prediction data frame
# ==============================================================================

cat("\nPreparing prediction data...\n", file = stderr())

# Create template for all zone-hour combinations
prediction_hours <- seq(from = ymd_hms(paste(prediction_date, "00:00:00")),
                       to = ymd_hms(paste(prediction_date, "23:00:00")),
                       by = "hour")

prediction_data <- expand.grid(
  load_area = zones,
  datetime = prediction_hours,
  stringsAsFactors = FALSE
)

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
    # Training data doesn't have hour 0 (hours 1-23), so map 0 -> 23
    hour = ifelse(hour_raw == 0, 23, hour_raw),
    thanksgiving_week = sapply(datetime, is_thanksgiving_week)
  )

# Join temperature forecast (rename load_zone to load_area)
prediction_data <- prediction_data %>%
  left_join(
    suppressWarnings(
      temp_forecast %>%
        mutate(datetime = ymd_hms(datetime)) %>%
        rename(load_area = load_zone) %>%
        select(load_area, datetime, temp_f)
    ),
    by = c("load_area", "datetime")
  )

# Check for missing temperatures
missing_temp <- prediction_data %>% filter(is.na(temp_f))
if (nrow(missing_temp) > 0) {
  cat(sprintf("  WARNING: %d observations missing temperature forecast\n",
              nrow(missing_temp)), file = stderr())
  # Fill missing with mean
  mean_temp <- mean(prediction_data$temp_f, na.rm = TRUE)
  prediction_data <- prediction_data %>%
    mutate(temp_f = ifelse(is.na(temp_f), mean_temp, temp_f))
}

cat(sprintf("  Prepared %d prediction rows (%d zones × 24 hours)\n",
            nrow(prediction_data), length(zones)), file = stderr())

# ==============================================================================
# STEP 4: Make predictions
# ==============================================================================

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

# ==============================================================================
# STEP 5: Calculate peak hours and peak days
# ==============================================================================

cat("\nCalculating peak hours and peak days...\n", file = stderr())

# Peak hour: hour with maximum load for each zone (for today's prediction)
peak_hours <- all_predictions %>%
  group_by(load_area) %>%
  slice_max(predicted_mw, n = 1) %>%
  select(load_area, peak_hour = hour_raw) %>%
  ungroup()

# Peak days: Read from peak day analysis (if available)
peak_days_file <- "data/peak_days.csv"
if (file.exists(peak_days_file)) {
  peak_days_data <- read_csv(peak_days_file, show_col_types = FALSE)

  # Filter for today's prediction date
  peak_days <- peak_days_data %>%
    filter(date == prediction_date) %>%
    select(load_area, is_peak_day)

  # If today is not in the peak_days file, default to 0 for all zones
  if (nrow(peak_days) == 0) {
    peak_days <- data.frame(
      load_area = zones,
      is_peak_day = 0
    )
  } else {
    # Ensure all zones are present
    missing_zones <- setdiff(zones, peak_days$load_area)
    if (length(missing_zones) > 0) {
      peak_days <- bind_rows(
        peak_days,
        data.frame(load_area = missing_zones, is_peak_day = 0)
      )
    }
  }
} else {
  # If peak_days.csv doesn't exist, default to 0 for all zones
  cat("  WARNING: peak_days.csv not found, defaulting all to non-peak\n", file = stderr())
  peak_days <- data.frame(
    load_area = zones,
    is_peak_day = 0
  )
}

# ==============================================================================
# STEP 6: Format output for submission
# ==============================================================================

cat("\nFormatting output...\n", file = stderr())

# Ensure zones are in consistent order
zones_ordered <- sort(zones)

# Reshape predictions to wide format (one row)
load_predictions <- all_predictions %>%
  arrange(load_area, hour_raw) %>%
  mutate(
    col_name = paste0("L", match(load_area, zones_ordered), "_", sprintf("%02d", hour_raw)),
    predicted_mw = round(predicted_mw)
  ) %>%
  select(col_name, predicted_mw) %>%
  tidyr::pivot_wider(names_from = col_name, values_from = predicted_mw)

# Peak hours
peak_hour_wide <- peak_hours %>%
  mutate(
    col_name = paste0("PH_", match(load_area, zones_ordered)),
    peak_hour = sprintf("%02d", peak_hour)
  ) %>%
  select(col_name, peak_hour) %>%
  tidyr::pivot_wider(names_from = col_name, values_from = peak_hour)

# Peak days
peak_day_wide <- peak_days %>%
  mutate(
    col_name = paste0("PD_", match(load_area, zones_ordered))
  ) %>%
  select(col_name, is_peak_day) %>%
  tidyr::pivot_wider(names_from = col_name, values_from = is_peak_day)

# Combine all into one row
output_row <- bind_cols(
  data.frame(date = as.character(Sys.Date())),  # Current date (prediction made today)
  load_predictions,
  peak_hour_wide,
  peak_day_wide
)

# ==============================================================================
# STEP 7: Output predictions
# ==============================================================================

cat("\n========================================================================\n", file = stderr())
cat("PREDICTIONS FOR", as.character(prediction_date), "\n", file = stderr())
cat("(Made on:", as.character(Sys.Date()), ")\n", file = stderr())
cat("Using OPTIMIZED SEASONAL WEIGHTS (3-round CV)\n", file = stderr())
cat("========================================================================\n\n", file = stderr())

# Write to stdout in required format (no header)
# This is the ONLY output to stdout
# Format: "YYYY-MM-DD", numeric, numeric, ... (only date is quoted)
output_line <- paste0(
  '"', output_row$date, '", ',
  paste(output_row[, -1], collapse = ", ")
)
cat(output_line, "\n", sep = "")

# Also save detailed predictions to file (silent)
detail_file <- sprintf("data/predictions_%s_detail.csv", prediction_date)
write_csv(all_predictions %>%
            select(load_area, datetime, hour_raw, day_of_week, temp_f, predicted_mw),
          detail_file)
cat(sprintf("\nDetailed predictions saved to: %s\n", detail_file), file = stderr())

# Save summary statistics
cat("\n========================================================================\n", file = stderr())
cat("PREDICTION SUMMARY\n", file = stderr())
cat("========================================================================\n\n", file = stderr())

summary_stats <- all_predictions %>%
  group_by(load_area) %>%
  summarise(
    mean_load = mean(predicted_mw),
    min_load = min(predicted_mw),
    max_load = max(predicted_mw),
    peak_hour = hour_raw[which.max(predicted_mw)],
    .groups = "drop"
  ) %>%
  arrange(desc(mean_load))

# Print to stderr so it doesn't interfere with stdout predictions
sink(stderr())
print(summary_stats, n = Inf)
sink()

cat("\n========================================================================\n", file = stderr())
cat("Complete!\n", file = stderr())
cat("========================================================================\n", file = stderr())
