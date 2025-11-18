#!/usr/bin/env Rscript

# Merge raw NOAA ISD weather data with PJM load data
# Inputs:
#   - rawdata/weather/*.gz (NOAA ISD files)
#   - rawdata/load/ (PJM load data from OSF)
# Output: data/load_with_weather.csv

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(lubridate)
})

cat("========================================================================\n")
cat("Merging Raw Weather and Load Data\n")
cat("========================================================================\n\n")

# ==============================================================================
# STEP 1: Load PJM load data
# ==============================================================================

cat("Step 1: Loading PJM load data from rawdata/load/...\n")

# Find CSV files in rawdata/load/
load_files <- list.files("rawdata/load", pattern = "\\.csv$",
                         full.names = TRUE, recursive = TRUE)

if (length(load_files) == 0) {
  stop("ERROR: No CSV files found in rawdata/load/")
}

cat(sprintf("  Found %d CSV file(s)\n", length(load_files)))

# Load and combine all load data files
load_data <- data.frame()

for (file in load_files) {
  cat(sprintf("  Reading %s...\n", basename(file)))
  df <- read_csv(file, show_col_types = FALSE)
  load_data <- bind_rows(load_data, df)
}

cat(sprintf("  Total load records: %d\n\n", nrow(load_data)))

# Standardize column names for PJM data
# Keep times in Eastern Time (EST/EDT), do not convert to UTC
load_data <- load_data %>%
  mutate(
    datetime = force_tz(mdy_hms(datetime_beginning_ept), "America/New_York"),
    mw = as.numeric(mw)
  ) %>%
  select(load_area, datetime, mw)

# ==============================================================================
# STEP 2: Process NOAA ISD weather data
# ==============================================================================

cat("Step 2: Processing NOAA ISD weather data from rawdata/weather/...\n")

# Load station mapping
stations <- read_csv("weather_station_mapping_final.csv", show_col_types = FALSE)
cat(sprintf("  Loaded %d station mappings\n", nrow(stations)))

# Function to parse NOAA ISD CSV format
parse_noaa_isd <- function(csv_file) {
  tryCatch({
    # Read the CSV
    df <- read_csv(csv_file, show_col_types = FALSE)

    # Extract temperature (TMP field in NOAA ISD)
    # Format: temp,quality_code (e.g., "+0123,1")
    if ("TMP" %in% names(df)) {
      df <- df %>%
        mutate(
          # Parse DATE (format: YYYY-MM-DDThh:mm:ss)
          datetime = ymd_hms(DATE),
          # Parse TMP: extract numeric part and convert to Fahrenheit
          temp_c = as.numeric(substr(TMP, 1, 5)) / 10,  # Scaled by 10
          temp_f = temp_c * 9/5 + 32
        ) %>%
        filter(!is.na(datetime), !is.na(temp_f), temp_f > -100, temp_f < 150) %>%
        select(datetime, temp_f)

      return(df)
    } else {
      return(NULL)
    }
  }, error = function(e) {
    return(NULL)
  })
}

# Process all weather files
weather_data <- data.frame()
weather_files <- list.files("rawdata/weather", pattern = "\\.csv$", full.names = TRUE)

cat(sprintf("  Found %d weather files\n", length(weather_files)))

pb_total <- length(weather_files)
pb_count <- 0

for (file in weather_files) {
  pb_count <- pb_count + 1

  # Extract USAF-WBAN from filename (format: 724070-93730-2024.csv)
  basename_file <- basename(file)
  usaf_wban <- sub("-\\d{4}\\.csv$", "", basename_file)  # Remove -YYYY.csv

  # Find ALL load areas that use this station (may be multiple)
  station_match <- stations %>%
    filter(usaf_wban == !!usaf_wban)

  if (nrow(station_match) == 0) next

  # Parse weather data once
  weather <- parse_noaa_isd(file)

  if (!is.null(weather) && nrow(weather) > 0) {
    # Create weather records for EACH load area that uses this station
    for (i in 1:nrow(station_match)) {
      load_area <- station_match$load_area[i]
      weather_copy <- weather
      weather_copy$load_area <- load_area
      weather_data <- bind_rows(weather_data, weather_copy)
    }

    if (pb_count %% 10 == 0) {
      cat(sprintf("  Processed %d/%d files...\n", pb_count, pb_total))
    }
  }
}

cat(sprintf("  Total weather records: %d\n\n", nrow(weather_data)))

# ==============================================================================
# STEP 3: Merge load and weather data
# ==============================================================================

cat("Step 3: Merging load and weather data...\n")

# Round datetime to hour for matching
# Keep everything in Eastern Time
load_data <- load_data %>%
  mutate(datetime = floor_date(datetime, "hour"))

weather_data <- weather_data %>%
  mutate(
    datetime = with_tz(datetime, "America/New_York"),
    datetime = floor_date(datetime, "hour")
  ) %>%
  group_by(load_area, datetime) %>%
  summarise(temp_f = mean(temp_f, na.rm = TRUE), .groups = "drop")

# Merge
merged_data <- load_data %>%
  left_join(weather_data, by = c("load_area", "datetime"))

cat(sprintf("  Merged records: %d\n", nrow(merged_data)))
cat(sprintf("  Non-missing temperatures: %d (%.1f%%)\n",
            sum(!is.na(merged_data$temp_f)),
            100 * mean(!is.na(merged_data$temp_f))))

# ==============================================================================
# STEP 4: Save merged data
# ==============================================================================

cat("\nStep 4: Saving merged data...\n")

# Create data directory if needed
dir.create("data", showWarnings = FALSE)

# Select and order columns
# Format datetime as string in EST without timezone suffix
output_data <- merged_data %>%
  mutate(datetime = format(datetime, "%Y-%m-%d %H:%M:%S")) %>%
  select(load_area, datetime, mw, temp_f) %>%
  arrange(load_area, datetime)

# Save
output_file <- "data/load_with_weather.csv"
write_csv(output_data, output_file)

cat(sprintf("  ✓ Saved to: %s\n", output_file))

# File size
file_size <- file.size(output_file) / (1024^2)
cat(sprintf("  File size: %.1f MB\n", file_size))

# ==============================================================================
# STEP 5: Summary statistics
# ==============================================================================

cat("\n========================================================================\n")
cat("SUMMARY\n")
cat("========================================================================\n\n")

cat(sprintf("Date range: %s to %s\n",
            min(output_data$datetime), max(output_data$datetime)))
cat(sprintf("Load areas: %d\n", n_distinct(output_data$load_area)))
cat(sprintf("Total records: %d\n", nrow(output_data)))
cat(sprintf("Records with temperature: %d (%.1f%%)\n",
            sum(!is.na(output_data$temp_f)),
            100 * mean(!is.na(output_data$temp_f))))

cat("\n========================================================================\n")
cat("Complete!\n")
cat("========================================================================\n")
